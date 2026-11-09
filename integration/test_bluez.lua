-- Integration: exercise examples/bluez.lua against a fake org.bluez
-- service on a private bus (via integration/run.sh).
-- Covers: GetManagedObjects cache, property read/write (__index/__newindex),
-- Adapter methods, InterfacesAdded / PropertiesChanged cache updates.
package.path = "src/?.lua;src/?/init.lua;examples/?.lua;examples/?/init.lua;" .. package.path
local ldbus = require "ldbus"
local bluez = require "bluez"
io.stdout:setvbuf("line")

--- Plain-Lua helpers (no busted in integration scripts).
local function equals(a, b)
  assert(a == b, "expected " .. tostring(b) .. ", got " .. tostring(a))
end

local DEVICE_PATH = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF"
local DEVICE_ADDR = "AA:BB:CC:DD:EE:FF"
local SERVICE_PATH = DEVICE_PATH .. "/service0025"
local CHAR_PATH = SERVICE_PATH .. "/char0026"
local BAT_SVC_UUID = "0000180f-0000-1000-8000-00805f9b34fb"
local BAT_CHAR_UUID = "00002a19-0000-1000-8000-00805f9b34fb"

local server = assert(ldbus.session())
local client_bus = assert(ldbus.session())
print("server:", server.conn.unique_name)

--------------------------------------------------------------------------------
-- fake org.bluez service
--------------------------------------------------------------------------------

local calls = { set = {}, discovery = 0, written = {}, adv_names = {} }

local adapter_obj = server:object("/org/bluez/hci0")
adapter_obj:method("org.bluez.Adapter1.StartDiscovery", "", "", function()
  calls.discovery = calls.discovery + 1
end)
adapter_obj:method("org.bluez.Adapter1.SetDiscoveryFilter", "a{sv}", "",
  function() end)
adapter_obj:method("org.bluez.Adapter1.GetDiscoveryFilters", "", "as",
  function() return { "le" } end)

-- record LEAdvertisement1 property changes pushed at runtime
server:on_signal(bluez.PROPS, "PropertiesChanged", function(msg)
  if msg.path == "/com/test/adv" or msg.path == "/org/bluez/hci0/lua_adv" then
    calls.adv_pc = { path = msg.path, changed = msg.body[2] }
  end
end)
adapter_obj:method("org.freedesktop.DBus.Properties.Get", "ss", "v",
  function(iface, name)
    if iface == "org.bluez.Adapter1" and name == "Address" then
      return ldbus.variant("s", "00:11:22:33:44:55")
    end
    if iface == "org.bluez.Adapter1" and name == "Powered" then
      return ldbus.variant("b", true)
    end
    if iface == "org.bluez.Adapter1" and name == "Alias" then
      return ldbus.variant("s", calls.alias or "TestAdapter")
    end
    error("no such property " .. name)
  end)
adapter_obj:method("org.freedesktop.DBus.Properties.Set", "ssv", "",
  function(iface, name, value)
    calls.set[#calls.set + 1] = { iface = iface, name = name, value = value }
    if iface == "org.bluez.Adapter1" and name == "Alias" then
      calls.alias = value.value
    end
  end)

-- fake GATT characteristic: ReadValue / WriteValue / StartNotify / StopNotify
local char_obj = server:object(CHAR_PATH)
char_obj:method("org.bluez.GattCharacteristic1.ReadValue", "a{sv}", "ay",
  function(opts) return { 42 } end)
char_obj:method("org.bluez.GattCharacteristic1.WriteValue", "aya{sv}", "",
  function(bytes, opts)
    calls.written[#calls.written + 1] = bytes
  end)
char_obj:method("org.bluez.GattCharacteristic1.StartNotify", "", "",
  function() calls.notify = true end)
char_obj:method("org.bluez.GattCharacteristic1.StopNotify", "", "",
  function() calls.notify = false end)

-- fake GattManager1 / LEAdvertisingManager1: validate the client's exports
-- by calling back into it (cross-service ObjectManager / Properties reads).
adapter_obj:method("org.bluez.GattManager1.RegisterApplication", "oa{sv}", "",
  function(app_path, opts)
    calls.registered = app_path
    local values, err = server:call(client_bus.conn.unique_name, app_path,
      bluez.OM, "GetManagedObjects", {}, { signature = "" })
    assert(values, "callback GetManagedObjects failed: " .. tostring(err))
    local objs = values[1]
    local svc = objs[app_path .. "/service1"]
    local ch = svc and objs[app_path .. "/service1/char1"]
    assert(svc and svc[bluez.GATT_SERVICE], "exported service missing")
    assert(ch and ch[bluez.GATT_CHAR], "exported characteristic missing")
    equals("2a19", ch[bluez.GATT_CHAR].UUID.value)
    calls.export_ok = true
  end)
adapter_obj:method("org.bluez.GattManager1.UnregisterApplication", "o", "",
  function(app_path) calls.unregistered = app_path end)
adapter_obj:method("org.bluez.LEAdvertisingManager1.RegisterAdvertisement",
  "oa{sv}", "", function(adv_path, opts)
    calls.adv_registered = adv_path
    local values, err = server:call(client_bus.conn.unique_name, adv_path,
      bluez.PROPS, "GetAll", { "org.bluez.LEAdvertisement1" },
      { signature = "s" })
    assert(values, "callback GetAll failed: " .. tostring(err))
    local props = values[1]
    assert(props.LocalName and props.LocalName.value, "LocalName missing")
    assert(props.ServiceUUIDs and props.ServiceUUIDs.value[1] == "180f",
      "ServiceUUIDs wrong")
    calls.adv_names[#calls.adv_names + 1] = props.LocalName.value
    calls.adv_props = props
  end)
adapter_obj:method("org.bluez.LEAdvertisingManager1.UnregisterAdvertisement",
  "o", "", function(adv_path) calls.adv_unregistered = adv_path end)

server:object("/"):method("org.freedesktop.DBus.ObjectManager.GetManagedObjects",
  "", "a{oa{sa{sv}}}", function()
  return {
    ["/org/bluez/hci0"] = {
      ["org.bluez.Adapter1"] = {
        Address     = ldbus.variant("s", "00:11:22:33:44:55"),
        Powered     = ldbus.variant("b", true),
        Discovering = ldbus.variant("b", false),
      },
    },
    [DEVICE_PATH] = {
      ["org.bluez.Device1"] = {
        Address = ldbus.variant("s", DEVICE_ADDR),
        Name    = ldbus.variant("s", "Test Device"),
        Paired  = ldbus.variant("b", false),
        RSSI    = ldbus.variant("n", -56),
      },
    },
    [SERVICE_PATH] = {
      ["org.bluez.GattService1"] = {
        UUID    = ldbus.variant("s", BAT_SVC_UUID),
        Device  = ldbus.variant("o", DEVICE_PATH),
        Primary = ldbus.variant("b", true),
      },
    },
    [CHAR_PATH] = {
      ["org.bluez.GattCharacteristic1"] = {
        UUID     = ldbus.variant("s", BAT_CHAR_UUID),
        Service  = ldbus.variant("o", SERVICE_PATH),
        Flags    = ldbus.variant("as", { "read", "write", "notify" }),
        Value    = ldbus.variant("ay", { 42 }),
      },
    },
  }
end)

equals(server:request_name("org.bluez"), ldbus.result.PRIMARY_OWNER)
print("owns name org.bluez")

--------------------------------------------------------------------------------
-- client: run inside one mainloop so server and client pump concurrently
--------------------------------------------------------------------------------

local done = false
local started = os.clock()
local bt  -- created in the init task, read by the until callback

ldbus.mainloop({ server, client_bus }, {
  timeout = 0.05,
  init = function()
    bt = bluez.new{ bus = client_bus }

    -- 1) GetManagedObjects cache
    local adapter = assert(bt:default_adapter(), "no adapter in cache")
    equals("/org/bluez/hci0", adapter:path())
    equals("00:11:22:33:44:55", adapter:get_prop("Address"))
    equals(true, adapter:get_prop("Powered"))

    local devs = bt:devices(adapter)
    equals(1, #devs)
    equals(DEVICE_PATH, devs[1]:path())
    equals("Test Device", devs[1]:label())
    equals(DEVICE_ADDR, devs[1]:address())
    equals(false, devs[1]:is_paired())
    equals(false, devs[1]:is_trusted() or false)
    equals(-56, devs[1]:rssi())
    assert(bt:find_device(DEVICE_ADDR), "find_device failed")
    assert(not bt:find_device("00:00:00:00:00:00"), "find_device false positive")
    print("cache + enumeration ok")

    -- 2) live property Get (falls through to the fake service)
    local values = adapter:get_prop("Discovering")
    equals(false, values)
    print("live Properties.Get ok")

    -- 3) property Set via set_prop
    adapter:set_prop("Powered", false)
    assert(#calls.set == 1, "Set not called")
    equals("org.bluez.Adapter1", calls.set[1].iface)
    equals("Powered", calls.set[1].name)
    equals("b", calls.set[1].value.signature)
    equals(false, calls.set[1].value.value)
    print("property Set ok")

    -- 4) adapter methods
    adapter:set_discovery_filter{ Transport = "le", DuplicateData = true }
    adapter:start_discovery()
    assert(calls.discovery == 1, "StartDiscovery not called")
    print("adapter methods ok")

    -- 5) GATT client: cached enumeration with UUID expansion
    local dev = bt:find_device(DEVICE_ADDR)
    local svc = assert(bt:find_service("180f", dev), "find_service failed")
    equals(SERVICE_PATH, svc:path())
    assert(#bt:services(dev) >= 1, "services enumeration failed")
    local bat = assert(bt:find_characteristic("2a19", svc),
      "find_characteristic failed")
    equals(CHAR_PATH, bat:path())

    -- 6) GATT client: read / write / subscribe
    local v, err = bat:read_value()
    assert(v, "read_value failed: " .. tostring(err))
    equals("\42", v)
    equals(true, bat:write_value("\42\43"))
    equals(42, calls.written[1][1])
    equals(43, calls.written[1][2])

    local got
    local unsub = assert(bat:subscribe(function(val) got = val end))
    equals(true, calls.notify)
    server:emit(CHAR_PATH, bluez.PROPS, "PropertiesChanged",
      "sa{sv}as", { bluez.GATT_CHAR,
        { Value = ldbus.variant("ay", { 7 }) }, {} })
    -- pump the loop with a harmless live call until the callback fires
    for _ = 1, 50 do
      if got ~= nil then break end
      adapter:get_prop("Discovering")
    end
    equals("\7", got)
    unsub()
    equals(false, calls.notify)
    print("gatt client read/write/subscribe ok")

    -- 7) GATT server: export an app + advertisement, register them
    local app = bluez.Application(bt, "/com/test/gatt")
    local lasvc = app:service("180f")
    local lachar = lasvc:characteristic("2a19", { "read", "notify" },
      { value = "\1", on_read = function() return "\1\2\3" end })
    local adv = bluez.Advertisement(bt, "/com/test/adv", {
      local_name = "TestAdv",
      service_uuids = { "180f" },
      manufacturer_data = { [0x0059] = "\1\2" },
    })
    local reg_ok, reg_err = app:register(adapter)
    assert(reg_ok, "register failed: "
      .. tostring(reg_err and (reg_err.name .. ": " .. reg_err.message) or reg_err))
    equals(true, calls.export_ok, "RegisterApplication export check failed")
    equals("/com/test/gatt", calls.registered)
    equals(true, adv:register(adapter))
    equals("/com/test/adv", calls.adv_registered)
    equals("TestAdv", calls.adv_names[1])
    assert(calls.adv_props.ManufacturerData
      and calls.adv_props.ManufacturerData.value[89],
      "ManufacturerData missing")
    equals(true, app:unregister(adapter))
    equals("/com/test/gatt", calls.unregistered)
    equals(true, adv:unregister(adapter))
    equals("/com/test/adv", calls.adv_unregistered)
    print("gatt server registration ok")

    -- 8) adapter management helpers
    adapter:set_name("LuaBox")
    adapter:set_powered(true)
    adapter:set_discoverable(true, 30)
    adapter:set_pairable(true, 60)
    equals("Alias", calls.set[2].name)
    equals("LuaBox", calls.set[2].value.value)
    equals("Powered", calls.set[3].name)
    equals(true, calls.set[3].value.value)
    equals("Discoverable", calls.set[4].name)
    equals("DiscoverableTimeout", calls.set[5].name)
    equals(30, calls.set[5].value.value)
    equals("Pairable", calls.set[6].name)
    equals("PairableTimeout", calls.set[7].name)
    equals(60, calls.set[7].value.value)
    equals("le", adapter:get_discovery_filters()[1])
    equals("LuaBox", adapter:display_name())

    -- one-call advertising toggle + runtime parameter update
    local ladv = assert(adapter:start_advertising{
      local_name = "LuaAdv", service_uuids = { "180f" },
      min_interval = 100, max_interval = 200,
    })
    equals("/org/bluez/hci0/lua_adv", ladv:path())
    equals("LuaAdv", calls.adv_names[2])
    equals(100, calls.adv_props.MinInterval.value)
    equals(200, calls.adv_props.MaxInterval.value)
    -- idempotent: a second start returns the same handle
    equals(ladv:path(), adapter:start_advertising{}:path())
    equals(true, ladv:update{ LocalName = "LuaAdv2", MinInterval = 150 })
    for _ = 1, 50 do
      if calls.adv_pc then break end
      adapter:get_prop("Discovering")   -- pump until the signal lands
    end
    assert(calls.adv_pc, "advertisement PropertiesChanged not received")
    equals("LuaAdv2", bluez.unwrap(calls.adv_pc.changed.LocalName))
    equals(150, bluez.unwrap(calls.adv_pc.changed.MinInterval))
    equals(true, adapter:stop_advertising())
    equals("/org/bluez/hci0/lua_adv", calls.adv_unregistered)
    local stopped, stop_err = adapter:stop_advertising()
    assert(not stopped, "stop_advertising should fail when not advertising")
    print("adapter management ok")

    -- 9) signals keep the cache fresh: a new device appears, RSSI changes
    server:emit("/org/bluez/hci0", bluez.OM, "InterfacesAdded",
      "oa{sa{sv}}", { "/org/bluez/hci0/dev_11_22_33_44_55_66", {
        ["org.bluez.Device1"] = {
          Address = ldbus.variant("s", "11:22:33:44:55:66"),
          Name    = ldbus.variant("s", "Fresh Device"),
        },
      }})
    server:emit(DEVICE_PATH, bluez.PROPS, "PropertiesChanged",
      "sa{sv}as", { "org.bluez.Device1",
        { RSSI = ldbus.variant("n", -50) }, {} })
  end,
  ["until"] = function()
    if done then return true end
    -- Runs in the main loop body (not a coroutine task), so only touch
    -- the signal-fed cache here -- no live D-Bus calls.
    local fresh = bt and bt:find_device("11:22:33:44:55:66")
    if not fresh then
      assert(os.clock() - started < 5, "timeout waiting for InterfacesAdded")
      return false
    end
    local seen = bt:find_device(DEVICE_ADDR)
    local rssi = seen and bt._objects[seen:path()]
      and bt._objects[seen:path()][bluez.DEVICE].RSSI
    if rssi ~= -50 then
      assert(os.clock() - started < 5, "timeout waiting for PropertiesChanged")
      return false
    end
    local fresh_props = bt._objects[fresh:path()][bluez.DEVICE]
    equals("Fresh Device", fresh_props.Name)
    print("InterfacesAdded + PropertiesChanged cache updates ok")
    done = true
    return true
  end,
  on_error = function(err)
    print("TASK ERROR:", err)
    print(debug.traceback(err, 2))
    os.exit(1)
  end,
})

server:close()
client_bus:close()
print("test_bluez PASSED")
