local types = require "ldbus.types"

describe("ldbus.types", function()
  describe("CODES", function()
    it("covers every D-Bus type code", function()
      assert.same({
        BYTE = "y", BOOLEAN = "b", INT16 = "n", UINT16 = "q",
        INT32 = "i", UINT32 = "u", INT64 = "x", UINT64 = "t",
        DOUBLE = "d", STRING = "s", OBJECT_PATH = "o", SIGNATURE = "g",
        ARRAY = "a", STRUCT = "r", DICT_ENTRY = "e", VARIANT = "v",
        UNIX_FD = "h",
      }, types.CODES)
    end)
  end)

  describe("alignment_of", function()
    it("returns base alignment for basic types", function()
      assert.equals(1, types.alignment_of("y"))
      assert.equals(4, types.alignment_of("b"))
      assert.equals(2, types.alignment_of("n"))
      assert.equals(2, types.alignment_of("q"))
      assert.equals(4, types.alignment_of("i"))
      assert.equals(4, types.alignment_of("u"))
      assert.equals(8, types.alignment_of("x"))
      assert.equals(8, types.alignment_of("t"))
      assert.equals(8, types.alignment_of("d"))
      assert.equals(4, types.alignment_of("s"))
      assert.equals(4, types.alignment_of("o"))
      assert.equals(1, types.alignment_of("g"))
      assert.equals(1, types.alignment_of("v"))
    end)

    it("returns 8 for structs and dict entries", function()
      assert.equals(8, types.alignment_of("(ii)"))
      assert.equals(8, types.alignment_of("{su}"))
      assert.equals(8, types.alignment_of("(y(yi))"))
    end)

    it("returns length-prefix alignment for arrays", function()
      assert.equals(4, types.alignment_of("as"))
      assert.equals(4, types.alignment_of("a{sv}"))
      assert.equals(4, types.alignment_of("ay"))
      assert.equals(4, types.alignment_of("a(ai)"))   -- nested arrays: 4
      assert.equals(4, types.alignment_of("a(yi)"))   -- struct elements: 4 prefix
    end)

    it("returns nil for unknown codes", function()
      assert.is_nil(types.alignment_of("z"))
    end)
  end)

  describe("pad_to / padding_needed", function()
    it("pads to alignment", function()
      assert.equals(0, types.pad_to(0, 8))
      assert.equals(8, types.pad_to(1, 8))
      assert.equals(8, types.pad_to(8, 8))
      assert.equals(12, types.pad_to(9, 4))
      assert.equals(4, types.pad_to(3, 4))
      assert.equals(0, types.pad_to(0, 1))
      assert.equals(5, types.pad_to(5, 1))
    end)

    it("computes padding needed", function()
      assert.equals(0, types.padding_needed(8, 8))
      assert.equals(7, types.padding_needed(1, 8))
      assert.equals(3, types.padding_needed(9, 4))
      assert.equals(0, types.padding_needed(0, 4))
      assert.equals(4, types.padding_needed(4, 8))
      assert.equals(0, types.padding_needed(12, 4))
    end)
  end)

  describe("split_complete_type", function()
    local function split(sig)
      local ok, a, b = types.split_complete_type(sig)
      return ok, a, b
    end

    it("splits basic types", function()
      assert.same({ true, "i", "" }, { split("i") })
      assert.same({ true, "s", "" }, { split("s") })
      assert.same({ true, "u", "s" }, { split("us") })
      assert.same({ true, "h", "" }, { split("h") })
    end)

    it("splits arrays", function()
      assert.same({ true, "as", "" }, { split("as") })
      assert.same({ true, "a{sv}", "" }, { split("a{sv}") })
      assert.same({ true, "a(xii)", "v" }, { split("a(xii)v") })
      assert.same({ true, "aay", "" }, { split("aay") })
      assert.same({ true, "aa{yv}", "g" }, { split("aa{yv}g") })
    end)

    it("splits structs", function()
      assert.same({ true, "(ii)", "" }, { split("(ii)") })
      assert.same({ true, "(i(as))", "u" }, { split("(i(as))u") })
      assert.same({ true, "((ss)i)", "" }, { split("((ss)i)") })
    end)

    it("splits dict entries", function()
      assert.same({ true, "{sv}", "" }, { split("{sv}") })
      assert.same({ true, "{yv}", "s" }, { split("{yv}s") })
    end)

    it("rejects malformed signatures", function()
      local ok, err = split("")
      assert.falsy(ok)
      local ok2, err2 = split("(i")
      assert.falsy(ok2)
      local ok3, err3 = split("()")
      assert.falsy(ok3)
      local ok4, err4 = split("{s")
      assert.falsy(ok4)
      local ok5, err5 = split("(i{i})")
      assert.falsy(ok5) -- "{i}" has no complete value type before ')'
      assert.falsy(split("a"))       -- array without element type
      assert.falsy(split("z"))       -- unknown code
      assert.falsy(split("{is)"))    -- missing '}'
    end)

    it("rejects variant keys in dict entries (key must be basic)", function()
      assert.falsy(split("{vs}"))
      assert.falsy(split("{vq}"))
    end)

    it("enforces the maximum nesting depth of 32", function()
      local ok_deep = split(string.rep("(", 32) .. "i" .. string.rep(")", 32))
      assert.is_true(ok_deep)
      assert.falsy(split(string.rep("(", 33) .. "i" .. string.rep(")", 33)))
      assert.falsy(split(string.rep("a", 33) .. "i"))
      assert.is_true(split(string.rep("a", 32) .. "i"))
    end)
  end)

  describe("is_complete_type", function()
    it("accepts complete types", function()
      assert.is_true(types.is_complete_type("i"))
      assert.is_true(types.is_complete_type("a{sv}"))
      assert.is_true(types.is_complete_type("(ii)s"))
      assert.is_true(types.is_complete_type("h"))
    end)

    it("rejects incomplete/malformed types", function()
      assert.falsy(types.is_complete_type(""))
      assert.falsy(types.is_complete_type("a"))
      assert.falsy(types.is_complete_type("(i"))
    end)
  end)

  describe("validate_signature", function()
    it("accepts valid signatures", function()
      local ok, n = types.validate_signature("")
      assert.is_true(ok)
      assert.equals(0, n)
      local ok2, n2 = types.validate_signature("iiasa{sv}(ii)")
      assert.is_true(ok2)
      assert.equals(5, n2)
      local ok3, n3 = types.validate_signature("a{sv}v")
      assert.is_true(ok3)
      assert.equals(2, n3)
    end)

    it("rejects invalid signatures", function()
      assert.falsy(types.validate_signature("a"))
      assert.falsy(types.validate_signature("z"))
      assert.falsy(types.validate_signature("(i"))
      assert.falsy(types.validate_signature("{is}"))  -- dict entry only
                                                      -- valid inside an array
    end)

    it("enforces the 255-byte signature limit", function()
      local ok, _ = types.validate_signature(string.rep("i", 255))
      assert.is_true(ok)
      assert.falsy(types.validate_signature(string.rep("i", 256)))
      -- multi-char types: 100 x "(ii)" = 400 bytes
      assert.falsy(types.validate_signature(string.rep("(ii)", 100)))
      local ok2 = types.validate_signature(string.rep("(ii)", 63) .. "i")
      assert.is_true(ok2)  -- 253 bytes
    end)
  end)

  describe("variant", function()
    it("creates tagged variant tables", function()
      local v = types.variant("s", "hello")
      assert.is_true(types.is_variant(v))
      assert.equals("s", v.signature)
      assert.equals("hello", v.value)
    end)

    it("rejects invalid signatures", function()
      assert.has_error(function() types.variant("a", 1) end)
      assert.has_error(function() types.variant("zz", 1) end)
    end)

    it("accepts unix fd", function()
      local v = types.variant("h", 3)
      assert.is_true(types.is_variant(v))
      assert.equals("h", v.signature)
      assert.equals(3, v.value)
    end)

    it("rejects signatures with more than one complete type", function()
      assert.has_error(function() types.variant("si", 1) end)
      assert.has_error(function() types.variant("(ii)s", 1) end)
    end)

    it("is_variant is false for non-variants", function()
      assert.falsy(types.is_variant({}))
      assert.falsy(types.is_variant("s"))
      assert.falsy(types.is_variant(nil))
      assert.falsy(types.is_variant({ signature = "s", value = "x" }))
    end)
  end)
end)
