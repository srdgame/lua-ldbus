local signature = require "ldbus.signature"

describe("ldbus.signature", function()
  describe("parse", function()
    it("parses basic types into nodes", function()
      local nodes, err = signature.parse("yuqbtxtdsogv")
      assert.is_nil(err)
      assert.equals(12, #nodes)
      for i, code in ipairs({ "y", "u", "q", "b", "t", "x", "t", "d", "s", "o", "g", "v" }) do
        assert.equals(code, nodes[i].code)
      end
    end)

    it("parses nested containers", function()
      local nodes = signature.parse("a{sv}")
      assert.equals("a", nodes[1].code)
      local entry = nodes[1].elem
      assert.equals("e", entry.code)
      assert.equals("s", entry.key.code)
      assert.equals("v", entry.value.code)
    end)

    it("parses structs with fields", function()
      local nodes = signature.parse("(ii(as))")
      local struct = nodes[1]
      assert.equals("r", struct.code)
      assert.equals(3, #struct.fields)
      -- third field is the struct "(as)"
      assert.equals("r", struct.fields[3].code)
      local inner = struct.fields[3].fields[1]
      assert.equals("a", inner.code)
      assert.equals("s", inner.elem.code)
    end)

    it("parses multiple complete types", function()
      local nodes = signature.parse("i{su}as")
      assert.equals(3, #nodes)
      assert.equals("i", nodes[1].code)
      assert.equals("e", nodes[2].code)
      assert.equals("a", nodes[3].code)
      assert.equals("s", nodes[3].elem.code)
    end)

    it("parses empty signature to empty list", function()
      local nodes = signature.parse("")
      assert.equals(0, #nodes)
    end)

    it("rejects unknown type codes", function()
      local nodes, err = signature.parse("z")
      assert.is_nil(nodes)
      assert.truthy(err:find("unknown type code"))
    end)

    it("rejects arrays without element type", function()
      local nodes, err = signature.parse("a")
      assert.is_nil(nodes)
      assert.truthy(err:find("invalid signature"))
    end)

    it("rejects unterminated structs", function()
      local nodes, err = signature.parse("(ii")
      assert.is_nil(nodes)
      assert.truthy(err:find("unterminated"))
    end)

    it("rejects empty structs", function()
      local nodes, err = signature.parse("()")
      assert.is_nil(nodes)
      assert.truthy(err:find("empty struct"))
    end)

    it("parses unix fd type", function()
      local nodes, err = signature.parse("h")
      assert.truthy(nodes)
      assert.is_nil(err)
      assert.equals("h", nodes[1].code)
    end)

    it("parses unix fd nested in arrays", function()
      local nodes, err = signature.parse("ah")
      assert.truthy(nodes)
      assert.is_nil(err)
      assert.equals("a", nodes[1].code)
      assert.equals("h", nodes[1].elem.code)
    end)
  end)

  describe("node_to_string", function()
    it("round-trips complex signatures", function()
      local sigs = {
        "i", "s", "as", "a{sv}", "(ii)", "(i(as)a{sv})", "a(xii)",
        "a{u(yii)}", "aa{sv}", "((y)t)", "a{ss}", "a{sv}(ii)a(i)",
      }
      local types_mod = require "ldbus.types"
      for _, sig in ipairs(sigs) do
        local nodes = signature.parse(sig)
        local ok, first = types_mod.split_complete_type(sig)
        assert.is_true(ok)
        assert.equals(first, signature.node_to_string(nodes[1]), "round-trip failed for " .. sig)
      end
    end)
  end)
end)
