-- Integration: coroutine mainloop — a handler performs a nested yielding
-- call to another service, errors propagate, client calls yield.
-- Run via integration/run.sh (inside dbus-run-session).
local ldbus = require "ldbus"

local svc_a = assert(ldbus.session())
local svc_b = assert(ldbus.session())
local client = assert(ldbus.session())
print("a:", svc_a.conn.unique_name, "b:", svc_b.conn.unique_name,
      "client:", client.conn.unique_name)

local function equals(a, b)
  assert(a == b, "expected " .. tostring(b) .. ", got " .. tostring(a))
end

-- service A chains to service B inside its handler
local obja = svc_a:object("/a")
obja:method("Chain", "i", "i", function(n)
  local v = svc_a:call(svc_b.conn.unique_name, "/b",
                       "com.example.B", "Double", { n }, { signature = "i" })
  return v[1]
end)
obja:method("Boom", "", "", function() error("chain failure") end)

local objb = svc_b:object("/b")
objb:method("Double", "i", "i", function(n) return n * 2 end)

local results = {}
local calls_done = 0

-- one mainloop drives all three connections with a single scheduler
ldbus.mainloop({ svc_a, svc_b, client }, {
  timeout = 0.05,
  init = function()
    -- 1) nested cross-service call: A.Chain -> B.Double
    local r = client:call(svc_a.conn.unique_name, "/a",
                          "com.example.A", "Chain", { 21 }, { signature = "i" })
    results.chain = r[1]
    calls_done = calls_done + 1

    -- 2) error inside the coroutine handler propagates to the client
    local _, err = client:call(svc_a.conn.unique_name, "/a",
                               "com.example.A", "Boom", nil)
    results.err_name = err and err.name
    results.err_msg = err and err.message
    calls_done = calls_done + 1
  end,
  ["until"] = function() return calls_done >= 2 end,
})

equals(42, results.chain)
print("Chain(21) ->", results.chain)
equals("org.freedesktop.DBus.Error.Failed", results.err_name)
equals("chain failure", results.err_msg)
print("Boom ->", results.err_name .. ": " .. results.err_msg)

svc_a:close()
svc_b:close()
client:close()
print("test_mainloop PASSED")
