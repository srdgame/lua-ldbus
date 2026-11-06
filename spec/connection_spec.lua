local Connection = require "ldbus.connection"
local message = require "ldbus.message"
local mock = require "mock_socket"

--- Build a mock io wired to a Connection, with the given scripted
--- replies (each entry = one recv chunk). The connection is NOT
--- authenticated; tests drive message exchange directly.
local function new_conn(replies)
  local io_obj = mock({ replies = replies })
  local conn = Connection(io_obj)
  return conn, io_obj
end

--- Build reply bytes for a serial with given values.
local function reply_bytes(serial, values, sig, err_name)
  return message.build({
    type = err_name and "error" or "method_return",
    serial = serial + 1000,
    reply_serial = serial,
    error_name = err_name,
    signature = sig,
    body = values,
    flags = message.FLAG.NO_REPLY_EXPECTED,
  })
end

describe("ldbus.connection", function()
  describe("serial allocation", function()
    it("increments and skips zero", function()
      local conn = new_conn({})
      local s1 = conn:next_serial()
      local s2 = conn:next_serial()
      assert.equals(1, s1)
      assert.equals(2, s2)
      conn.serial = 4294967295
      local s3 = conn:next_serial()
      assert.equals(1, s3) -- wraps, skipping 0
    end)
  end)

  describe("blocking call over mock io", function()
    it("sends a method call and collects the reply", function()
      local conn = new_conn({})
      -- prime the mock so the pump finds a reply: feed on demand is
      -- tricky, so we reply via a pre-loaded chunk computed from the
      -- serial the call will use (1).
      conn.buf:feed(reply_bytes(1, { "pong" }, "s"))
      local values, err = conn:call("a.b", "/p", "a.b.I", "Echo", nil)
      assert.is_nil(err)
      assert.same({ "pong" }, values)
      -- verify the outgoing message
      local sent = conn.io:sent()
      local outgoing = message.parse(sent)
      assert.equals("method_call", outgoing.type_name)
      assert.equals("Echo", outgoing.member)
      assert.equals(1, outgoing.serial)
    end)

    it("returns err table for D-Bus error replies", function()
      local conn = new_conn({})
      conn.buf:feed(reply_bytes(1, { "no gas" }, "s", "com.x.Err.NoGas"))
      local values, err = conn:call("a.b", "/p", "a.b.I", "Go", nil)
      assert.is_nil(values)
      assert.equals("com.x.Err.NoGas", err.name)
      assert.equals("no gas", err.message)
    end)

    it("times out when no reply arrives", function()
      local conn = new_conn({})
      local values, err = conn:call("a.b", "/p", "a.b.I", "Echo", nil, { timeout = 0.2 })
      assert.is_nil(values)
      assert.truthy(err.message:find("timed out"))
    end)

    it("dispatches unrelated messages while waiting", function()
      local conn = new_conn({})
      local seen = {}
      conn.on_message = function(msg)
        seen[#seen + 1] = msg
      end
      conn.buf:feed(message.build({
        type = "signal", serial = 50, path = "/s",
        interface = "com.x.I", member = "Ping", signature = "i", body = { 1 },
      }))
      conn.buf:feed(reply_bytes(1, { 5 }, "i"))
      local values = conn:call("a.b", "/p", "a.b.I", "Get", nil)
      assert.same({ 5 }, values)
      assert.equals(1, #seen)
      assert.equals("signal", seen[1].type_name)
    end)

    it("sends message with args matching signature", function()
      local conn = new_conn({})
      conn.buf:feed(reply_bytes(1, { 4 }, "i"))
      conn:call("a.b", "/p", "a.b.I", "Add", { 1, 3 }, { signature = "ii" })
      local outgoing = message.parse(conn.io:sent())
      assert.same({ 1, 3 }, outgoing.body)
      assert.equals("ii", outgoing.signature)
    end)

    it("handles a reply split across two chunks", function()
      local conn = new_conn({})
      local data = reply_bytes(1, { "hi" }, "s")
      conn.buf:feed(data:sub(1, 5))
      -- start the call pump manually in pieces
      local serial = conn:send({
        type = message.TYPE.METHOD_CALL, path = "/p",
        interface = "a.b.I", member = "M",
      })
      conn.pending[serial] = function() end
      conn.buf:feed(data:sub(6))
      local msg = conn:pump_until(serial, 1)
      assert.equals("method_return", msg.type_name)
    end)
  end)

  describe("pump", function()
    it("counts dispatched messages", function()
      local conn = new_conn({})
      conn.buf:feed(message.build({
        type = "signal", serial = 1, path = "/s",
        interface = "i", member = "a",
      }))
      conn.buf:feed(message.build({
        type = "signal", serial = 2, path = "/s",
        interface = "i", member = "b",
      }))
      local n = conn:pump(0)
      assert.equals(2, n)
    end)
  end)

  describe("close", function()
    it("marks connection closed", function()
      local conn = new_conn({})
      conn:close()
      assert.is_true(conn.closed)
      assert.is_true(conn.io.closed)
    end)
  end)
end)
