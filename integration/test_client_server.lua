-- Integration: two bus connections in one process — client calls methods
-- exported by the server (request_name, success, error, unknown method).
-- Run via integration/run.sh (inside dbus-run-session).
local ldbus = require "ldbus"
local message = require "ldbus.message"

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

local server = assert(ldbus.session())
local client = assert(ldbus.session())
print("server:", server.conn.unique_name, "client:", client.conn.unique_name)

-- export an object on the server
local obj = server:object("/com/example/Calc")
obj:method("Add", "ii", "i", function(a, b) return a + b end)
obj:method("Boom", "", "", function() error("exploded") end)
obj:method("Fire", "", "", function() fired = true end)

-- own a well-known name
local result = server:request_name("com.example.Calc")
assert(result == ldbus.result.PRIMARY_OWNER,
       "RequestName result: " .. tostring(result))
print("owns name com.example.Calc")

--- Send a call from the client and pump both sides until the reply
--- (or timeout). Returns the reply message table.
local function roundtrip(member, args, sig, dest, iface, path)
  local serial = client.conn:send({
    type = "method_call",
    destination = dest or "com.example.Calc",
    path = path or "/com/example/Calc",
    interface = iface or "com.example.Calc",
    member = member,
    signature = sig or "",
    body = args,
  })
  local reply
  client.conn.pending[serial] = function(msg) reply = msg end
  local deadline = os.clock() + 2
  while not reply and os.clock() < deadline do
    server.conn:pump(0.05)
    client.conn:pump(0.05)
  end
  assert(reply, "no reply for " .. member)
  return reply
end

-- 1) success path
local reply = roundtrip("Add", { 2, 40 }, "ii")
equals("method_return", reply.type_name)
same(reply.body, { 42 })
print("Add(2,40) =", reply.body[1])

-- 2) Lua error becomes a D-Bus error reply
reply = roundtrip("Boom")
equals("error", reply.type_name)
equals("org.freedesktop.DBus.Error.Failed", reply.error_name)
same(reply.body, { "exploded" })
print("Boom ->", reply.error_name)

-- 3) unknown method gets UnknownMethod
reply = roundtrip("Nonexistent")
equals("error", reply.type_name)
equals("org.freedesktop.DBus.Error.UnknownMethod", reply.error_name)
print("Nonexistent ->", reply.error_name)

-- 4) NO_REPLY_EXPECTED: dispatched, no reply sent
client.conn:call_noreply("com.example.Calc", "/com/example/Calc",
                         "com.example.Calc", "Fire")
local deadline = os.clock() + 2
while not fired and os.clock() < deadline do
  server.conn:pump(0.05)
end
assert(fired, "Fire handler not invoked")
assert(client.conn:pump(0.1) == 0, "unexpected reply for noreply call")
print("Fire (noreply) ok")

-- 5) introspection: Introspectable.Introspect returns the XML
local reply = roundtrip("Introspect", nil, "", "com.example.Calc",
                        "org.freedesktop.DBus.Introspectable",
                        "/com/example/Calc")
equals("method_return", reply.type_name)
local xml = reply.body[1]
assert(type(xml) == "string", "Introspect failed")
assert(xml:find("<!DOCTYPE node"), "missing DOCTYPE")
assert(xml:find('<method name="Add">'), "Add missing from XML")
assert(xml:find('<interface name="org.freedesktop.DBus.Introspectable">'),
       "Introspectable built-in missing")
print("Introspect ok, xml len:", #xml)

server:close()
client:close()
print("test_client_server PASSED")
