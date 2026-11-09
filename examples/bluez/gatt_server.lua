--- bluez.gatt_server: GATT server (peripheral role) and LE advertisement
-- support. Exports local GATT objects over D-Bus and registers them with
-- bluetoothd via org.bluez.GattManager1 / org.bluez.LEAdvertisingManager1.
--
--   local bluez = require "bluez"   -- loads gatt_server automatically
--   local app = bluez.Application(bt, "/com/example/gatt")
--   local svc = app:service("180f")
--   local bat = svc:characteristic("2a19", { "read", "write", "notify" }, {
--     on_read  = function(opts) return "\42" end,       -- return value
--     on_write = function(value, opts) ... end,         -- receives string
--   })
--   app:register(bt:default_adapter())
--
--   local adv = bluez.Advertisement(bt, "/com/example/adv", {
--     local_name = "MyDevice", service_uuids = { "180f" },
--     min_interval = 100, max_interval = 200,
--   })
--   adv:register(bt:default_adapter())
--   adv:update{ LocalName = "Renamed" }  -- runtime parameter change
--
-- bluetoothd calls back into our exported objects, so a mainloop must be
-- running (ldbus.mainloop / bus:mainloop) while registered.
--
-- @module bluez.gatt_server

local ldbus = require "ldbus"
local bluez = require "bluez"

-- middleclass: same lookup strategy as the core module.
if not pcall(require, "middleclass") then
  package.path = "middleclass/?.lua;" .. package.path
end
local middleclass = require "middleclass"

local to_bytes = bluez.to_bytes
local from_bytes = bluez.from_bytes

local GATT_APP_IFACE = "org.bluez.GattApplication1"
local GATT_SERVICE_IFACE = "org.bluez.GattService1"
local GATT_CHAR_IFACE = "org.bluez.GattCharacteristic1"
local ADV_IFACE = "org.bluez.LEAdvertisement1"

--- Export org.freedesktop.DBus.Properties Get/GetAll backed by getters.
local function export_properties(obj, get, getall)
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
local function adapter_path(adapter)
  return type(adapter) == "table" and adapter:path() or adapter
end

--------------------------------------------------------------------------------
-- LocalCharacteristic: one exported org.bluez.GattCharacteristic1 object
--------------------------------------------------------------------------------

local LocalCharacteristic = middleclass("LocalCharacteristic")

function LocalCharacteristic:initialize(service, uuid, path, flags, handlers)
  handlers = handlers or {}
  self.service = service
  self.uuid = uuid
  self._path = path
  self.flags = flags or {}
  self.on_read = handlers.on_read
  self.on_write = handlers.on_write
  self._value = handlers.value
  self._notifying = false

  local obj = service.app.bt.bus:object(path)

  export_properties(obj,
    function(name) return self:_prop(name) end,
    function() return self:_props() end)

  obj:method(GATT_CHAR_IFACE .. ".ReadValue", "a{sv}", "ay", function(opts)
    if self.on_read then
      return to_bytes(self.on_read(opts))
    end
    if self._value ~= nil then
      return to_bytes(self._value)
    end
    error("reading not supported")
  end)

  obj:method(GATT_CHAR_IFACE .. ".WriteValue", "aya{sv}", "",
    function(bytes, opts)
      local value = from_bytes(bytes)
      self._value = value
      if self.on_write then
        self.on_write(value, opts)
      end
      if self._notifying then
        self:_emit_value()
      end
    end)

  obj:method(GATT_CHAR_IFACE .. ".StartNotify", "", "", function()
    self._notifying = true
    if self._value ~= nil then
      self:_emit_value()
    end
  end)

  obj:method(GATT_CHAR_IFACE .. ".StopNotify", "", "", function()
    self._notifying = false
  end)
end

--- The D-Bus object path of this characteristic.
function LocalCharacteristic:path()
  return self._path
end

local BASE_PROPS = { UUID = "s", Service = "o", Flags = "as" }

function LocalCharacteristic:_prop(name)
  local kind = BASE_PROPS[name]
  if kind then
    return ldbus.variant(kind, name == "Flags" and self.flags
      or name == "UUID" and self.uuid or self.service._path)
  end
  if name == "Value" and self._value ~= nil then
    return ldbus.variant("ay", to_bytes(self._value))
  end
  return nil
end

function LocalCharacteristic:_props()
  local out = {}
  for name in pairs(BASE_PROPS) do
    out[name] = self:_prop(name)
  end
  if self._value ~= nil then
    out.Value = ldbus.variant("ay", to_bytes(self._value))
  end
  return out
end

--- Emit PropertiesChanged(Value) so subscribed centrators receive it.
function LocalCharacteristic:_emit_value()
  self.service.app.bt.bus:emit(self._path, bluez.PROPS, "PropertiesChanged",
    "sa{sv}as",
    { GATT_CHAR_IFACE, { Value = ldbus.variant("ay", to_bytes(self._value)) }, {} })
end

--- Push a new value to subscribed peers (and update the local cache).
-- `value` is a Lua string (or table of byte integers).
function LocalCharacteristic:notify(value)
  self._value = value
  if self._notifying then
    self:_emit_value()
  end
end

--------------------------------------------------------------------------------
-- LocalService: one exported org.bluez.GattService1 object
--------------------------------------------------------------------------------

local LocalService = middleclass("LocalService")

function LocalService:initialize(app, uuid, path, opts)
  opts = opts or {}
  self.app = app
  self.uuid = uuid
  self._path = path
  self._primary = opts.primary ~= false
  self._chars = {}
  self._nchars = 0

  local props = {
    UUID = ldbus.variant("s", uuid),
    Primary = ldbus.variant("b", self._primary),
  }
  export_properties(app.bt.bus:object(path),
    function(name) return props[name] end,
    function() return props end)
end

--- The D-Bus object path of this service.
function LocalService:path()
  return self._path
end

--- Add a characteristic. `flags` is the D-Bus flags array, e.g.
-- { "read", "write", "notify", "write-without-response", "indicate" }.
-- `handlers`: { on_read = fn(opts) -> value, on_write = fn(value, opts),
-- value = initial value }. Returns the LocalCharacteristic.
function LocalService:characteristic(uuid, flags, handlers)
  self._nchars = self._nchars + 1
  local ch = LocalCharacteristic(self, uuid,
    self._path .. "/char" .. self._nchars, flags, handlers)
  self._chars[#self._chars + 1] = ch
  return ch
end

--------------------------------------------------------------------------------
-- Application: exported GATT app (ObjectManager root) + registration
--------------------------------------------------------------------------------

local Application = middleclass("Application")

--- Create a GATT application bound to `path` (a unique object path prefix
-- on our bus, e.g. "/com/example/gatt").
function Application:initialize(bt, path)
  self.bt = bt
  self._path = path
  self._services = {}
  self._nservices = 0

  bt.bus:object(path):method(bluez.OM .. ".GetManagedObjects", "",
    "a{oa{sa{sv}}}", function()
      return self:_managed_objects()
    end)
end

--- Add a service. Returns the LocalService. `opts`:
-- { primary = true (default) }.
function Application:service(uuid, opts)
  self._nservices = self._nservices + 1
  local svc = LocalService(self, uuid,
    self._path .. "/service" .. self._nservices, opts)
  self._services[#self._services + 1] = svc
  return svc
end

--- The root D-Bus object path of this application.
function Application:path()
  return self._path
end

function Application:_managed_objects()
  local out = {}
  for _, svc in ipairs(self._services) do
    out[svc._path] = {
      [GATT_SERVICE_IFACE] = {
        UUID = ldbus.variant("s", svc.uuid),
        Primary = ldbus.variant("b", svc._primary),
      },
    }
    for _, ch in ipairs(svc._chars) do
      out[ch._path] = { [GATT_CHAR_IFACE] = ch:_props() }
    end
  end
  return out
end

--- Register with bluetoothd via org.bluez.GattManager1 (adapter may be a
-- path string or Adapter handle). Requires a running mainloop.
function Application:register(adapter)
  local values, err = self.bt.bus:call(bluez.SERVICE, adapter_path(adapter),
    bluez.GATT_MANAGER, "RegisterApplication",
    { self._path, {} }, { signature = "oa{sv}" })
  if not values then
    return nil, err
  end
  return true
end

function Application:unregister(adapter)
  local values, err = self.bt.bus:call(bluez.SERVICE, adapter_path(adapter),
    bluez.GATT_MANAGER, "UnregisterApplication",
    { self._path }, { signature = "o" })
  if not values then
    return nil, err
  end
  return true
end

--------------------------------------------------------------------------------
-- Advertisement: exported org.bluez.LEAdvertisement1 + registration
--------------------------------------------------------------------------------

local Advertisement = middleclass("Advertisement")

--- Create an LE advertisement object. `opts`:
--   type          = "peripheral" (default) or "broadcast"
--   local_name    = "MyDevice"
--   service_uuids = { "180f", ... }
--   solicit_uuids = { "180f", ... }
--   includes      = { "tx-power" }      -- do NOT combine "local-name"
--                                        -- with local_name (BlueZ rejects)
--   discoverable  = true
--   discoverable_timeout = 30            -- seconds (uint16, BlueZ >= 5.54)
--   manufacturer_data = { [0x0059] = bytes }   -- a{qv}: uint16 id -> ay
--   appearance    = 962                  -- uint16 category (BlueZ >= 5.55)
--   duration      = 4                    -- seconds per slot (BlueZ >= 5.63)
--   timeout       = 60                   -- overall seconds (BlueZ >= 5.63)
--   min_interval  = 100                  -- ms (BlueZ >= 5.64)
--   max_interval  = 200                  -- ms (BlueZ >= 5.64)
function Advertisement:initialize(bt, path, opts)
  opts = opts or {}
  self.bt = bt
  self._path = path
  self._props = {
    Type = ldbus.variant("s", opts.type or "peripheral"),
  }
  if opts.local_name then
    self._props.LocalName = ldbus.variant("s", opts.local_name)
  end
  if opts.service_uuids then
    self._props.ServiceUUIDs = ldbus.variant("as", opts.service_uuids)
  end
  if opts.solicit_uuids then
    self._props.SolicitUUIDs = ldbus.variant("as", opts.solicit_uuids)
  end
  if opts.includes then
    self._props.Includes = ldbus.variant("as", opts.includes)
  end
  if opts.discoverable ~= nil then
    self._props.Discoverable = ldbus.variant("b", opts.discoverable)
  end
  if opts.discoverable_timeout ~= nil then
    -- bluetoothd expects uint16 here (not uint32)
    self._props.DiscoverableTimeout = ldbus.variant("q", opts.discoverable_timeout)
  end
  if opts.manufacturer_data then
    -- LEAdvertisement1 ManufacturerData is a{qv}: uint16 manufacturer id
    -- -> variant wrapping an array of bytes
    local md = {}
    for k, v in pairs(opts.manufacturer_data) do
      md[k] = ldbus.variant("ay", to_bytes(v))
    end
    self._props.ManufacturerData = ldbus.variant("a{qv}", md)
  end
  if opts.appearance then
    self._props.Appearance = ldbus.variant("q", opts.appearance)
  end
  if opts.duration then
    self._props.Duration = ldbus.variant("q", opts.duration)
  end
  if opts.timeout then
    self._props.Timeout = ldbus.variant("q", opts.timeout)
  end
  if opts.min_interval then
    self._props.MinInterval = ldbus.variant("u", opts.min_interval)
  end
  if opts.max_interval then
    self._props.MaxInterval = ldbus.variant("u", opts.max_interval)
  end

  export_properties(bt.bus:object(path),
    function(name) return self._props[name] end,
    function() return self._props end)
end

--- The D-Bus object path of this advertisement.
function Advertisement:path()
  return self._path
end

--- Register via org.bluez.LEAdvertisingManager1 (adapter may be a path
-- string or Adapter handle). Requires a running mainloop.
function Advertisement:register(adapter)
  local values, err = self.bt.bus:call(bluez.SERVICE, adapter_path(adapter),
    bluez.ADV_MANAGER, "RegisterAdvertisement",
    { self._path, {} }, { signature = "oa{sv}" })
  if not values then
    return nil, err
  end
  return true
end

function Advertisement:unregister(adapter)
  local values, err = self.bt.bus:call(bluez.SERVICE, adapter_path(adapter),
    bluez.ADV_MANAGER, "UnregisterAdvertisement",
    { self._path }, { signature = "o" })
  if not values then
    return nil, err
  end
  return true
end

--- Change advertisement properties at runtime. `props` keys are D-Bus
-- property names (LocalName, Includes, MinInterval, DiscoverableTimeout,
-- ...); plain values are auto-wrapped. Emits PropertiesChanged so
-- bluetoothd applies the change while the advertisement is registered.
-- Returns true, or nil + err.
function Advertisement:update(props)
  local changed = {}
  for k, v in pairs(props) do
    local var = bluez.auto_variant(v)
    self._props[k] = var
    changed[k] = var
  end
  self.bt.bus:emit(self._path, bluez.PROPS, "PropertiesChanged",
    "sa{sv}as", { ADV_IFACE, changed, {} })
  return true
end

--------------------------------------------------------------------------------
-- module surface
--------------------------------------------------------------------------------

bluez.Application = Application
bluez.LocalService = LocalService
bluez.LocalCharacteristic = LocalCharacteristic
bluez.Advertisement = Advertisement

return true
