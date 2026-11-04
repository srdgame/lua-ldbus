-- Example: monitor session-bus lifecycle signals until Ctrl-C.
local ldbus = require "ldbus"

local bus, err = ldbus.session()
if not bus then
  error("cannot connect to the session bus: " .. tostring(err))
end

print("monitoring on", bus.conn.unique_name, "(Ctrl-C to quit)")

bus:on_signal("org.freedesktop.DBus", "NameOwnerChanged", function(msg)
  local name, old, new = msg.body[1], msg.body[2], msg.body[3]
  if new == "" then
    print(("[lost]     %s (was %s)"):format(name, old))
  elseif old == "" then
    print(("[acquired] %s -> %s"):format(name, new))
  else
    print(("[replaced] %s: %s -> %s"):format(name, old, new))
  end
end)

-- all properties changes on any object (interface-wide match)
bus:on_signal("org.freedesktop.DBus.Properties", nil, function(msg)
  print(("[props]    %s %s.%s"):format(msg.path, msg.interface, msg.member))
end)

bus:mainloop{ timeout = 0.2 }
