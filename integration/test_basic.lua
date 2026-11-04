-- Integration: connect to a real bus, Hello, GetId, ListNames.
-- Run via integration/run.sh (inside dbus-run-session).
local dbus = require "ldbus.connection"

local bus, err = dbus.connect("session")
if not bus then
  error("connect failed: " .. tostring(err))
end
print("connected, unique name:", bus.unique_name)
assert(bus.unique_name:match("^:%d+%.%d+$"), "unique name looks wrong: " .. bus.unique_name)

-- GetId on the bus itself
local id = bus:call("org.freedesktop.DBus", "/org/freedesktop/DBus",
                    "org.freedesktop.DBus", "GetId", nil)
assert(id and #id == 1 and type(id[1]) == "string", "GetId failed")
print("bus id:", id[1])

-- ListNames must include the bus itself and our own unique name
local names = bus:call("org.freedesktop.DBus", "/org/freedesktop/DBus",
                       "org.freedesktop.DBus", "ListNames", nil)
assert(names and names[1], "ListNames failed")
local found_bus, found_self = false, false
for _, n in ipairs(names[1]) do
  if n == "org.freedesktop.DBus" then
    found_bus = true
  end
  if n == bus.unique_name then
    found_self = true
  end
end
assert(found_bus, "bus name missing from ListNames")
assert(found_self, "own unique name missing from ListNames")
print("ListNames ok:", #names[1], "names")

bus:close()
print("test_basic PASSED")
