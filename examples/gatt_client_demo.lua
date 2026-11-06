-- Example: GATT client (central role). Locates a device, connects,
-- dumps its GATT hierarchy, reads the battery level, and subscribes to
-- notifications.
--
-- Usage: lua5.4 examples/gatt_client_demo.lua [MAC|name] [seconds]
--   MAC/name: device to use (default: any already-connected device)
--   seconds:  how long to listen for notifications (default 15)
--
-- Pairs well with examples/gatt_server_demo.lua: run the server on a
-- second machine and connect to it here by its advertised name.
package.path = "examples/?.lua;examples/?/init.lua;" .. package.path
local bluez = require "bluez"

local target = arg[1]
local SUBSCRIBE_S = tonumber(arg[2]) or 15

local bt = assert(bluez.new(), "cannot start bluez client")
local adapter = assert(bt:default_adapter(), "no Bluetooth adapter found")

--------------------------------------------------------------------------------
-- 1) locate the device: cache first, then a 10-second scan
--------------------------------------------------------------------------------

local function matches(dev)
  if dev:get_prop("Address") == target then
    return true
  end
  if target then
    local name = dev:get_prop("Alias") or dev:get_prop("Name")
    return name ~= nil and name:find(target, 1, true) ~= nil
  end
  return dev:is_connected()      -- no target: use a connected device
end

local function find_device()
  for _, dev in ipairs(bt:devices()) do
    if matches(dev) then
      return dev
    end
  end
  return nil
end

local dev = find_device()
if not dev then
  print(("scanning for 10 s (%s)...")
    :format(target or "any device"))
  adapter:start_discovery()
  local deadline = os.time() + 10
  bt.bus:mainloop{
    timeout = 0.5,
    ["until"] = function() return os.time() >= deadline end,
  }
  adapter:stop_discovery()
  dev = find_device()
end
assert(dev, "no matching device found"
  .. (target and (": " .. target) or " (nothing connected)"))

print(("device: %s  (%s)"):format(dev:label(), dev:path()))

--------------------------------------------------------------------------------
-- 2) connect (blocking; the mainloop is not needed for this)
--------------------------------------------------------------------------------

local was_connected = dev:is_connected()
if not was_connected then
  print("connecting...")
  local ok, err = dev:connect()
  assert(ok, "connect failed: "
    .. tostring(err and (err.name .. ": " .. err.message) or err))
end
print("connected")

--------------------------------------------------------------------------------
-- 3) dump the GATT hierarchy from the ObjectManager cache
--------------------------------------------------------------------------------

bt:refresh()   -- pull in the services/characteristics added on connect
print("services:")
for _, svc in ipairs(bt:services(dev)) do
  print(("  %s"):format(svc:get_prop("UUID")))
  for _, ch in ipairs(bt:characteristics(svc)) do
    print(("    %s  [%s]"):format(ch:get_prop("UUID"),
      table.concat(ch:get_prop("Flags") or {}, ", ")))
  end
end

--------------------------------------------------------------------------------
-- 4) read the battery level (0x180f / 0x2a19)
--------------------------------------------------------------------------------

local bat
local svc = bt:find_service("180f", dev)
if svc then
  bat = bt:find_characteristic("2a19", svc)
end
if bat then
  local v, err = bat:read_value()
  if v then
    print(("battery level: %d%%"):format(v:byte(1)))
  else
    print("battery read failed: "
      .. tostring(err and err.message or err))
  end
else
  print("device has no battery service")
end

--------------------------------------------------------------------------------
-- 5) subscribe to notifications (needs a running mainloop)
--------------------------------------------------------------------------------

if bat then
  print(("subscribing for %d s (interact with the device to see data)...")
    :format(SUBSCRIBE_S))
  local unsub = assert(bat:subscribe(function(value)
    print(("notification: %s")
      :format(#value == 1 and (value:byte(1) .. "%") or (#value .. " bytes")))
  end))
  local deadline = os.time() + SUBSCRIBE_S
  bt.bus:mainloop{
    timeout = 0.5,
    ["until"] = function() return os.time() >= deadline end,
  }
  unsub()
end

--------------------------------------------------------------------------------
-- 6) cleanup
--------------------------------------------------------------------------------

if not was_connected then
  print("disconnecting...")
  dev:disconnect()
end
bt:close()
print("gatt_client_demo done")
