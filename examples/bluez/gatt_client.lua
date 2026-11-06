--- bluez.gatt_client: GATT client-side API (org.bluez.GattService1 /
-- GattCharacteristic1). Extends the bluez client with cached enumeration
-- and live characteristic I/O:
--
--   local bluez = require "bluez"  -- loads gatt_client automatically
--   local svc = bt:find_service("180f")
--   local bat = bt:find_characteristic("2a19", svc)
--   print(bat:read_value())                    -- ReadValue -> Lua string
--   bat:write_value("\42")                     -- WriteValue
--   local unsub = bat:subscribe(function(v) print("value:", v) end)
--   ...
--   unsub()
--
-- Characteristics must already be in the ObjectManager cache (connect to
-- the device first, or scan with discovery running). Values are exposed
-- as Lua strings; the "ay" wire format is converted for you.
--
-- @module bluez.gatt_client

local bluez = require "bluez"

local to_bytes = bluez.to_bytes
local from_bytes = bluez.from_bytes
local expand_uuid = bluez.expand_uuid

--------------------------------------------------------------------------------
-- GattService (org.bluez.GattService1)
--------------------------------------------------------------------------------

local GattService = bluez.Object:subclass("GattService")

--- The Device this service belongs to, or nil for locally-shared services.
function GattService:device()
  local dev_path = self:get_prop("Device")
  if not dev_path then
    return nil
  end
  return bluez.Device(self._bt, dev_path, bluez.DEVICE)
end

--- Cached characteristic handles under this service (sorted by path).
function GattService:characteristics()
  return self._bt:characteristics(self)
end

--------------------------------------------------------------------------------
-- GattCharacteristic (org.bluez.GattCharacteristic1)
--------------------------------------------------------------------------------

local GattCharacteristic = bluez.Object:subclass("GattCharacteristic")

--- The service object this characteristic belongs to.
function GattCharacteristic:service()
  local svc_path = self:get_prop("Service")
  if not svc_path then
    return nil
  end
  return GattService(self._bt, svc_path, bluez.GATT_SERVICE)
end

--- ReadValue: returns the current value as a Lua string, or nil + err.
-- `opts` maps to the a{sv} options argument (offset, mtu, ...).
function GattCharacteristic:read_value(opts)
  local values, err = self:call("ReadValue", { opts or {} },
                                { signature = "a{sv}" })
  if not values then
    return nil, err
  end
  return from_bytes(values[1])
end

--- WriteValue. `data` is a Lua string (or table of byte integers);
-- `opts` maps to the a{sv} options argument (type, offset, ...).
-- Returns true, or nil + err.
function GattCharacteristic:write_value(data, opts)
  local values, err = self:call("WriteValue",
    { to_bytes(data), opts or {} }, { signature = "aya{sv}" })
  if not values then
    return nil, err
  end
  return true
end

--- AcquireNotify (BlueZ >= 5.53): returns a socket-based subscription
-- handle is NOT supported by ldbus; use :subscribe() instead.
function GattCharacteristic:acquire_notify()
  return nil, { name = "org.bluez.Error.NotSupported",
                message = "AcquireNotify is not supported; use subscribe()" }
end

--- Start notifications without a Lua callback (see :subscribe).
-- Returns true, or nil + err.
function GattCharacteristic:start_notify()
  local values, err = self:call("StartNotify")
  if not values then
    return nil, err
  end
  return true
end

--- Stop notifications.
function GattCharacteristic:stop_notify()
  return self:call("StopNotify")
end

--- Subscribe to value updates: StartNotify + a PropertiesChanged listener
-- for this exact object path. `cb(value)` receives each new value as a
-- Lua string. Returns an unsubscribe function (StopNotify + cleanup).
-- Requires a running mainloop (ldbus.mainloop / bus:mainloop).
function GattCharacteristic:subscribe(cb)
  local ok, err = self:start_notify()
  if not ok then
    return nil, err
  end
  local path = self._path
  local handler
  handler = function(msg)
    if msg.path ~= path then
      return
    end
    local changed = msg.body[2]
    if changed and changed.Value ~= nil then
      cb(from_bytes(bluez.unwrap(changed.Value)))
    end
  end
  self._bt.bus:on_signal(bluez.PROPS, "PropertiesChanged", handler,
                         { add_match = false })  -- client already matched PROPS
  return function()
    self._bt.bus:off_signal(bluez.PROPS, "PropertiesChanged", handler)
    self:stop_notify()
  end
end

--- The last value seen in the signal-fed cache, or nil.
function GattCharacteristic:value()
  return self:get_prop("Value")
end

--------------------------------------------------------------------------------
-- client-side enumeration helpers (added to bluez.Bluez)
--------------------------------------------------------------------------------

--- Cached GATT services, optionally limited to one device
-- (path string or Device handle). Returns a sorted list of GattService.
function bluez.Bluez:services(device)
  local prefix = type(device) == "table" and device:path() or device
  return self:_collect(bluez.GATT_SERVICE, GattService, prefix)
end

--- Cached characteristics, optionally limited to one service
-- (path string or GattService handle). Returns a sorted list.
function bluez.Bluez:characteristics(service)
  local prefix = type(service) == "table" and service:path() or service
  return self:_collect(bluez.GATT_CHAR, GattCharacteristic, prefix)
end

--- Find a cached service by UUID. Short SIG UUIDs ("180f") are expanded
-- to the 128-bit form. `device` (path or handle) narrows the search.
-- Cache-only: never does I/O.
function bluez.Bluez:find_service(uuid, device)
  local want = expand_uuid(uuid)
  local prefix = type(device) == "table" and device:path() or device
  for path, entry in pairs(self._objects) do
    local props = entry[bluez.GATT_SERVICE]
    if props and props.UUID == want
        and (not prefix or path:sub(1, #prefix + 1) == prefix .. "/") then
      return GattService(self, path, bluez.GATT_SERVICE)
    end
  end
  return nil
end

--- Find a cached characteristic by UUID; `service` (path or handle)
-- narrows the search. Cache-only: never does I/O.
function bluez.Bluez:find_characteristic(uuid, service)
  local want = expand_uuid(uuid)
  local prefix = type(service) == "table" and service:path() or service
  for path, entry in pairs(self._objects) do
    local props = entry[bluez.GATT_CHAR]
    if props and props.UUID == want
        and (not prefix or path:sub(1, #prefix + 1) == prefix .. "/") then
      return GattCharacteristic(self, path, bluez.GATT_CHAR)
    end
  end
  return nil
end

bluez.GattService = GattService
bluez.GattCharacteristic = GattCharacteristic

return true
