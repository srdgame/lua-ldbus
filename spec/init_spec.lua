local ldbus = require "ldbus"
local Connection = require "ldbus.connection"
local router = require "ldbus.router"
local message = require "ldbus.message"
local mock = require "mock_socket"

--- A Bus over a mock io (no bus daemon behind it).
local function mock_bus()
  local io_obj = mock.new({})
  local conn = Connection.new(io_obj)
  return ldbus.wrap(conn), io_obj
end

describe("ldbus (public API)", function()
  it("exposes version and RequestName flags", function()
    assert.truthy(ldbus._VERSION)
    assert.equals(2, ldbus.flags.REPLACE_EXISTING)
  end)

  it("session/system/connect fail gracefully without a bus", function()
    -- DBUS_SESSION_BUS_ADDRESS unset in this env; whatever happens it
    -- must return nil+err rather than raising.
    local bus, err = ldbus.session()
    if not bus then
      assert.truthy(err)
    end
  end)

  describe("bus wrapper over mock conn", function()
    it("delegates call to the connection", function()
      local bus = mock_bus()
      bus.conn.buf:feed(message.build({
        type = "method_return", serial = 1001, reply_serial = 1,
        signature = "s", body = { "pong" },
        flags = message.FLAG.NO_REPLY_EXPECTED,
      }))
      local values = bus:call("a.b", "/p", "a.b.I", "Echo", nil)
      assert.same({ "pong" }, values)
    end)

    it("object():method() registers handlers reachable via dispatch", function()
      local bus, io_obj = mock_bus()
      local obj = bus:object("/calc")
      obj:method("Add", "ii", "i", function(a, b) return a + b end)
      bus.conn.buf:feed(message.build({
        type = "method_call", serial = 5, path = "/calc",
        interface = "com.x.Calc", member = "Add",
        sender = ":1.2", signature = "ii", body = { 2, 40 },
      }))
      bus.conn:pump(0)
      local reply = message.parse(io_obj:sent())
      assert.equals("method_return", reply.type_name)
      assert.same({ 42 }, reply.body)
    end)

    it("object():signal() declares signals (metadata only)", function()
      local bus = mock_bus()
      local obj = bus:object("/calc")
      local s = obj:signal("Changed", "i")
      assert.equals("Changed", s.member)
      assert.equals("i", s.signature)
    end)

    it("emit() sends a signal with signature + values", function()
      local bus, io_obj = mock_bus()
      bus:emit("/x", "com.x.I", "Changed", "i", { 3 })
      local s = message.parse(io_obj:sent())
      assert.equals("signal", s.type_name)
      assert.same({ 3 }, s.body)
    end)

    it("emit() accepts the { signature = , value = } shorthand", function()
      local bus, io_obj = mock_bus()
      bus:emit("/x", "com.x.I", "Changed", { signature = "s", value = "hi" })
      local s = message.parse(io_obj:sent())
      assert.equals("s", s.signature)
      assert.same({ "hi" }, s.body)
    end)

    it("on_signal(add_match=false) registers without a bus round-trip", function()
      local bus, io_obj = mock_bus()
      local seen
      bus:on_signal("com.x.I", "Changed", function(msg) seen = msg.body[1] end,
                    { add_match = false })
      assert.equals(0, #io_obj:sent())
      bus.conn.buf:feed(message.build({
        type = "signal", serial = 9, path = "/s",
        interface = "com.x.I", member = "Changed",
        signature = "i", body = { 11 },
      }))
      bus.conn:pump(0)
      assert.equals(11, seen)
    end)

    it("request_name() calls RequestName and returns the result code", function()
      local bus, io_obj = mock_bus()
      -- preload the expected reply for the first outbound serial (1)
      bus.conn.buf:feed(message.build({
        type = "method_return", serial = 1001, reply_serial = 1,
        signature = "u", body = { 1 },
        flags = message.FLAG.NO_REPLY_EXPECTED,
      }))
      local result = bus:request_name("com.example.Calc")
      assert.equals(1, result)
      local sent = message.parse(io_obj:sent())
      assert.equals("RequestName", sent.member)
      assert.same({ "com.example.Calc", 0 }, sent.body)
    end)

    it("close() closes the underlying connection", function()
      local bus, io_obj = mock_bus()
      bus:close()
      assert.is_true(bus.conn.closed)
      assert.is_true(io_obj.closed)
    end)
  end)
end)
