local ldbus = require "ldbus"
local Connection = require "ldbus.connection"
local mainloop = require "ldbus.mainloop"
local message = require "ldbus.message"
local mock = require "mock_socket"

--- Bus over a mock io.
local function mock_bus()
  local io_obj = mock.new({})
  return ldbus.wrap(Connection.new(io_obj)), io_obj
end

--- Build a method_return for `serial` with values.
local function reply_bytes(serial, sig, values)
  return message.build({
    type = "method_return", serial = serial + 500, reply_serial = serial,
    signature = sig, body = values, flags = message.FLAG.NO_REPLY_EXPECTED,
  })
end

describe("ldbus.mainloop", function()
  it("exposes Bus:mainloop / Bus:quit / ldbus.mainloop", function()
    assert.is_function(mainloop.run)
    assert.is_function(ldbus.mainloop)
    local bus = mock_bus()
    assert.is_function(bus.mainloop)
    assert.is_function(bus.quit)
  end)

  it("runs an init task; yielding call() is resumed by the reply", function()
    local bus = mock_bus()
    local result
    bus.conn.buf:feed(reply_bytes(1, "s", { "async-pong" }))
    mainloop.run(bus, {
      timeout = 0.01,
      init = function()
        local values = bus:call("a.b", "/p", "a.b.I", "Echo", { "x" },
                                { signature = "s" })
        result = values[1]
      end,
["until"] = function() return result ~= nil end,
    })
    assert.equals("async-pong", result)
    -- connection left loop mode after the loop
    assert.is_false(bus.conn.loop_mode)
  end)

  it("handlers run as coroutines and may call() (nested yield)", function()
    local bus, io_obj = mock_bus()
    -- incoming method_call whose handler will make a nested call;
    -- the nested outbound call gets serial 1 (first on this connection)
    bus.conn.buf:feed(message.build({
      type = "method_call", serial = 100, path = "/calc",
      interface = "com.x.Calc", member = "TwicePlus",
      sender = ":1.9", signature = "i", body = { 10 },
    }))
    local handler_result
    local obj = bus:object("/calc")
    obj:method("TwicePlus", "i", "i", function(n)
      local v = bus:call(":1.99", "/helper", "com.x.H", "Double", { n },
                         { signature = "i" })
      handler_result = v[1]
      return handler_result + 20
    end)
    -- deliver the nested call's reply only once it has actually been
    -- sent (visible on the mock io), simulating a live peer
    local fed = false
    mainloop.run(bus, {
      timeout = 0.01,
      ["until"] = function()
        if not fed and #io_obj:sent() > 0 then
          bus.conn.buf:feed(reply_bytes(1, "i", { 21 }))
          fed = true
        end
        return handler_result ~= nil
      end,
    })
    assert.equals(21, handler_result)
  end)

  it("quit() stops the loop", function()
    local bus = mock_bus()
    local iterations = 0
    bus.conn._loop_probe = nil
    mainloop.run(bus, {
      timeout = 0.01,
      init = function()
        -- self-schedule: quit right away
        bus:quit()
      end,
["until"] = function()
        iterations = iterations + 1
        return iterations > 100 -- safety net
      end,
    })
    assert.is_true(iterations < 100)
  end)

  it("task errors inside the loop do not stop it", function()
    local bus = mock_bus()
    local survived = false
    mainloop.run(bus, {
      timeout = 0.01,
      init = function()
        error("task blew up")
      end,
["until"] = function()
        survived = true
        return true
      end,
    })
    assert.is_true(survived)
  end)

  it("call timeout inside mainloop returns Timeout error", function()
    local bus = mock_bus() -- nothing fed: no reply will come
    local err
    mainloop.run(bus, {
      timeout = 0.01,
      init = function()
        local _, e = bus:call("a.b", "/p", "a.b.I", "Echo", nil, { timeout = 0.05 })
        err = e
      end,
["until"] = function() return err ~= nil end,
    })
    assert.equals("org.freedesktop.DBus.Error.Timeout", err.name)
  end)
end)
