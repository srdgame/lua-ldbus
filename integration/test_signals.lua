-- Integration: signal subscription (AddMatch), emission, delivery.
-- Run via integration/run.sh (inside dbus-run-session).
local ldbus = require "ldbus"

--- Plain-Lua helpers (no busted in integration scripts).
local function equals(a, b)
  assert(a == b, "expected " .. tostring(b) .. ", got " .. tostring(a))
end
local function same(list, expected)
  assert(#list == #expected,
    "expected " .. #expected .. " items, got " .. #list)
  for i, v in ipairs(expected) do
    assert(list[i] == v, "item " .. i .. ": expected " .. tostring(v)
      .. ", got " .. tostring(list[i]))
  end
end

local emitter = assert(ldbus.session())
local receiver = assert(ldbus.session())

-- exact-member match
local exact = {}
assert(receiver:on_signal("com.example.Test", "Changed", function(msg)
  exact[#exact + 1] = msg.body[1]
end))

-- interface-wide match (any member)
local any_member = {}
assert(receiver:on_signal("com.example.Other", nil, function(msg)
  any_member[#any_member + 1] = msg.member
end))

--- Pump the receiver until `cond` holds or the deadline passes.
local function wait_for(cond, what)
  local deadline = os.clock() + 2
  while not cond() and os.clock() < deadline do
    receiver.conn:pump(0.05)
  end
  assert(cond(), "timed out waiting for " .. what)
end

-- 1) exact match receives the signal
emitter:emit("/com/example/Test", "com.example.Test", "Changed", "i", { 42 })
wait_for(function() return #exact == 1 end, "Changed signal")
equals(42, exact[1])
print("Changed delivered:", exact[1])

-- 2) interface-wide match receives every member
emitter:emit("/o", "com.example.Other", "A", "s", { "a" })
emitter:emit("/o", "com.example.Other", "B", "s", { "b" })
wait_for(function() return #any_member == 2 end, "Other signals")
same(any_member, { "A", "B" })
print("interface-wide match ok:", table.concat(any_member, ","))

-- 3) non-matching signals are not delivered
emitter:emit("/o", "com.example.Unrelated", "Changed", "i", { 1 })
wait_for(function() return true end, "nothing") -- just pump time
receiver.conn:pump(0.2)
equals(1, #exact)
print("unrelated signal filtered out")

emitter:close()
receiver:close()
print("test_signals PASSED")
