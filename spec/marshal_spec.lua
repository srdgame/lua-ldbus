local marshal = require "ldbus.marshal"
local types = require "ldbus.types"

local function hex(s)
  return (s:gsub(".", function(c) return ("%02x"):format(c:byte()) end))
end

local function enc(sig, values)
  return marshal.encode_signature(sig, values)
end

describe("ldbus.marshal", function()
  describe("basic types", function()
    it("encodes byte", function()
      assert.equals("2a", hex(enc("y", { 42 })))
    end)

    it("encodes uint32", function()
      assert.equals("2a000000", hex(enc("u", { 42 })))
    end)

    it("encodes int16 negative", function()
      -- -8706 two's complement = 0xDDFE, little-endian bytes fe dd
      assert.equals("fedd", hex(enc("n", { -8706 })))
    end)

    it("encodes uint16 max", function()
      assert.equals("ffff", hex(enc("q", { 65535 })))
    end)

    it("encodes boolean true/false", function()
      assert.equals("01000000", hex(enc("b", { true })))
      assert.equals("00000000", hex(enc("b", { false })))
    end)

    it("encodes int64 / uint64", function()
      assert.equals("0100000000000000", hex(enc("x", { 1 })))
      assert.equals("ffffffffffffffff", hex(enc("t", { -1 }))) -- wraps to 2^64-1
    end)

    it("encodes double", function()
      -- 1.5 little endian IEEE754
      assert.equals("000000000000f83f", hex(enc("d", { 1.5 })))
    end)

    it("encodes strings with length and NUL terminator", function()
      -- "hello": len=5 (5 00 00 00) + "hello\0"
      assert.equals("0500000068656c6c6f00", hex(enc("s", { "hello" })))
    end)

    it("encodes empty string", function()
      assert.equals("0000000000", hex(enc("s", { "" })))
    end)

    it("encodes signature (NUL-terminated)", function()
      -- "ai": len=2 + "ai" + NUL
      assert.equals("02616900", hex(enc("g", { "ai" })))
    end)
  end)

  describe("unix fd ('h')", function()
    it("encodes to the fd index in the message fd array", function()
      -- each 'h' encoded claims the next index: first 'h' -> 0
      assert.equals("00000000", hex(enc("h", { 7 })))
      -- a second 'h' in the same body -> index 1
      assert.equals("00000000" .. "01000000", hex(enc("hh", { 7, 8 })))
    end)

    it("decodes an index to the real fd from the fds table", function()
      local values, err = marshal.decode_signature("h", "\0\0\0\0", { 42 })
      assert.is_nil(err)
      assert.same({ 42 }, values)
    end)

    it("errors when the fd index is out of range", function()
      local values, err = marshal.decode_signature("h", "\0\0\0\0", {})
      assert.is_nil(values)
      assert.truthy(err)
      local values2, err2 = marshal.decode_signature("h", "\010\0\0\0", { 42 })
      assert.is_nil(values2)
      assert.truthy(err2)
    end)

    it("round-trips fds nested in containers", function()
      -- dict s -> h
      local raw = enc("a{sh}", { { take = 0 } })
      local values, err = marshal.decode_signature("a{sh}", raw, { 9 })
      assert.is_nil(err)
      assert.same({ { take = 9 } }, values)
      -- fd array at the top level
      local raw2 = enc("ah", { { 0 } })
      local values2, err2 = marshal.decode_signature("ah", raw2, { 5 })
      assert.is_nil(err2)
      assert.same({ { 5 } }, values2)
    end)

    it("counts fds in a signature", function()
      assert.equals(0, marshal.count_fds("su(ii)as"))
      assert.equals(1, marshal.count_fds("h"))
      assert.equals(2, marshal.count_fds("ahsh"))
    end)
  end)

  describe("alignment", function()
    it("pads strings to 4-byte boundaries between fields", function()
      -- signature "ss": "a" (00000000 6100) then "b" at offset 6 -> align to 8
      local data = enc("ss", { "a", "b" })
      assert.equals("0100000061000000" .. "010000006200", hex(data))
    end)

    it("aligns u64 after a string", function()
      -- "sx": "hi" = 02000000 68 69 00 (7 bytes), pad 1 to offset 8, then u64 7
      local data = enc("sx", { "hi", 7 })
      assert.equals("02000000686900" .. "00" .. "0700000000000000", hex(data))
    end)
  end)

  describe("structs", function()
    it("encodes struct 8-aligned at offset 0", function()
      -- "(yu)": y=3 pad3, u=9
      assert.equals("03000000" .. "09000000", hex(enc("(yu)", { { 3, 9 } })))
    end)

    it("8-aligns struct after leading byte", function()
      -- "y(yu)": y=3, pad to 8, struct {3,9}
      local data = enc("y(yu)", { 3, { 3, 9 } })
      assert.equals("03" .. "00000000000000" .. "03000000" .. "09000000", hex(data))
    end)

    it("rejects field count mismatch", function()
      assert.has_error(function() enc("(ii)", { { 1 } }) end)
    end)
  end)

  describe("arrays", function()
    it("encodes empty array as zero length only", function()
      assert.equals("00000000", hex(enc("as", { {} })))
    end)

    it("encodes byte array", function()
      assert.equals("03000000010203", hex(enc("ay", { { 1, 2, 3 } })))
    end)

    it("aligns first element for non-1-aligned element types", function()
      -- "ai" {5}: len=4, elem 05 00 00 00
      assert.equals("0400000005000000", hex(enc("ai", { { 5 } })))
    end)

    it("aligns elements relative to array body start (D-Bus spec example)", function()
      -- The spec example: signature "yai", value {3, {5}}:
      -- y=3, array at offset 1: pad to 4, len=4, elem aligned inside body
      local data = enc("yai", { 3, { 5 } })
      assert.equals("03" .. "000000" .. "04000000" .. "05000000", hex(data))
    end)

    it("aligns nested struct elements to 8 bytes inside array body", function()
      -- "a(yu)" with one entry {5,6}: body starts at offset 4, struct
      -- aligns to 8 (4 pad, not counted in length), y=5, u aligns to 4,
      -- element bytes = 8 = 0x08
      local data = enc("a(yu)", { { { 5, 6 } } })
      assert.equals("08000000"
        .. "00000000"
        .. "05000000"
        .. "06000000", hex(data))
    end)

    it("encodes array of arrays", function()
      -- "aay" { {1}, {2,3} }: inner array lengths are 4-aligned even
      -- though byte elements need no alignment: len=1+byte(1)=2, pad3,
      -- len=2+bytes=4; total body = 2 + 3pad? no: 4 + 1 + 3pad? -> 14 = 0x0e
      local data = enc("aay", { { { 1 }, { 2, 3 } } })
      assert.equals("0e000000"
        .. "01000000" .. "01" .. "000000"
        .. "02000000" .. "0203", hex(data))
    end)
  end)

  describe("dict entries", function()
    it("encodes empty dict", function()
      -- length 0, but the mandatory leading padding is still emitted
      assert.equals("00000000" .. "00000000", hex(enc("a{sv}", { {} })))
    end)

    it("encodes string->string dict", function()
      -- body starts at offset 4; first entry is 8-aligned so 4 bytes pad
      -- (not counted in the length); key "k": 01000000 6b00 (6 bytes),
      -- value aligns to 4 (2 pad), "v": 01000000 7600
      local data = enc("a{ss}", { { k = "v" } })
      assert.equals("0e000000"
        .. "00000000"
        .. "010000006b00"
        .. "0000"
        .. "010000007600",
        hex(data))
      -- length = 6 + 2 + 6 = 14 = 0x0e
    end)

    it("encodes sv dict with variant", function()
      local data = enc("a{sv}", { { key = types.variant("s", "val") } })
      -- body: 4 pad (entry 8-align, not counted in length), key "key"
      -- (8 bytes), sig "s" = 0173, value aligns to 4 (1 pad),
      -- "val" = 03000000 76616c00
      assert.equals("14000000"
        .. "00000000"
        .. "030000006b657900"
        .. "017300"
        .. "00"
        .. "0300000076616c00",
        hex(data))
      -- length = 8 + 3 + 1 + 8 = 20 = 0x14 (padding excluded)
    end)

    it("encodes dict with numeric keys sorted", function()
      local data = enc("a{yu}", { { [3] = 30, [1] = 10, [2] = 20 } })
      -- body: 4 bytes alignment pad (body starts at offset 4, entries at 8,
      -- padding excluded from the length), then 3 x 8-byte entries
      local h = hex(data)
      assert.equals("18000000", h:sub(1, 8))
      -- entries sorted 1,2,3 after the leading pad
      assert.equals("00000000"
        .. "01000000" .. "0a000000"
        .. "02000000" .. "14000000"
        .. "03000000" .. "1e000000",
        h:sub(9))
    end)
  end)

  describe("variants", function()
    it("encodes variant with u32", function()
      -- sig "u" = 01 75 00 (3 bytes), u32 aligns to 4 (1 pad), then 42
      assert.equals("01750000" .. "2a000000", hex(enc("v", { types.variant("u", 42) })))
    end)

    it("encodes variant of variant", function()
      local data = enc("v", { types.variant("v", types.variant("y", 7)) })
      -- 'g' is NUL-terminated: len+v = 017600, len+y = 017900, byte 07
      assert.equals("01760001790007", hex(data))
    end)

    it("rejects plain values for variant", function()
      assert.has_error(function() enc("v", { 42 }) end)
    end)
  end)

  describe("round-trips", function()
    local cases = {
      { "y", { 255 } },
      { "bb", { true, false } },
      { "nq", { -32768, 65535 } },
      { "iu", { -2147483648, 4294967295 } },
      { "xt", { math.mininteger, math.maxinteger } },
      { "t", { -1 } }, -- wraps to 2^64-1
      { "dd", { 3.14159, -1.5e-10 } },
      { "sss", { "", "hello world", "unicode: héllo" } },
      { "o", { "/org/freedesktop/systemd1" } },
      { "g", { "a{sv}(ii)" } },
      { "vvv", { types.variant("s", "text"), types.variant("(ii)", { 1, 2 }),
               types.variant("a{sv}", { k = types.variant("u", 1) }) } },
      { "as", { { "a", "b", "long string here" } } },
      { "aas", { { { "x" }, { "y", "z" }, {} } } },
      { "aay", { { { 1 }, { 2, 3 }, {} } } },
      { "ai", { { 1, -2, 3 } } },
      { "ay", { { 0, 255 } } },
      { "ad", { { 0.5 } } },
      { "ab", { { true, false } } },
      { "a(yu)", { { { 1, 2 }, { 3, 4 } } } },
      { "a{ss}", { { a = "1", b = "2" } } },
      { "a{sv}", { { s = types.variant("s", "x"), n = types.variant("i", -5) } } },
      { "a{yy}", { { [1] = 2, [200] = 100 } } },
      { "a{yv}", { { [1] = types.variant("s", "a"), [200] = types.variant("u", 7) } } },
      { "(ii(dd))", { { 1, 2, { 0.5, -0.5 } } } },
      { "a(ia{sv})", { { { 1, { x = types.variant("y", 3) } } } } },
    }

    for _, case in ipairs(cases) do
      it("round-trips signature " .. case[1], function()
        local values = case[2]
        local data = enc(case[1], values)
        local decoded, err = marshal.decode_signature(case[1], data)
        assert.is_nil(err)
        -- u64 wraparound: -1 encodes as 2^64-1 and decodes back to -1
        assert.same(values, decoded)
      end)
    end

    it("encodes an empty signature to an empty body", function()
      assert.equals("", enc("", {}))
    end)
  end)

  describe("errors", function()
    it("rejects out-of-range values", function()
      assert.has_error(function() enc("y", { 256 }) end)
      assert.has_error(function() enc("q", { -1 }) end)
      assert.has_error(function() enc("u", { -1 }) end)
      assert.has_error(function() enc("n", { 32768 }) end)
    end)

    it("rejects non-integer values for integer types", function()
      assert.has_error(function() enc("u", { 1.5 }) end)
    end)

    it("rejects non-string for string types", function()
      assert.has_error(function() enc("s", { 42 }) end)
    end)

    it("rejects wrong table type for struct", function()
      assert.has_error(function() enc("(ii)", { "nope" }) end)
    end)

    it("round-trips unix fd inside a variant", function()
      local raw = enc("v", { types.variant("h", 0) })
      -- decode needs the fd table the 'h' index points into
      local values, err = marshal.decode_signature("v", raw, { 42 })
      assert.is_nil(err)
      assert.is_true(types.is_variant(values[1]))
      assert.equals("h", values[1].signature)
      assert.equals(42, values[1].value)
    end)

    it("decodes truncated data with an error", function()
      local values, err = marshal.decode_signature("us", { "\1\0\0\0\5\0" })
      assert.is_nil(values)
      assert.truthy(err)
    end)

    it("decodes invalid boolean with an error", function()
      local values, err = marshal.decode_signature("b", { "\2\0\0\0" })
      assert.is_nil(values)
      assert.truthy(err)
    end)
  end)
end)
