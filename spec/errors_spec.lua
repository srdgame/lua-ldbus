local errors = require "ldbus.errors"
local message = require "ldbus.message"

describe("ldbus.errors", function()
  it("defines standard error names", function()
    assert.equals("org.freedesktop.DBus.Error.Failed", errors.FAILED)
    assert.equals("org.freedesktop.DBus.Error.UnknownMethod", errors.UNKNOWN_METHOD)
    assert.equals("org.freedesktop.DBus.Error.UnknownObject", errors.UNKNOWN_OBJECT)
    assert.equals("org.freedesktop.DBus.Error.InvalidArgs", errors.INVALID_ARGS)
    assert.equals("org.freedesktop.DBus.Error.NameHasNoOwner", errors.NAME_HAS_NO_OWNER)
  end)

  describe("new", function()
    it("creates a DBusError with tostring", function()
      local e = errors.new(errors.FAILED, "out of fuel")
      assert.equals(errors.FAILED, e.name)
      assert.equals("out of fuel", e.message)
      assert.equals(errors.FAILED .. ": out of fuel", tostring(e))
    end)

    it("is detected by errors.is", function()
      assert.is_true(errors.is(errors.new(errors.FAILED, "x")))
      assert.is_false(errors.is({ name = errors.FAILED }))
      assert.is_false(errors.is("plain string"))
    end)
  end)

  describe("from_message", function()
    it("builds an error from an ERROR message", function()
      local msg = message.build({
        type = "error", serial = 2, reply_serial = 1,
        error_name = "com.x.Err.NoGas",
        signature = "s", body = { "tank empty" },
      })
      local e = errors.from_message(message.parse(msg))
      assert.equals("com.x.Err.NoGas", e.name)
      assert.equals("tank empty", e.message)
    end)

    it("tolerates an error reply without body", function()
      local msg = message.build({
        type = "error", serial = 2, reply_serial = 1,
        error_name = "com.x.Err.Silent",
      })
      local e = errors.from_message(message.parse(msg))
      assert.equals("com.x.Err.Silent", e.name)
      assert.equals("", e.message)
    end)
  end)

  describe("reply opts", function()
    it("builds opts for an error reply to a call", function()
      local call = message.parse(message.build({
        type = "method_call", serial = 42, path = "/p",
        interface = "a.b.I", member = "M", sender = ":1.5",
      }))
      local opts = errors.reply_opts(call, errors.FAILED, "boom")
      assert.equals("error", opts.type)
      assert.equals(42, opts.reply_serial)
      assert.equals(":1.5", opts.destination)
      assert.equals(errors.FAILED, opts.error_name)
      assert.equals("s", opts.signature)
      assert.same({ "boom" }, opts.body)
      assert.equals(1, opts.flags) -- NO_REPLY_EXPECTED
    end)
  end)
end)
