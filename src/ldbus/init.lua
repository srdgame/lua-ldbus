--- ldbus: a pure Lua 5.4 D-Bus implementation.
-- Public entry point: connect to a bus and get a Bus object with an
-- idiomatic Lua API for method calls, exported objects, signals, and
-- name ownership.
-- @module ldbus

local Connection = require "ldbus.connection"
local router = require "ldbus.router"
local errors = require "ldbus.errors"
local name = require "ldbus.name"
local mainloop = require "ldbus.mainloop"

local ldbus = {
  _VERSION = "ldbus 0.1.0",
  flags = name.FLAG,
  result = name.RESULT,
  errors = errors,
}

local DBUS_DEST = "org.freedesktop.DBus"
local DBUS_PATH = "/org/freedesktop/DBus"
local DBUS_IFACE = "org.freedesktop.DBus"

--------------------------------------------------------------------------------
-- Bus wrapper
--------------------------------------------------------------------------------

local Bus = {}
Bus.__index = Bus

--- Wrap a Connection into the high-level Bus API.
function ldbus.wrap(conn)
  router.attach(conn)
  return setmetatable({ conn = conn }, Bus)
end

--- Connect and return a Bus, or nil + error message.
-- target: "session", "system", an address string, or a parsed address table.
function ldbus.connect(target)
  local conn, err = Connection.connect(target or "session")
  if not conn then
    return nil, err
  end
  return ldbus.wrap(conn)
end

--- Connect to the session bus (DBUS_SESSION_BUS_ADDRESS).
function ldbus.session()
  return ldbus.connect("session")
end

--- Connect to the system bus (DBUS_SYSTEM_BUS_ADDRESS or the default path).
function ldbus.system()
  return ldbus.connect("system")
end

--- Synchronous (or, inside a mainloop, yielding) method call.
-- Same arguments as Connection:call; returns reply values or nil + err table.
function Bus:call(dest, path, iface, member, args, opts)
  return self.conn:call(dest, path, iface, member, args, opts)
end

--- Fire-and-forget method call (NO_REPLY_EXPECTED).
function Bus:call_noreply(dest, path, iface, member, args, opts)
  return self.conn:call_noreply(dest, path, iface, member, args, opts)
end

--- Export an object at an object path. Returns a handle whose
--- :method(member, in_sig, out_sig, fn) registers handlers.
function Bus:object(path)
  local handle = { conn = self.conn }
  handle.methods = router.object(self.conn, path).methods

  --- Register a method handler: fn(decoded_args...) -> reply values.
  function handle:method(member, in_sig, out_sig, fn)
    return router.method(handle, member, in_sig, out_sig, fn)
  end

  --- Declare a signal (metadata only; used by introspection).
  function handle:signal(member, sig)
    handle.signals = handle.signals or {}
    handle.signals[#handle.signals + 1] = { member = member, signature = sig or "" }
    return handle.signals[#handle.signals]
  end

  return handle
end

--- Emit a signal. Signature/values may be given as (sig, values) or as
--- a single { signature = "...", value = ... } table.
function Bus:emit(path, iface, member, a, b)
  local sig, values
  if type(a) == "table" and a.signature then
    sig, values = a.signature, { a.value }
  else
    sig, values = a or "", b
  end
  return router.emit(self.conn, path, iface, member, sig, values)
end

--- Subscribe to a signal. Performs AddMatch on the bus unless
--- opts.add_match is false (useful for tests / peer-filtered buses).
function Bus:on_signal(iface, member, fn, opts)
  if not (opts and opts.add_match == false) then
    router.add_match(self.conn, name.match_signal(iface, member))
  end
  return router.on_signal(self.conn, iface, member, fn)
end

--- Request a well-known name. Returns the RequestName result code
--- (ldbus.result.PRIMARY_OWNER / IN_QUEUE / EXISTS), or nil + err table.
function Bus:request_name(bus_name, flags)
  local values, err = self.conn:call(DBUS_DEST, DBUS_PATH, DBUS_IFACE,
    "RequestName", { bus_name, flags or 0 }, { signature = "su" })
  if not values then
    return nil, err
  end
  return values[1]
end

--- Release a previously requested name. Returns the release code.
function Bus:release_name(bus_name)
  local values, err = self.conn:call(DBUS_DEST, DBUS_PATH, DBUS_IFACE,
    "ReleaseName", { bus_name }, { signature = "s" })
  if not values then
    return nil, err
  end
  return values[1]
end

--- Process pending incoming messages for up to `timeout` seconds.
-- Returns the number of messages dispatched (0 on timeout).
function Bus:pump(timeout)
  return self.conn:pump(timeout)
end

--- Run the coroutine mainloop on this bus (see ldbus.mainloop.run).
-- Inside the loop bus:call() yields and handlers run as coroutines.
function Bus:mainloop(opts)
  return mainloop.run(self, opts)
end

--- Stop the mainloop running on this bus.
function Bus:quit()
  self._quit = true
end

--- Close the connection.
function Bus:close()
  self.conn:close()
end

--- Run the mainloop over one bus or a list of buses (they share one
--- scheduler). See ldbus.mainloop.run for opts.
function ldbus.mainloop(buses, opts)
  return mainloop.run(buses, opts)
end

return ldbus
