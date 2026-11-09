-- Example: scan for nearby Bluetooth devices via org.bluez and print
-- what was found. Requires bluetoothd and a powered adapter on the
-- system bus.
package.path = "examples/?.lua;examples/?/init.lua;" .. package.path
local bluez = require "bluez"

local ok, bt = pcall(function() return bluez.new() end)
if not ok then
  error("cannot start bluez client: " .. tostring(bt))
end

local adapter = bt:default_adapter()
if not adapter then
  error("no Bluetooth adapter found (is bluetoothd running?)")
end
print(("adapter %s at %s"):format(adapter:address() or "?", adapter:path()))

if not adapter:get_prop("Powered") then
  print("powering adapter on...")
  adapter:set_prop("Powered", true)
end

-- Low-energy scan; drop the filter for BR/EDR too.
adapter:set_discovery_filter{ Transport = "le" }
adapter:start_discovery()
print("scanning for 10 seconds...")

local deadline = os.time() + 10
bt.bus:mainloop{
  timeout = 0.5,
  ["until"] = function() return os.time() >= deadline end,
}

adapter:stop_discovery()

local devices = bt:devices(adapter)
print(("%d device(s) seen:"):format(#devices))
for _, dev in ipairs(devices) do
  print(("  %-17s  %-25s  RSSI %s  %s%s"):format(
    dev:address() or "?",
    dev:label(),
    tostring(dev:rssi() or "-"),
    dev:is_paired() and "[paired] " or "",
    dev:is_connected() and "[connected]" or ""))
end

bt:close()
