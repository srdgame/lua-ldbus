local uid = require "ldbus.uid"

describe("ldbus.uid", function()
  describe("hex_encode", function()
    it("hex-encodes ASCII strings", function()
      assert.equals("31303030", uid.hex_encode("1000"))
      assert.equals("30", uid.hex_encode("0"))
      assert.equals("", uid.hex_encode(""))
    end)
  end)

  describe("external_identity", function()
    it("hex-encodes the decimal uid string (SASL EXTERNAL)", function()
      assert.equals("31303030", uid.external_identity(1000))
      assert.equals("30", uid.external_identity(0))
    end)
  end)

  describe("current_uid", function()
    it("parses /proc/self/status Uid line", function()
      local fake = function()
        return {
          lines = function()
            return coroutine.wrap(function()
              coroutine.yield("Name:\tlua5.4")
              coroutine.yield("Uid:\t1000\t1000\t1000\t1000")
              coroutine.yield("Gid:\t1000\t1000\t1000\t1000")
            end)
          end,
          close = function() end,
        }
      end
      local u = uid.current_uid(fake)
      assert.equals(1000, u)
    end)

    it("returns error when file cannot be opened", function()
      local u, err = uid.current_uid(function() return nil end)
      assert.is_nil(u)
      assert.truthy(err)
    end)

    it("returns error when no Uid line present", function()
      local fake = function()
        return {
          lines = function() return coroutine.wrap(function() coroutine.yield("Name:\tx") end) end,
          close = function() end,
        }
      end
      local u, err = uid.current_uid(fake)
      assert.is_nil(u)
      assert.truthy(err)
    end)

    it("reads the real uid on this system", function()
      local u = uid.current_uid()
      assert.is_number(u)
      assert.is_true(u >= 0)
    end)
  end)
end)
