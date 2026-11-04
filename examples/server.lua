-- Example: export a calculator object on the session bus and serve it
-- under a well-known name. Try it with:
--   dbus-send --session --type=method_call --print-reply \
--     --dest=com.example.Calc /com/example/Calc com.example.Calc.Add int32:2 int32:40
local ldbus = require "ldbus"

local bus, err = ldbus.session()
if not bus then
  error("cannot connect to the session bus: " .. tostring(err))
end

local calc = bus:object("/com/example/Calc")

calc:method("Add", "ii", "i", function(a, b)
  return a + b
end)

calc:method("Divide", "ii", "d", function(a, b)
  if b == 0 then
    error(ldbus.errors.new("com.example.Calc.Error.DivideByZero",
                           "divisor must be nonzero"))
  end
  return a / b
end)

calc:signal("Changed", "i")

local result = bus:request_name("com.example.Calc",
                                ldbus.flags.DO_NOT_QUEUE)
if result ~= ldbus.result.PRIMARY_OWNER then
  error("could not own com.example.Calc (result " .. tostring(result) .. ")")
end
print("serving com.example.Calc on", bus.conn.unique_name)

-- emit Changed whenever Add is called, via a wrapper around the method
local add = function(a, b)
  local sum = a + b
  bus:emit("/com/example/Calc", "com.example.Calc", "Changed",
           { signature = "i", value = sum })
  return sum
end
calc:method("AddEmit", "ii", "i", add)

bus:mainloop{ timeout = 0.1 }
bus:close()
