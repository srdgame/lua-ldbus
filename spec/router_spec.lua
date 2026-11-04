local Connection = require "ldbus.connection"
local router = require "ldbus.router"
local errors = require "ldbus.errors"
local message = require "ldbus.message"
local mock = require "mock_socket"

--- Connection wired to a mock io. `feed_in(data)` injects incoming bytes.
local function new_conn()
  local io_obj = mock.new({})
  local conn = Connection.new(io_obj)
  router.attach(conn)
  return conn, io_obj
end

--- Parse everything written by the mock io into a message list.
local function sent_messages(io_obj)
  local raw = io_obj:sent()
  local out = {}
  local pos = 1
  while pos <= #raw do
    local total = message.total_len(raw:sub(pos, pos + 16))
    local msg, err = message.parse(raw:sub(pos, pos + total))
    assert(msg, err)
    out[#out + 1] = msg
    pos = pos + total
  end
  return out
end

--- Build an incoming method_call message and feed it to the connection.
local function feed_call(conn, opts)
  conn.buf:feed(message.build({
    type = "method_call", serial = opts.serial,
    path = opts.path or "/p", interface = opts.interface or "a.b.I",
    member = opts.member, destination = opts.destination,
    sender = opts.sender or ":1.9",
    signature = opts.signature, body = opts.body,
    flags = opts.flags,
  }))
end

describe("ldbus.router", function()
  describe("method dispatch", function()
    it("invokes a registered handler and sends method_return", function()
      local conn, io_obj = new_conn()
      local obj = router.object(conn, "/p")
      router.method(obj, "Echo", "s", "s", function(s) return s .. "!" end)
      feed_call(conn, { serial = 10, member = "Echo", signature = "s", body = { "hi" } })
      conn.buf:feed("") -- nothing else pending
      conn:pump(0)
      local replies = sent_messages(io_obj)
      assert.equals(1, #replies)
      local r = replies[1]
      assert.equals("method_return", r.type_name)
      assert.equals(10, r.reply_serial)
      assert.equals(":1.9", r.destination)
      assert.same({ "hi!" }, r.body)
    end)

    it("handles multiple return values", function()
      local conn, io_obj = new_conn()
      local obj = router.object(conn, "/p")
      router.method(obj, "Div", "ii", "is", function(a, b) return a // b, "ok" end)
      feed_call(conn, { serial = 11, member = "Div", signature = "ii", body = { 9, 3 } })
      conn:pump(0)
      local r = sent_messages(io_obj)[1]
      assert.equals("is", r.signature)
      assert.same({ 3, "ok" }, r.body)
    end)

    it("returns UnknownObject error for unregistered paths", function()
      local conn, io_obj = new_conn()
      feed_call(conn, { serial = 12, path = "/nowhere", member = "X" })
      conn:pump(0)
      local r = sent_messages(io_obj)[1]
      assert.equals("error", r.type_name)
      assert.equals("org.freedesktop.DBus.Error.UnknownObject", r.error_name)
    end)

    it("returns UnknownMethod error for unregistered members", function()
      local conn, io_obj = new_conn()
      router.object(conn, "/p")
      feed_call(conn, { serial = 13, member = "Missing" })
      conn:pump(0)
      local r = sent_messages(io_obj)[1]
      assert.equals("org.freedesktop.DBus.Error.UnknownMethod", r.error_name)
    end)

    it("converts handler errors into error replies", function()
      local conn, io_obj = new_conn()
      local obj = router.object(conn, "/p")
      router.method(obj, "Boom", "", "", function() error("kaboom") end)
      feed_call(conn, { serial = 14, member = "Boom" })
      conn:pump(0)
      local r = sent_messages(io_obj)[1]
      assert.equals("error", r.type_name)
      assert.equals("org.freedesktop.DBus.Error.Failed", r.error_name)
      assert.same({ "kaboom" }, r.body)
    end)

    it("supports custom error names via DBusError", function()
      local conn, io_obj = new_conn()
      local obj = router.object(conn, "/p")
      router.method(obj, "Bad", "s", "", function(arg)
        error(errors.new("com.x.Err.Bad", "wrong: " .. arg))
      end)
      feed_call(conn, { serial = 15, member = "Bad", signature = "s", body = { "x" } })
      conn:pump(0)
      local r = sent_messages(io_obj)[1]
      assert.equals("com.x.Err.Bad", r.error_name)
      assert.same({ "wrong: x" }, r.body)
    end)

    it("does not reply to NO_REPLY_EXPECTED calls", function()
      local conn, io_obj = new_conn()
      local obj = router.object(conn, "/p")
      router.method(obj, "Fire", "", "", function() end)
      feed_call(conn, { serial = 16, member = "Fire", flags = message.FLAG.NO_REPLY_EXPECTED })
      conn:pump(0)
      assert.equals(0, #sent_messages(io_obj))
    end)

    it("pings built-in org.freedesktop.DBus.Peer.Ping", function()
      local conn, io_obj = new_conn()
      feed_call(conn, { serial = 17, interface = "org.freedesktop.DBus.Peer", member = "Ping" })
      conn:pump(0)
      assert.equals("method_return", sent_messages(io_obj)[1].type_name)
    end)
  end)

  describe("signal handlers", function()
    it("calls matching handlers on pump", function()
      local conn = new_conn()
      local seen = {}
      router.on_signal(conn, "com.x.I", "Changed", function(msg)
        seen[#seen + 1] = msg.body[1]
      end)
      conn.buf:feed(message.build({
        type = "signal", serial = 20, path = "/s",
        interface = "com.x.I", member = "Changed",
        signature = "i", body = { 7 },
      }))
      conn.buf:feed(message.build({
        type = "signal", serial = 21, path = "/s",
        interface = "com.x.I", member = "Other",
        signature = "i", body = { 99 },
      }))
      conn:pump(0)
      assert.same({ 7 }, seen)
    end)

    it("supports multiple handlers for one match", function()
      local conn = new_conn()
      local a, b = 0, 0
      router.on_signal(conn, "com.x.I", "Changed", function() a = a + 1 end)
      router.on_signal(conn, "com.x.I", "Changed", function() b = b + 1 end)
      conn.buf:feed(message.build({
        type = "signal", serial = 22, path = "/s",
        interface = "com.x.I", member = "Changed",
      }))
      conn:pump(0)
      assert.equals(1, a)
      assert.equals(1, b)
    end)
  end)

  describe("emit", function()
    it("sends a signal message", function()
      local conn, io_obj = new_conn()
      router.emit(conn, "/x", "com.x.I", "Changed", "i", { 5 })
      local msgs = sent_messages(io_obj)
      assert.equals(1, #msgs)
      local s = msgs[1]
      assert.equals("signal", s.type_name)
      assert.equals("/x", s.path)
      assert.equals("com.x.I", s.interface)
      assert.equals("Changed", s.member)
      assert.equals("i", s.signature)
      assert.same({ 5 }, s.body)
      assert.equals(1, s.flags) -- NO_REPLY_EXPECTED
    end)
  end)
end)
