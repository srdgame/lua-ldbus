--- Shared helpers for the bluez GATT server modules (gatt_server +
-- gatt_descriptor): options unwrapping, authorize callbacks, properties
-- export and safe user-callback invocation.
--
-- @module bluez.gatt_common

local ldbus = require "ldbus"
local bluez = require "bluez"

local common = {}

common.GATT_APP_IFACE = "org.bluez.GattApplication1"
common.GATT_SERVICE_IFACE = "org.bluez.GattService1"
common.GATT_CHAR_IFACE = "org.bluez.GattCharacteristic1"
common.GATT_DESC_IFACE = "org.bluez.GattDescriptor1"
common.NOT_AUTHORIZED = "org.bluez.Error.NotAuthorized"

--- Export org.freedesktop.DBus.Properties Get/GetAll backed by getters.
function common.export_properties(obj, get, getall)
  obj:method(bluez.PROPS .. ".Get", "ss", "v", function(_, name)
    local v = get(name)
    if v == nil then
      error("no such property: " .. tostring(name))
    end
    return v
  end)
  obj:method(bluez.PROPS .. ".GetAll", "s", "a{sv}", function()
    return getall()
  end)
end

--- Resolve an adapter argument (path string or Adapter handle) to a path.
function common.adapter_path(adapter)
  return type(adapter) == "table" and adapter:path() or adapter
end

--- Resolve an object path to a Device handle when the device is in the
-- ObjectManager cache; otherwise return the path string unchanged
-- (cache-only: never does I/O).
function common.resolve_device(bt, path)
  local entry = bt._objects[path]
  if entry and entry[bluez.DEVICE] then
    return bluez.Device(bt, path, bluez.DEVICE)
  end
  return path
end

--- Unwrap a ReadValue/WriteValue a{sv} options table into a new plain
-- table: variant tags are stripped (offset/mtu become numbers, ...), and
-- the `device` key additionally resolves to a Device handle when the
-- device is cached (a path string otherwise). Returns a new table;
-- the input is never modified.
function common.unwrap_opts(raw, bt)
  local out = {}
  if raw then
    for k, v in pairs(raw) do
      local value = bluez.unwrap(v)
      if k == "device" then
        value = common.resolve_device(bt, value)
      end
      out[k] = value
    end
  end
  return out
end

--- Run the effective authorize callback: the object-level on_authorize
-- overrides the application-level one. `fn(obj, op, device, opts)` --
-- returning false raises org.bluez.Error.NotAuthorized (router turns it
-- into the D-Bus error reply); a callback raising its own error
-- propagates unchanged (allowing custom error replies).
function common.authorize(obj, op, opts)
  local owner = obj.service or obj.char.service
  local fn = obj.on_authorize or owner.app._on_authorize
  if not fn then
    return true
  end
  local allow = fn(obj, op, opts.device, opts)
  if allow == false then
    error(ldbus.errors.new(common.NOT_AUTHORIZED,
      op .. " rejected by on_authorize"))
  end
  return true
end

--- Run a user callback, reporting (not propagating) errors so a faulty
-- callback never kills the mainloop.
function common.pcall_safe(fn, ...)
  if not fn then
    return
  end
  local ok, err = pcall(fn, ...)
  if not ok then
    io.stderr:write("bluez: callback error: ", tostring(err), "\n")
  end
end

return common
