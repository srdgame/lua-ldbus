--- Bus connection: serials, pending replies, blocking pump, dispatch.
-- Works over any "io" object providing:
--   send(bytes)                    -> true | nil, err
--   recv()                         -> string | false | nil, err
--   wait_readable(timeout)         -> true | false (false = timeout)
--   close()
-- @module ldbus.connection

local message = require "ldbus.message"
local buffermod = require "ldbus.buffer"
local auth = require "ldbus.auth"
local uid = require "ldbus.uid"
local address = require "ldbus.address"
local socketio = require "ldbus.socketio"
local lsocket = require "lsocket"

local middleclass = require "ldbus.class"

local Connection = middleclass("Connection")

local SERIAL_MAX = 4294967295
local DBUS_DEST = "org.freedesktop.DBus"
local DBUS_PATH = "/org/freedesktop/DBus"
local DBUS_IFACE = "org.freedesktop.DBus"

--- Wrap an lsocket socket in the io interface. All functions are
-- called as methods (io:send(bytes)), so each takes a leading self.
local function lsocket_io(sock)
  return {
    send = function(_, bytes)
      return socketio.send_all(sock, bytes)
    end,
    recv = function(_)
      return socketio.recv(sock)
    end,
    wait_readable = function(_, timeout)
      local r = lsocket.select({ sock }, timeout)
      if r == false then
        return false -- timeout
      end
      return r ~= nil and #r > 0
    end,
    close = function(_)
      socketio.close(sock)
    end,
    _sock = sock,
  }
end

--- Create a connection over an existing io object (testing-friendly).
-- Call :authenticate() and :hello() before using it.
function Connection:initialize(io)
  self.io = io
  self.buf = buffermod()
  self.serial = 0
  self.unique_name = nil
  self.pending = {}      -- serial -> callback(reply_msg)
  self.signal_handlers = {} -- filled in by router.lua
  self.closed = false
  self.loop_mode = false -- set by mainloop; call() yields instead of blocking
  self.on_message = nil  -- hook used by router/mainloop
end

--- Resolve an address target ("session", "system", or a parsed table)
--- and connect + authenticate + Hello. Returns the Connection.
-- Static method: Connection.connect(target).
function Connection.static.connect(target)
  local addr
  if type(target) == "table" then
    addr = target
  else
    local err
    addr, err = address.get(target or "session")
    if not addr then
      return nil, err
    end
  end
  local sock, err = socketio.connect(addr)
  if not sock then
    return nil, "connect failed: " .. err
  end
  local conn = Connection(lsocket_io(sock))
  local guid, aerr = conn:authenticate()
  if not guid then
    conn:close()
    return nil, "authentication failed: " .. aerr
  end
  local name, herr = conn:hello()
  if not name then
    conn:close()
    return nil, "Hello failed: " .. herr.message
  end
  return conn
end

function Connection:next_serial()
  self.serial = (self.serial + 1) % 4294967296
  if self.serial == 0 then
    self.serial = 1
  end
  return self.serial
end

--------------------------------------------------------------------------------
-- SASL authentication
--------------------------------------------------------------------------------

--- Read one "\r\n"-terminated line from the socket (buffered).
local function read_line(io, buf)
  while true do
    local line = buf:read_line()
    if line then
      return line
    end
    if not io.wait_readable(5) then
      return nil, "timeout waiting for auth reply"
    end
    local chunk, err = io.recv()
    if not chunk then
      return nil, err
    end
    if chunk ~= false then
      buf:feed(chunk)
    end
  end
end

function Connection:authenticate()
  local id, err = uid.current_uid()
  if not id then
    return nil, err
  end
  local guid, aerr = auth.negotiate({
    send = function(_, s)
      return self.io:send(s)
    end,
    read_line = function(_)
      return read_line(self.io, self.buf)
    end,
  }, uid.external_identity(id))
  if not guid then
    return nil, aerr
  end
  self.guid = guid
  return guid
end

--- Send Hello and store our unique bus name.
function Connection:hello()
  local values, err = self:call(DBUS_DEST, DBUS_PATH, DBUS_IFACE, "Hello", nil)
  if not values then
    return nil, err
  end
  self.unique_name = values[1]
  return self.unique_name
end

--------------------------------------------------------------------------------
-- Message send/recv
--------------------------------------------------------------------------------

--- Send a complete message table (see message.build opts).
-- Returns true or nil + error message.
function Connection:send(opts)
  opts.serial = opts.serial or self:next_serial()
  local ok, err = self.io:send(message.build(opts))
  if not ok then
    self.closed = true
    return nil, err
  end
  return opts.serial
end

--- Try to extract one message from the buffer.
-- Returns msg table, or false when more data is needed,
-- or nil + error message on protocol errors.
function Connection:_recv_message()
  local header = self.buf:peek(message.fixed_header_len())
  if not header then
    return false
  end
  local total, reason = message.total_len(header)
  if not total then
    return nil, reason
  end
  local raw = self.buf:take(total)
  if not raw then
    return false
  end
  return message.parse(raw)
end

--- Read from io into the buffer once (waiting up to timeout).
-- Returns true on progress, false on timeout/no data.
function Connection:_read_once(timeout)
  local readable = self.io:wait_readable(timeout or 0.1)
  if not readable then
    return false
  end
  local chunk, err = self.io:recv()
  if chunk == nil then
    self.closed = true
    error("connection closed while reading: " .. tostring(err), 0)
  end
  if chunk == false then
    return false
  end
  self.buf:feed(chunk)
  return true
end

--- Dispatch a single incoming message.
-- Replies/errors go to pending callbacks; other messages go through
-- the on_message hook (signals etc., handled by router in mainloop).
function Connection:_dispatch(msg)
  if msg.type == message.TYPE.METHOD_RETURN or msg.type == message.TYPE.ERROR then
    local callback = self.pending[msg.reply_serial]
    if callback then
      self.pending[msg.reply_serial] = nil
      callback(msg)
    end
    return
  end
  if self.on_message then
    self.on_message(msg)
  end
end

--- Process messages until one with `reply_serial == serial` arrives,
--- or the deadline passes. Returns the reply message or nil + reason.
function Connection:pump_until(serial, timeout)
  local deadline = timeout and (os.clock() + timeout) or nil
  while true do
    -- drain messages already buffered
    while true do
      local msg, err = self:_recv_message()
      if not msg then
        if err then
          error("protocol error: " .. err, 0)
        end
        break
      end
      if msg.reply_serial == serial and self.pending[serial] then
        self.pending[serial] = nil
        return msg
      end
      self:_dispatch(msg)
    end
    if deadline and os.clock() > deadline then
      self.pending[serial] = nil
      return nil, "call timed out"
    end
    if self.closed then
      self.pending[serial] = nil
      return nil, "connection closed"
    end
    self:_read_once(0.1)
  end
end

--- Public pump: read and dispatch whatever arrives within timeout.
-- Returns number of messages dispatched (0 on timeout).
function Connection:pump(timeout)
  local count = 0
  while true do
    local msg, err = self:_recv_message()
    if not msg then
      if err then
        error("protocol error: " .. err, 0)
      end
      break
    end
    self:_dispatch(msg)
    count = count + 1
  end
  if self:_read_once(timeout or 0) then
    -- new data may complete buffered messages
    return count + self:pump(0)
  end
  return count
end

--------------------------------------------------------------------------------
-- Method calls
--------------------------------------------------------------------------------

--- Synchronous method call.
-- bus:call(destination, path, interface, member, args, opts)
-- args: list of values matching opts.signature.
-- opts: { signature = "...", timeout = seconds (default 25) }
-- Returns the list of reply values, or nil + err table
-- { name = "com.example.Error", message = "..." }.
-- Inside a mainloop coroutine this yields instead (see scheduler).
function Connection:call(dest, path, iface, member, args, opts)
  opts = opts or {}
  if self.loop_mode then
    -- scheduler hooks this method at runtime (ldbus.mainloop)
    local scheduler_call = self._loop_call
    if scheduler_call then
      return scheduler_call(self, dest, path, iface, member, args, opts)
    end
  end

  local serial = self:send({
    type = message.TYPE.METHOD_CALL,
    path = path,
    interface = iface,
    member = member,
    destination = dest,
    signature = opts.signature or "",
    body = args,
  })

  -- register a trivial reply collector
  local reply
  self.pending[serial] = function(msg)
    reply = msg
  end
  local msg, err = self:pump_until(serial, opts.timeout or 25)
  if not msg then
    return nil, { name = "org.freedesktop.DBus.Error.Timeout", message = err }
  end
  if msg.type == message.TYPE.ERROR then
    return nil, { name = msg.error_name, message = msg.body[1] or "" }
  end
  return msg.body
end

--- Fire-and-forget call (no reply expected).
function Connection:call_noreply(dest, path, iface, member, args, opts)
  opts = opts or {}
  return self:send({
    type = message.TYPE.METHOD_CALL,
    path = path,
    interface = iface,
    member = member,
    destination = dest,
    signature = opts.signature or "",
    body = args,
    flags = message.FLAG.NO_REPLY_EXPECTED,
  })
end

function Connection:close()
  if not self.closed then
    self.closed = true
    self.io:close()
  end
end

return Connection
