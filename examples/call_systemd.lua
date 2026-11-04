-- Example: call systemd on the system bus and list loaded units.
-- Requires permission to talk to the system bus (usually true for
-- read-only Manager calls).
local ldbus = require "ldbus"

local bus, err = ldbus.system()
if not bus then
  error("cannot connect to the system bus: " .. tostring(err))
end

local units, err = bus:call("org.freedesktop.systemd1",
                            "/org/freedesktop/systemd1",
                            "org.freedesktop.systemd1.Manager",
                            "ListUnits", nil)
if not units then
  error("ListUnits failed: " .. tostring(err.name) .. ": " .. tostring(err.message))
end

print(#units[1] .. " units")
for i, unit in ipairs(units[1]) do
  -- unit is (sssssouso): name, description, load_state, active_state,
  -- sub_state, following, path, job_id, job_type, job_path
  if i <= 10 then
    print(string.format("  %-45s %s", unit[1], unit[4]))
  end
end
if #units[1] > 10 then
  print(("  ... and %d more"):format(#units[1] - 10))
end

bus:close()
