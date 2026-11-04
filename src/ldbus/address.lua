--- D-Bus address parsing.
-- Handles the DBUS_SESSION_BUS_ADDRESS / DBUS_STARTER_ADDRESS /
-- DBUS_SYSTEM_BUS_ADDRESS environment variables and their
-- "transport:key=value,key=value;transport:..." syntax.
-- @module ldbus.address

local address = {}

--- Parse an address string, returning the first viable transport.
-- Returns a table like:
--   { transport = "unix", path = "/tmp/bus" }
--   { transport = "unix", abstract = "foo" }
--   { transport = "tcp",  host = "127.0.0.1", port = "1234" }
-- or nil + error message when no usable transport is found.
function address.parse(str)
  if type(str) ~= "string" or #str == 0 then
    return nil, "empty address string"
  end
  local last_err
  for entry in str:gmatch("[^;]+") do
    local transport, rest = entry:match("^([^:]+):(.*)$")
    if transport == "unix" then
      local t = { transport = "unix" }
      for kv in rest:gmatch("[^,]+") do
        local k, v = kv:match("^([^=]+)=(.*)$")
        if k then
          t[k] = v
        end
      end
      if t.path then
        return t
      elseif t.abstract then
        return t
      elseif t.dir then
        return nil, "unix dir transport not supported"
      else
        last_err = "unix transport without path/abstract: " .. entry
      end
    elseif transport == "tcp" then
      local t = { transport = "tcp" }
      for kv in rest:gmatch("[^,]+") do
        local k, v = kv:match("^([^=]+)=(.*)$")
        if k then
          t[k] = v
        end
      end
      if t.host and t.port then
        return t
      else
        last_err = "tcp transport without host/port: " .. entry
      end
    else
      last_err = "unsupported transport: " .. tostring(transport)
    end
  end
  return nil, last_err or ("no transport in address: " .. str)
end

--- Resolve the address for a bus type ("session" or "system").
-- `env` optionally overrides os.getenv (for testing).
-- DBUS_STARTER_ADDRESS is the fallback used by dbus-run-session.
function address.get(bus_type, env)
  local getenv = env and function(k) return env[k] end or os.getenv
  if bus_type == "session" then
    local addr = getenv("DBUS_SESSION_BUS_ADDRESS") or getenv("DBUS_STARTER_ADDRESS")
    if not addr then
      return nil, "DBUS_SESSION_BUS_ADDRESS is not set"
    end
    return address.parse(addr)
  elseif bus_type == "system" then
    local addr = getenv("DBUS_SYSTEM_BUS_ADDRESS")
        or "unix:path=/var/run/dbus/system_bus_socket"
    return address.parse(addr)
  end
  return nil, "unknown bus type: " .. tostring(bus_type)
end

return address
