--- D-Bus wire format encoder/decoder (little-endian).
-- Uses Lua 5.4 native integers (64-bit) and string.pack/unpack.
-- Alignment is handled with an explicit running position counter;
-- arrays encode their elements into a sub-buffer so that the
-- element offsets match their final absolute offsets exactly.
-- @module ldbus.marshal

local types = require "ldbus.types"
local signature = require "ldbus.signature"

local marshal = {}

local function check_int(v, code)
  if math.type(v) ~= "integer" then
    if type(v) == "number" and v % 1 == 0 and math.tointeger(v) then
      v = math.tointeger(v)
    else
      error("expected integer for type '" .. code .. "', got " .. tostring(v), 3)
    end
  end
  return v
end

local function check_range(v, lo, hi, code)
  if v < lo or v > hi then
    error(string.format("value %s out of range for type '%s'", tostring(v), code), 3)
  end
  return v
end

local function align_buf(pos, alignment)
  return string.rep("\0", types.padding_needed(pos, alignment))
end

--------------------------------------------------------------------------------
-- Encoder
--------------------------------------------------------------------------------

local middleclass = require "ldbus.class"

local Encoder = middleclass("Encoder")

--- `start_pos` is the absolute wire offset this buffer begins at, so
-- sub-buffers (array bodies) keep correct relative alignment.
function Encoder:initialize(start_pos)
  self.chunks = {}
  self.pos = start_pos or 0
end

function Encoder:write(s)
  self.chunks[#self.chunks + 1] = s
  self.pos = self.pos + #s
end

function Encoder:align(alignment)
  local pad = types.padding_needed(self.pos, alignment)
  if pad > 0 then
    self:write(string.rep("\0", pad))
  end
end

function Encoder:pack(fmt, v)
  self:write(string.pack(fmt, v))
end

function Encoder:result()
  return table.concat(self.chunks)
end

--- Encode a single value according to `node` into `enc`.
-- encode_array / encode_dict are declared after but referenced at
-- call time, so forward declaration is enough.
local encode_array, encode_dict

local function encode_node(node, value, enc)
  local code = node.code

  if code == "y" then
    enc:pack("<I1", check_range(check_int(value, code), 0, 255, code))
  elseif code == "b" then
    enc:align(4)
    enc:pack("<I4", value and 1 or 0)
  elseif code == "n" then
    enc:align(2)
    enc:pack("<i2", check_range(check_int(value, code), -32768, 32767, code))
  elseif code == "q" then
    enc:align(2)
    enc:pack("<I2", check_range(check_int(value, code), 0, 65535, code))
  elseif code == "i" then
    enc:align(4)
    enc:pack("<i4", check_range(check_int(value, code), -2147483648, 2147483647, code))
  elseif code == "u" then
    enc:align(4)
    enc:pack("<I4", check_range(check_int(value, code), 0, 4294967295, code))
  elseif code == "x" then
    enc:align(8)
    enc:pack("<i8", check_int(value, code))
  elseif code == "t" then
    -- uint64: Lua 5.4 integers are signed 64-bit; values >= 2^63 must
    -- be passed as their wrapped negative form and decode back negative.
    -- e.g. pass math.mininteger to encode 2^63.
    enc:align(8)
    enc:pack("<I8", check_int(value, code))
  elseif code == "d" then
    if type(value) ~= "number" then
      error("expected number for type 'd', got " .. type(value), 3)
    end
    enc:align(8)
    enc:pack("<d", value)
  elseif code == "s" or code == "o" then
    if type(value) ~= "string" then
      error("expected string for type '" .. code .. "', got " .. type(value), 3)
    end
    if #value > 2147483647 then
      error("string too long for type '" .. code .. "'", 3)
    end
    enc:align(4)
    enc:pack("<I4", #value)
    enc:write(value)
    enc:write("\0")
  elseif code == "g" then
    if type(value) ~= "string" then
      error("expected string for type 'g', got " .. type(value), 3)
    end
    if #value > 255 then
      error("signature string too long (max 255)", 3)
    end
    enc:pack("<I1", #value)
    enc:write(value)
    enc:write("\0") -- signatures are NUL-terminated on the wire
  elseif code == "v" then
    if not types.is_variant(value) then
      error("variant value must be created with ldbus.variant(sig, value)", 3)
    end
    local inner_sig = value.signature
    if inner_sig == "h" then
      error("unix fd type 'h' is not supported by ldbus", 3)
    end
    local inner_nodes = signature.parse(inner_sig)
    if not inner_nodes then
      error("invalid variant signature: " .. tostring(inner_sig), 3)
    end
    encode_node({ code = "g" }, inner_sig, enc)
    encode_node(inner_nodes[1], value.value, enc)
  elseif code == "a" then
    if type(value) ~= "table" then
      error("expected table for array type, got " .. type(value), 3)
    end
    if node.elem.code == "e" then
      encode_dict(node, value, enc)
    else
      encode_array(node, value, enc)
    end
  elseif code == "r" then
    if type(value) ~= "table" then
      error("expected table (array) for struct, got " .. type(value), 3)
    end
    if #value ~= #node.fields then
      error(string.format(
        "struct field count mismatch: signature wants %d, value has %d",
        #node.fields, #value), 3)
    end
    enc:align(8)
    for i, field in ipairs(node.fields) do
      encode_node(field, value[i], enc)
    end
  else
    error("cannot encode type code '" .. tostring(code) .. "'", 3)
  end
end

--- Encode a plain array (element type is not a dict entry).
encode_array = function(node, value, enc)
  enc:align(4)
  -- Elements are encoded into a sub-buffer positioned *after* the
  -- length prefix so that element alignments match absolute offsets.
  local sub = Encoder(enc.pos + 4)
  local elem_align = types.alignment_of(signature.node_to_string(node.elem))
  -- The alignment padding before the first element is mandatory even
  -- for empty arrays and is NOT counted in the length prefix.
  local lead = types.padding_needed(enc.pos + 4, elem_align)
  sub:write(string.rep("\0", lead))
  for i = 1, #value do
    sub:align(elem_align)
    encode_node(node.elem, value[i], sub)
  end
  local body = sub:result()
  if #body - lead > 2147483647 then
    error("array body too large", 3)
  end
  enc:pack("<I4", #body - lead)
  enc:write(body)
end

--- Encode a Lua table as an array of dict entries ("a{...}").
-- Keys are sorted for deterministic output.
encode_dict = function(node, value, enc)
  local entry = node.elem
  local keys = {}
  for k in pairs(value) do
    keys[#keys + 1] = k
  end
  if types.ALIGNMENT[entry.key.code] and entry.key.code ~= "s"
      and entry.key.code ~= "o" then
    table.sort(keys, function(a, b) return a < b end)
  else
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  end
  enc:align(4)
  local sub = Encoder(enc.pos + 4)
  local entry_align = 8
  -- Leading padding before the first entry is required even for empty
  -- dicts and is NOT counted in the length prefix.
  local lead = types.padding_needed(enc.pos + 4, entry_align)
  sub:write(string.rep("\0", lead))
  for _, k in ipairs(keys) do
    sub:align(entry_align)
    encode_node(entry.key, k, sub)
    encode_node(entry.value, value[k], sub)
  end
  local body = sub:result()
  enc:pack("<I4", #body - lead)
  enc:write(body)
end

--- Encode a list of values against a list of signature nodes.
-- `start_pos` is the wire offset the buffer will be placed at (needed
-- for header fields, which start at offset 16 in a message).
-- Returns the encoded body string.
function marshal.encode(nodes, values, start_pos)
  local enc = Encoder(start_pos or 0)
  for i, node in ipairs(nodes) do
    encode_node(node, values[i], enc)
  end
  return enc:result()
end

--------------------------------------------------------------------------------
-- Decoder
--------------------------------------------------------------------------------

local Decoder = middleclass("Decoder")

function Decoder:initialize(data)
  self.data = data
  self.pos = 1 -- Lua 1-based
end

function Decoder:align(alignment)
  -- self.pos is 1-based (Lua string index); wire offsets are 0-based
  self.pos = types.pad_to(self.pos - 1, alignment) + 1
end

function Decoder:unpack(fmt)
  local v, next_pos = string.unpack(fmt, self.data, self.pos)
  self.pos = next_pos
  return v
end

function Decoder:read(n)
  if self.pos + n - 1 > #self.data then
    error("premature end of data while decoding", 3)
  end
  local s = self.data:sub(self.pos, self.pos + n - 1)
  self.pos = self.pos + n
  return s
end

local function decode_node(node, dec)
  local code = node.code

  if code == "y" then
    return dec:unpack("<I1")
  elseif code == "b" then
    dec:align(4)
    local n = dec:unpack("<I4")
    if n ~= 0 and n ~= 1 then
      error("invalid boolean value " .. n)
    end
    return n == 1
  elseif code == "n" then
    dec:align(2)
    return dec:unpack("<i2")
  elseif code == "q" then
    dec:align(2)
    return dec:unpack("<I2")
  elseif code == "i" then
    dec:align(4)
    return dec:unpack("<i4")
  elseif code == "u" then
    dec:align(4)
    return dec:unpack("<I4")
  elseif code == "x" then
    dec:align(8)
    return dec:unpack("<i8")
  elseif code == "t" then
    dec:align(8)
    return dec:unpack("<I8")
  elseif code == "d" then
    dec:align(8)
    return dec:unpack("<d")
  elseif code == "s" or code == "o" then
    dec:align(4)
    local len = dec:unpack("<I4")
    local s = dec:read(len)
    dec:read(1) -- trailing NUL
    return s
  elseif code == "g" then
    local len = dec:unpack("<I1")
    local s = dec:read(len)
    dec:read(1) -- trailing NUL
    return s
  elseif code == "v" then
    local inner_sig = decode_node({ code = "g" }, dec)
    local inner_nodes = signature.parse(inner_sig)
    if not inner_nodes then
      error("invalid variant signature in data: " .. tostring(inner_sig))
    end
    local value = decode_node(inner_nodes[1], dec)
    return types.variant(inner_sig, value)
  elseif code == "a" then
    dec:align(4)
    local body_len = dec:unpack("<I4")
    local elem_align = types.alignment_of(signature.node_to_string(node.elem))
    -- The length does NOT include the mandatory alignment padding
    -- before the first element; skip it now and include it in the bound.
    dec:align(elem_align)
    if dec.pos + body_len - 1 > #dec.data then
      error("array body length exceeds available data")
    end
    local result = {}
    local end_pos = dec.pos + body_len
    if node.elem.code == "e" then
      while dec.pos < end_pos do
        dec:align(elem_align)
        local k = decode_node(node.elem.key, dec)
        local v = decode_node(node.elem.value, dec)
        result[k] = v
      end
    else
      local i = 0
      while dec.pos < end_pos do
        dec:align(elem_align)
        i = i + 1
        result[i] = decode_node(node.elem, dec)
      end
    end
    if dec.pos ~= end_pos then
      error("array body length mismatch")
    end
    return result
  elseif code == "r" then
    dec:align(8)
    local result = {}
    for i, field in ipairs(node.fields) do
      result[i] = decode_node(field, dec)
    end
    return result
  else
    error("cannot decode type code '" .. tostring(code) .. "'")
  end
end

--- Decode `data` (a body string) against a list of signature nodes.
-- Returns `values` (a list) or `nil, err`.
function marshal.decode(nodes, data)
  local dec = Decoder(data)
  local values = {}
  for i, node in ipairs(nodes) do
    local ok, v = pcall(decode_node, node, dec)
    if not ok then
      return nil, tostring(v)
    end
    values[i] = v
  end
  return values
end

--- Parse a signature and encode values in one step.
-- Raises on invalid signature or value mismatch.
function marshal.encode_signature(sig, values)
  local nodes, err = signature.parse(sig)
  if not nodes then
    error(err, 2)
  end
  return marshal.encode(nodes, values)
end

--- Parse a signature and decode data in one step.
-- Returns `values` or `nil, err`.
function marshal.decode_signature(sig, data)
  local nodes, err = signature.parse(sig)
  if not nodes then
    return nil, err
  end
  return marshal.decode(nodes, data)
end

return marshal
