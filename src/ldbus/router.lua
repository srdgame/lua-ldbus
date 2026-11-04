--- Message routing: exported objects (method dispatch), signal handlers,
--- and signal emission. router.attach(conn) installs the machinery on a
--- Connection and takes over its on_message hook.
-- @module ldbus.router

local message = require "ldbus.message"
local errors = require "ldbus.errors"
local name = require "ldbus.name"
local introspect = require "ldbus.introspect"

local router = {}

local DBUS_DEST = "org.freedesktop.DBus"
local DBUS_PATH = "/org/freedesktop/DBus"
local DBUS_IFACE = "org.freedesktop.DBus"

--- Register a handler list slot. Returns the (empty) list.
local function handler_list(conn, iface, member)
  local iface_handlers = conn.signal_handlers[iface]
  if not iface_handlers then
    iface_handlers = {}
    conn.signal_handlers[iface] = iface_handlers
  end
  local list = iface_handlers[member]
  if not list then
    list = {}
    iface_handlers[member] = list
  end
  return list
end

--- Register a signal handler locally (no AddMatch). `member` may be nil
--- to match any member on the interface. The bus layer (ldbus.init) is
--- responsible for performing the AddMatch bus call.
function router.on_signal(conn, iface, member, fn)
  local list = handler_list(conn, iface, member or "")
  for _, existing in ipairs(list) do
    if existing == fn then return false end -- already registered
  end
  list[#list + 1] = fn
  return true
end

--- Send an AddMatch rule to the bus (blocking outside a mainloop).
function router.add_match(conn, rule)
  return conn:call(DBUS_DEST, DBUS_PATH, DBUS_IFACE, "AddMatch",
                   { rule }, { signature = "s" })
end

--- Deliver an incoming signal to registered handlers.
local function dispatch_signal(conn, msg)
  local iface_handlers = conn.signal_handlers[msg.interface]
  if not iface_handlers then return end
  local list = iface_handlers[msg.member] or iface_handlers[""]
  if not list then return end
  for _, fn in ipairs(list) do
    local ok, err = pcall(fn, msg)
    if not ok then
      -- handler errors must not kill the pump; surface on stderr
      io.stderr:write("ldbus: signal handler error: ", tostring(err), "\n")
    end
  end
end

--- Get or create the object table at a path.
-- Objects live on the connection: conn.objects[path] = { methods = {...} }.
-- Methods are keyed "iface.member", or "member" as a wildcard fallback.
function router.object(conn, path)
  conn.objects = conn.objects or {}
  local obj = conn.objects[path]
  if not obj then
    obj = { path = path, methods = {} }
    conn.objects[path] = obj
  end
  return obj
end

--- Register a method on an object.
-- obj = router.object(conn, path)
-- router.method(obj, member, in_sig, out_sig, fn)
-- fn receives the decoded arguments and returns the reply values (or nil).
function router.method(obj, member, in_sig, out_sig, fn)
  obj.methods[member] = {
    member = member,
    in_sig = in_sig or "",
    out_sig = out_sig or "",
    fn = fn,
  }
  return obj.methods[member]
end

--- Send an error reply for an incoming method call.
local function send_error(conn, call, err_name, msg)
  if call.flags and (call.flags % 2 >= 1) then -- NO_REPLY_EXPECTED
    return
  end
  return conn:send(errors.reply_opts(call, err_name, msg))
end

--- Look up a method: exact "iface.member" registration first, then the
--- wildcard "member" registration on the same object.
local function lookup_method(obj, iface, member)
  if not obj then return nil end
  return obj.methods[iface .. "." .. member] or obj.methods[member]
end

--- Invoke a handler and send the reply (or error reply) for a call.
local function execute_call(conn, msg, m)
  local results = { pcall(m.fn, table.unpack(msg.body or {})) }
  local ok = table.remove(results, 1)
  if not ok then
    local err = results[1]
    if errors.is(err) then
      return send_error(conn, msg, err.name, err.message)
    end
    -- string errors carry a "file:line: " prefix from error(); strip it
    if type(err) == "string" then
      err = err:match("^.+:%d+: (.+)$") or err
    end
    return send_error(conn, msg, errors.FAILED, tostring(err))
  end
  if msg.flags and (msg.flags % 2 >= 1) then -- NO_REPLY_EXPECTED
    return true
  end
  return conn:send({
    type = "method_return",
    reply_serial = msg.serial,
    destination = msg.sender,
    signature = m.out_sig or "",
    body = results,
  })
end

--- Dispatch an incoming method_call: route to a registered handler and
--- send the reply. Unhandled calls get error replies (unless the caller
--- marked them NO_REPLY_EXPECTED).
function router.dispatch_method(conn, msg)
  local obj = conn.objects and conn.objects[msg.path]
  local m = lookup_method(obj, msg.interface, msg.member)

  -- built-in: org.freedesktop.DBus.Introspectable.Introspect
  local intro_opts = introspect.reply(conn, msg)
  if intro_opts then
    if msg.flags and (msg.flags % 2 >= 1) then
      return true
    end
    return conn:send(intro_opts)
  end

  -- built-in: org.freedesktop.DBus.Peer.Ping
  if not m and msg.interface == "org.freedesktop.DBus.Peer" and msg.member == "Ping" then
    m = { member = "Ping", in_sig = "", out_sig = "", fn = function() return nil end }
  end

  if not m then
    if not obj then
      return send_error(conn, msg, errors.UNKNOWN_OBJECT,
        "no object at path " .. tostring(msg.path))
    end
    return send_error(conn, msg, errors.UNKNOWN_METHOD,
      msg.interface .. "." .. msg.member .. " not implemented at " .. tostring(msg.path))
  end

  if conn.loop_mode and conn._scheduler then
    -- mainloop mode: the handler runs as a task so it may yield on
    -- nested bus:call()s; the reply is sent when the task finishes.
    conn._scheduler:spawn(execute_call, conn, msg, m)
  else
    execute_call(conn, msg, m)
  end
end

--- Emit a signal: router.emit(conn, path, iface, member, sig, values).
-- Returns the serial, or nil + error.
function router.emit(conn, path, iface, member, sig, values)
  return conn:send({
    type = "signal",
    path = path,
    interface = iface,
    member = member,
    signature = sig or "",
    body = values,
    flags = message.FLAG.NO_REPLY_EXPECTED,
  })
end

--- Attach routing to a connection. After this, pumping the connection
--- dispatches method_calls to registered objects and signals to handlers.
-- Any pre-existing conn.on_message hook is preserved and still called.
function router.attach(conn)
  conn.objects = conn.objects or {}
  conn.signal_handlers = conn.signal_handlers or {}
  local user_hook = conn.on_message
  conn.on_message = function(msg)
    if msg.type == message.TYPE.METHOD_CALL then
      router.dispatch_method(conn, msg)
    elseif msg.type == message.TYPE.SIGNAL then
      dispatch_signal(conn, msg)
    end
    if user_hook then
      user_hook(msg)
    end
  end
  return conn
end

return router
