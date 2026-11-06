-- Example: GATT server (peripheral role). Exposes a counter service,
-- advertises it with configurable LE parameters, pushes notifications,
-- and demonstrates runtime advertising-parameter changes.
--
-- Usage: lua5.4 examples/gatt_server_demo.lua [seconds]   (default 60)
--
-- Requires bluetoothd with a powered adapter. While running, the device
-- appears as "LuaGattDemo" to nearby BLE centrals; connect and write/
-- subscribe the counter characteristic from a GATT client (e.g. the
-- gatt_client_demo example or a phone app).
package.path = "examples/?.lua;examples/?/init.lua;src/?.lua;src/?/init.lua;" .. package.path
local bluez = require "bluez"

-- 128-bit custom service/characteristic UUIDs (16-bit UUIDs in
-- advertisements must be SIG-assigned; custom ones must be full length)
local DEMO_SVC  = "8ec90001-f315-4f60-9fb8-838830daea50"
local DEMO_CHAR = "8ec90002-f315-4f60-9fb8-838830daea50"

local DURATION = tonumber(arg[1]) or 60

local bt = assert(bluez.new(), "cannot start bluez client")
local adapter = assert(bt:default_adapter(), "no Bluetooth adapter found")

-- remember the current adapter state so we can restore it on exit
local old_alias = adapter:get_prop("Alias")
local old_disc = adapter:get_prop("Discoverable")
local old_disc_timeout = adapter:get_prop("DiscoverableTimeout")

local function restore_adapter()
  if old_alias then adapter:set_name(old_alias) end
  if old_disc ~= nil then
    adapter:set_discoverable(old_disc, old_disc_timeout or 0)
  end
end

--------------------------------------------------------------------------------
-- adapter management
--------------------------------------------------------------------------------

adapter:set_powered(true)
adapter:set_name("LuaGattDemo")
adapter:set_discoverable(true, 0)          -- visible, never hides
print(("adapter %s (%s) powered=%s"):format(
  adapter:display_name(), adapter:path(), tostring(adapter:is_powered())))

--------------------------------------------------------------------------------
-- GATT application: one service with a counter characteristic
--------------------------------------------------------------------------------

local app = bluez.Application(bt, "/com/example/gatt")
local svc = app:service(DEMO_SVC)

local level = 100
local counter = svc:characteristic(DEMO_CHAR, { "read", "write", "notify" }, {
  value = string.char(level),
  on_read = function(opts)
    print("peer reads counter ->", level)
    return string.char(level)
  end,
  on_write = function(value, opts)
    level = value:byte(1) or 0
    print("peer writes counter <-", level)
  end,
})

--------------------------------------------------------------------------------
-- LE advertisement with tunable parameters
--------------------------------------------------------------------------------

local adv = bluez.Advertisement(bt, "/com/example/adv", {
  type = "peripheral",
  local_name = "LuaGattDemo",
  service_uuids = { DEMO_SVC },
  includes = { "tx-power" },  -- no "local-name": conflicts with LocalName
  discoverable = true,
  discoverable_timeout = 0,   -- uint16 seconds
  min_interval = 100,         -- ms, BlueZ >= 5.64 (min must be <= max)
  max_interval = 200,         -- ms
  manufacturer_data = { [0xff] = "ldbus demo" },  -- a{qv}: id -> bytes
})

print("registering GATT application + advertisement (100-200 ms)...")
local ok, err = app:register(adapter)
assert(ok, "register application failed: "
  .. tostring(err and err.message or err))
ok, err = adv:register(adapter)
assert(ok, "register advertisement failed: "
  .. tostring(err and err.message or err))

--------------------------------------------------------------------------------
-- mainloop in 5-second bursts: notify between bursts, retune halfway
--------------------------------------------------------------------------------

local deadline = os.time() + DURATION
local retuned = false
while os.time() < deadline do
  local burst_end = math.min(os.time() + 5, deadline)
  bt.bus:mainloop{
    timeout = 0.5,
    ["until"] = function() return os.time() >= burst_end end,
  }

  -- push a new value to subscribed centrals
  level = (level + 1) % 101
  counter:notify(string.char(level))
  print(("notify: counter = %d  (%d s left)")
    :format(level, deadline - os.time()))

  -- adjust advertising parameters while registered (PropertiesChanged)
  if not retuned and os.time() >= deadline - math.max(DURATION / 2, 5) then
    ok, err = adv:update{
      LocalName = "LuaGattDemoFast",
      MinInterval = 20,      -- ms
      MaxInterval = 40,      -- ms
    }
    if ok then
      print("advertisement updated: name=LuaGattDemoFast, 20-40 ms")
    else
      print("advertisement update failed:", err and err.message or err)
    end
    retuned = true
  end
end

--------------------------------------------------------------------------------
-- cleanup
--------------------------------------------------------------------------------

print("unregistering...")
adv:unregister(adapter)
app:unregister(adapter)
restore_adapter()
bt:close()
print("gatt_server_demo done")
