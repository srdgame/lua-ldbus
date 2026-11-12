--- bluez: idiomatic Lua wrapper for the org.bluez D-Bus API (BlueZ 5).
-- Built on ldbus (and middleclass for the class hierarchy), talks to the
-- system bus. Objects expose properties via explicit accessors
-- (`adapter:get_prop("Powered")`, `adapter:set_prop("Powered", true)`)
-- and methods as regular calls (`adapter:start_discovery()`). The
-- ObjectManager view is cached
-- and kept fresh via InterfacesAdded/InterfacesRemoved and
-- PropertiesChanged signals, so `bt:devices()` never does I/O.
--
-- This is the core module: adapter/device enumeration and control,
-- Adapter1 property accessors and the one-call LE advertising toggle.
-- GATT client helpers live in `bluez.gatt_client`; GATT server and LE
-- advertisement support lives in `bluez.gatt_server`. Both are loaded
-- automatically.
--
-- Usage:
--   local bluez = require "bluez"
--   local bt = bluez.new()
--   local adapter = bt:default_adapter()
--   adapter:set_prop("Powered", true)
--   adapter:start_discovery()
--   for _, dev in ipairs(bt:devices()) do print(dev:label()) end
--
-- @module bluez

local ldbus = require "ldbus"

-- middleclass: prefer an installed copy, fall back to the git submodule
-- in this repository.
if not pcall(require, "middleclass") then
  package.path = "middleclass/?.lua;" .. package.path
end
local middleclass = require "middleclass"

local bluez = {
  SERVICE = "org.bluez",
  ROOT = "/",
  OM = "org.freedesktop.DBus.ObjectManager",
  PROPS = "org.freedesktop.DBus.Properties",
  ADAPTER = "org.bluez.Adapter1",
  DEVICE = "org.bluez.Device1",
  GATT_SERVICE = "org.bluez.GattService1",
  GATT_CHAR = "org.bluez.GattCharacteristic1",
  GATT_DESC = "org.bluez.GattDescriptor1",
  GATT_MANAGER = "org.bluez.GattManager1",
  ADV_MANAGER = "org.bluez.LEAdvertisingManager1",
}

--------------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------------

--- Strip the variant tag: `variant table -> value`, anything else passes through.
local function unwrap(v)
  if type(v) == "table" and v._dbus_variant then
    return v.value
  end
  return v
end

--- Map a plain Lua value to a D-Bus variant for a{sv} dicts and Set calls.
-- Booleans -> "b", strings -> "s", integers -> "u", floats -> "d",
-- tables -> "as" (string array). Explicit ldbus.variant values pass through.
local function auto_variant(v)
  if type(v) == "table" and v._dbus_variant then
    return v
  end
  local t = type(v)
  if t == "boolean" then return ldbus.variant("b", v) end
  if t == "string" then return ldbus.variant("s", v) end
  if math.type(v) == "integer" then return ldbus.variant("u", v) end
  if math.type(v) == "float" then return ldbus.variant("d", v) end
  if t == "table" then return ldbus.variant("as", v) end
  error("cannot map Lua value of type " .. t .. " to a D-Bus variant", 2)
end

--- GATT byte arrays ("ay") <-> Lua strings. The library API accepts and
-- returns plain strings for characteristic values; the wire format is a
-- byte array.
local function to_bytes(v)
  if type(v) == "string" then
    local out = {}
    for i = 1, #v do
      out[i] = v:byte(i)
    end
    return out
  end
  return v
end

local function from_bytes(v)
  if type(v) == "table" then
    return string.char(table.unpack(v, 1, #v))
  end
  return v
end

--- Expand a Bluetooth SIG short UUID ("180f", "2a19") to its full
-- 128-bit form; full UUIDs pass through (case-normalized).
local function expand_uuid(uuid)
  uuid = uuid:lower()
  if #uuid == 4 then
    return "0000" .. uuid .. "-0000-1000-8000-00805f9b34fb"
  end
  return uuid
end

--------------------------------------------------------------------------------
-- Object: shared base for Adapter and Device (explicit property accessors)
--------------------------------------------------------------------------------

local Object = middleclass("Object")

function Object:initialize(bt, path, iface)
  self._bt = bt
  self._path = path
  self._iface = iface
end

--- The D-Bus object path of this adapter/device.
function Object:path()
  return self._path
end

--- Call a method of this object's primary interface.
-- Returns the reply values, or nil + err table on a D-Bus error.
function Object:call(member, args, opts)
  return self._bt.bus:call(bluez.SERVICE, self._path, self._iface,
                           member, args, opts)
end

--- Read a property: live Properties.Get first, falling back to the
-- ObjectManager cache (kept fresh by signals). Returns value or nil + err.
function Object:get_prop(name)
  local values, err = self._bt.bus:call(bluez.SERVICE, self._path,
    bluez.PROPS, "Get", { self._iface, name }, { signature = "ss" })
  if values then
    return unwrap(values[1])
  end
  local cached = self._bt._objects[self._path]
  if cached and cached[self._iface] then
    local v = cached[self._iface][name]
    if v ~= nil then
      return v
    end
  end
  return nil, err
end

--- Write a property (`value` may be a plain value or an ldbus.variant).
-- Returns true on success, or nil + err table.
function Object:set_prop(name, value)
  local values, err = self._bt.bus:call(bluez.SERVICE, self._path,
    bluez.PROPS, "Set", { self._iface, name, auto_variant(value) },
    { signature = "ssv" })
  if not values then
    return nil, err
  end
  return true
end

--------------------------------------------------------------------------------
-- Adapter (org.bluez.Adapter1)
--------------------------------------------------------------------------------

local Adapter = Object:subclass("Adapter")

--- Start LE/BR/EDR discovery on this adapter.
function Adapter:start_discovery()
  return self:call("StartDiscovery")
end

--- Stop discovery.
function Adapter:stop_discovery()
  return self:call("StopDiscovery")
end

--- Set the discovery filter. Keys use the D-Bus property names, plain
-- values are auto-wrapped: e.g. `{ UUIDs = {...}, Transport = "le" }`.
function Adapter:set_discovery_filter(filter)
  local svs = {}
  for k, v in pairs(filter) do
    svs[k] = auto_variant(v)
  end
  return self:call("SetDiscoveryFilter", { svs }, { signature = "a{sv}" })
end

--- Remove a device (and its pairing) from this adapter.
-- Accepts an object path string or a Device handle.
function Adapter:remove_device(dev)
  local path = type(dev) == "table" and dev:path() or dev
  return self:call("RemoveDevice", { path }, { signature = "o" })
end

--------------------------------------------------------------------------------
-- Adapter: common Adapter1 property accessors
--------------------------------------------------------------------------------

--- The adapter's Bluetooth MAC address (Address property).
function Adapter:address()
  return self:get_prop("Address")
end

--- True when the adapter is powered on.
function Adapter:is_powered()
  return self:get_prop("Powered") == true
end

--- Power the adapter on/off.
function Adapter:set_powered(on)
  return self:set_prop("Powered", on and true or false)
end

--- True while a discovery scan is running on this adapter.
function Adapter:is_discovering()
  return self:get_prop("Discovering") == true
end

--- Set the adapter's human-friendly name (Alias property).
function Adapter:set_name(alias)
  return self:set_prop("Alias", alias)
end

--- Current display name: Alias, then Name. (Named `display_name` because
-- `name` collides with middleclass's internal class-name attribute.)
function Adapter:display_name()
  return self:get_prop("Alias") or self:get_prop("Name")
end

--- Enable/disable discoverability. `timeout` is the visibility window in
-- seconds (0 = always discoverable); omit it to leave the timeout unchanged.
function Adapter:set_discoverable(on, timeout)
  local ok, err = self:set_prop("Discoverable", on and true or false)
  if not ok then
    return nil, err
  end
  if timeout ~= nil then
    ok, err = self:set_prop("DiscoverableTimeout", timeout)
    if not ok then
      return nil, err
    end
  end
  return true
end

--- Enable/disable pairability. `timeout` is the pairable window in
-- seconds (0 = always pairable); omit it to leave the timeout unchanged.
function Adapter:set_pairable(on, timeout)
  local ok, err = self:set_prop("Pairable", on and true or false)
  if not ok then
    return nil, err
  end
  if timeout ~= nil then
    ok, err = self:set_prop("PairableTimeout", timeout)
    if not ok then
      return nil, err
    end
  end
  return true
end

--- The currently active discovery filters (org.bluez.Adapter1
-- .GetDiscoveryFilters). Returns a list, or nil + err.
function Adapter:get_discovery_filters()
  local values, err = self:call("GetDiscoveryFilters")
  if not values then
    return nil, err
  end
  return values[1]
end

--- This adapter's LE advertising settings and capabilities
-- (org.bluez.LEAdvertisingManager1 properties): SupportedInstances /
-- ActiveInstances (byte counts), SupportedIncludes,
-- SupportedSecondaryChannels, SupportedFeatures (string lists) and
-- SupportedCapabilities (a{sv}: MinTxPower/MaxTxPower, MaxAdvLen/
-- MaxScnRspLen). Live Properties.GetAll first, falling back to the
-- ObjectManager cache. Returns a plain table (values unwrapped, a{sv}
-- entries deeply unwrapped to plain values), or nil + err.
function Adapter:advertising_capabilities()
  local values, err = self._bt.bus:call(bluez.SERVICE, self._path,
    bluez.PROPS, "GetAll", { bluez.ADV_MANAGER }, { signature = "s" })
  local props
  if values then
    props = {}
    for k, v in pairs(values[1]) do
      props[k] = unwrap(v)
    end
  else
    local cached = self._bt._objects[self._path]
    if not cached or not cached[bluez.ADV_MANAGER] then
      return nil, err
    end
    props = cached[bluez.ADV_MANAGER]  -- outer variants already unwrapped
  end
  -- a{sv} properties (e.g. SupportedCapabilities) need one more level
  local out = {}
  for k, v in pairs(props) do
    if type(v) == "table" then
      local inner = {}
      for k2, v2 in pairs(v) do
        inner[k2] = unwrap(v2)
      end
      out[k] = inner
    else
      out[k] = v
    end
  end
  return out
end

--------------------------------------------------------------------------------
-- Device (org.bluez.Device1)
--------------------------------------------------------------------------------

local Device = Object:subclass("Device")

--- Connect to this device (registers all auto-connectable profiles).
function Device:connect()
  return self:call("Connect")
end

--- Disconnect this device.
function Device:disconnect()
  return self:call("Disconnect")
end

--- Pair with this device (may require confirmation on the remote side).
function Device:pair()
  return self:call("Pair")
end

--- Cancel an in-progress Pairing.
function Device:cancel_pair()
  return self:call("CancelPair")
end

--- Connect a specific profile UUID.
function Device:connect_profile(uuid)
  return self:call("ConnectProfile", { uuid }, { signature = "s" })
end

--- Disconnect a specific profile UUID.
function Device:disconnect_profile(uuid)
  return self:call("DisconnectProfile", { uuid }, { signature = "s" })
end

--------------------------------------------------------------------------------
-- Device: common Device1 property accessors
--------------------------------------------------------------------------------

--- The device's Bluetooth MAC address (Address property).
function Device:address()
  return self:get_prop("Address")
end

--- The address type: "public", "random" or "anonymous".
function Device:address_type()
  return self:get_prop("AddressType")
end

--- The remote icon name (Icon property), e.g. "input-mouse"; may be nil.
function Device:icon()
  return self:get_prop("Icon")
end

--- Latest RSSI in dBm (RSSI property); nil once the device is connected
-- (BlueZ drops the property when advertising stops).
function Device:rssi()
  return self:get_prop("RSSI")
end

--- Set the device's human-friendly name (Alias property). The alias is
-- local to this machine; pass "" to reset to the remote Name.
function Device:set_name(alias)
  return self:set_prop("Alias", alias)
end

--- Display name: Alias, then Name, then the MAC address.
function Device:label()
  return self:get_prop("Alias") or self:get_prop("Name")
    or self:address() or self:path()
end

--- True while the device reports a live connection.
function Device:is_connected()
  return self:get_prop("Connected") == true
end

--- True once pairing has completed (Paired property).
function Device:is_paired()
  return self:get_prop("Paired") == true
end

--- True when all GATT services of the device have been resolved
-- (ServicesResolved property).
function Device:services_resolved()
  return self:get_prop("ServicesResolved") == true
end

--- True when the device is trusted (Trusted property); trusted devices
-- auto-reconnect without re-authorization.
function Device:is_trusted()
  return self:get_prop("Trusted") == true
end

--- Mark the device trusted/untrusted.
function Device:set_trusted(on)
  return self:set_prop("Trusted", on and true or false)
end

--- True when the device is blocked (Blocked property); blocked devices
-- cannot connect or be connected.
function Device:is_blocked()
  return self:get_prop("Blocked") == true
end

--- Block/unblock the device.
function Device:set_blocked(on)
  return self:set_prop("Blocked", on and true or false)
end

--------------------------------------------------------------------------------
-- Bluez client: ObjectManager cache + signal subscriptions
--------------------------------------------------------------------------------

local Bluez = middleclass("Bluez")

--- Create a client. Options:
--   bus = ldbus Bus to use (default: connect to the system bus and own it).
-- The ObjectManager cache starts empty; call :refresh() to populate it
-- (an error here is returned and leaves the cache empty, e.g. when
-- bluetoothd is not running).
function Bluez:initialize(opts)
  opts = opts or {}
  local bus = opts.bus
  local owns = false
  if not bus then
    local err
    bus, err = ldbus.system()
    if not bus then
      error("cannot connect to the system bus: " .. tostring(err), 2)
    end
    owns = true
  end
  self.bus = bus
  self._owns_bus = owns
  self._objects = {}   -- { [path] = { [iface] = { [prop] = value } } }
  self._closed = false
  self:_subscribe()
  local ok, err = self:refresh()
  if not ok then
    self._refresh_err = err
  end
end

--- Refresh the ObjectManager cache with a fresh GetManagedObjects call.
function Bluez:refresh()
  local values, err = self.bus:call(bluez.SERVICE, bluez.ROOT, bluez.OM,
                                    "GetManagedObjects")
  if not values then
    return nil, err
  end
  local objects = {}
  for path, ifaces in pairs(values[1]) do
    objects[path] = self:_unwrap_ifaces(ifaces)
  end
  self._objects = objects
  return true
end

local function unwrap_props(props)
  local out = {}
  for k, v in pairs(props) do
    out[k] = unwrap(v)
  end
  return out
end

function Bluez:_unwrap_ifaces(ifaces)
  local out = {}
  for iface, props in pairs(ifaces) do
    out[iface] = unwrap_props(props)
  end
  return out
end

function Bluez:_subscribe()
  self.bus:on_signal(bluez.OM, "InterfacesAdded", function(msg)
    local path, ifaces = msg.body[1], msg.body[2]
    local prev = self._objects[path] or {}
    -- merge (an InterfacesAdded may carry several interfaces)
    for iface, props in pairs(self:_unwrap_ifaces(ifaces)) do
      prev[iface] = props
    end
    self._objects[path] = prev
  end)

  self.bus:on_signal(bluez.OM, "InterfacesRemoved", function(msg)
    local path, ifaces = msg.body[1], msg.body[2]
    local entry = self._objects[path]
    if not entry then return end
    for _, iface in ipairs(ifaces) do
      entry[iface] = nil
    end
    if next(entry) == nil then
      self._objects[path] = nil
    end
  end)

  self.bus:on_signal(bluez.PROPS, "PropertiesChanged", function(msg)
    local iface, changed = msg.body[1], msg.body[2]
    local entry = self._objects[msg.path]
    if not entry or not entry[iface] then return end
    for k, v in pairs(changed) do
      entry[iface][k] = unwrap(v)
    end
    for _, name in ipairs(msg.body[3] or {}) do
      entry[iface][name] = nil
    end
  end)
end

--- Enumerate cached adapters. Returns a sorted list of Adapter handles.
function Bluez:adapters()
  return self:_collect(bluez.ADAPTER, Adapter)
end

--- The first cached adapter, or nil.
function Bluez:default_adapter()
  return self:adapters()[1]
end

--- Enumerate cached devices, optionally limited to one adapter
-- (path string or Adapter handle). Returns a sorted list of Device handles.
function Bluez:devices(adapter)
  local prefix = type(adapter) == "table" and adapter:path() or adapter
  return self:_collect(bluez.DEVICE, Device, prefix)
end

--- Find a cached device by MAC address, or nil. Cache-only: never does I/O.
function Bluez:find_device(address)
  for path, entry in pairs(self._objects) do
    local props = entry[bluez.DEVICE]
    if props and props.Address == address then
      return Device(self, path, bluez.DEVICE)
    end
  end
  return nil
end

--- A Device handle for a cached device path, or nil when the device is
-- not in the ObjectManager cache. Cache-only: never does I/O.
function Bluez:device(path)
  local entry = self._objects[path]
  if entry and entry[bluez.DEVICE] then
    return Device(self, path, bluez.DEVICE)
  end
  return nil
end

--- Collect cached objects implementing `iface` under `prefix` (nil = all),
-- as a sorted list of `class` handles. Never does I/O.
function Bluez:_collect(iface, class, prefix)
  local paths = {}
  for path, entry in pairs(self._objects) do
    if entry[iface]
        and (not prefix or path:sub(1, #prefix + 1) == prefix .. "/") then
      paths[#paths + 1] = path
    end
  end
  table.sort(paths)
  local out = {}
  for i, path in ipairs(paths) do
    out[i] = class(self, path, iface)
  end
  return out
end

--- Close the client and its bus connection if this client opened it.
function Bluez:close()
  if self._closed then return end
  self._closed = true
  if self._owns_bus then
    self.bus:close()
  end
end

--------------------------------------------------------------------------------
-- module surface
--------------------------------------------------------------------------------

bluez.new = function(opts)
  return Bluez(opts)
end

bluez.Bluez = Bluez
bluez.Object = Object
bluez.Adapter = Adapter
bluez.Device = Device
bluez.to_bytes = to_bytes
bluez.from_bytes = from_bytes
bluez.expand_uuid = expand_uuid
bluez.unwrap = unwrap
bluez.auto_variant = auto_variant

-- Optional submodules extend the client with GATT client/server APIs.
-- Register ourselves first so the circular `require "bluez"` inside the
-- submodules returns this (partially complete) table instead of recursing.
package.loaded["bluez"] = bluez
pcall(require, "bluez.gatt_client")
pcall(require, "bluez.gatt_server")

--------------------------------------------------------------------------------
-- Adapter: one-call LE advertising toggle (uses bluez.Advertisement
-- from bluez.gatt_server, so defined after the submodules load)
--------------------------------------------------------------------------------

--- Create and register an LE advertisement on this adapter in one call.
-- `opts` is passed straight to bluez.Advertisement (local_name,
-- service_uuids, includes, min_interval/max_interval, ...). Calling it
-- again while advertising returns the existing handle unchanged.
-- Requires a running mainloop while registered.
function Adapter:start_advertising(opts)
  local bt = self._bt
  bt._advertisements = bt._advertisements or {}
  local existing = bt._advertisements[self._path]
  if existing then
    return existing
  end
  if not bluez.Advertisement then
    return nil, { name = "org.bluez.Error.NotSupported",
                  message = "bluez.gatt_server not available" }
  end
  local path = self._path .. "/lua_adv"
  local adv = bluez.Advertisement(bt, path, opts)
  local ok, err = adv:register(self)
  if not ok then
    return nil, err
  end
  bt._advertisements[self._path] = adv
  return adv
end

--- Unregister the advertisement started with :start_advertising.
-- Returns true, or nil + err (including when not currently advertising).
function Adapter:stop_advertising()
  local advs = self._bt._advertisements
  local adv = advs and advs[self._path]
  if not adv then
    return nil, { name = "org.bluez.Error.DoesNotExist",
                  message = "no active advertisement for " .. self._path }
  end
  local ok, err = adv:unregister(self)
  if not ok then
    return nil, err
  end
  advs[self._path] = nil
  return true
end

return bluez
