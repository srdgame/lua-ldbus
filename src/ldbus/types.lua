--- D-Bus type system: type codes, alignment rules, Variant constructor.
-- @module ldbus.types

local types = {}

--- Single-character D-Bus type codes.
types.CODES = {
  BYTE = "y",
  BOOLEAN = "b",
  INT16 = "n",
  UINT16 = "q",
  INT32 = "i",
  UINT32 = "u",
  INT64 = "x",
  UINT64 = "t",
  DOUBLE = "d",
  STRING = "s",
  OBJECT_PATH = "o",
  SIGNATURE = "g",
  ARRAY = "a",
  STRUCT = "r",       -- only valid inside signatures
  DICT_ENTRY = "e",   -- only valid inside signatures
  VARIANT = "v",
  UNIX_FD = "h",      -- NOT supported by ldbus
}

--- Required byte alignment for each type code.
types.ALIGNMENT = {
  y = 1,
  b = 4,
  n = 2,
  q = 2,
  i = 4,
  u = 4,
  x = 8,
  t = 8,
  d = 8,
  s = 4,
  o = 4,
  g = 1,
  a = 4,
  v = 1,
  h = 4,
}

--- Alignment of a complete type as it appears in a signature
-- (structs and dict entries are always 8-aligned).
-- `sig` may be a single type code or a full signature string
-- (for arrays this is the length-prefix alignment, 4; the element
-- type's own alignment is applied separately by marshal).
function types.alignment_of(sig)
  local first = sig:sub(1, 1)
  if first == "(" or first == "{" then
    return 8
  end
  -- for arrays this is the alignment of the length prefix (4);
  -- elements inside are aligned separately by marshal
  return types.ALIGNMENT[first]
end

--- Pad `n` up to the next multiple of `alignment`.
function types.pad_to(n, alignment)
  local rem = n % alignment
  if rem == 0 then
    return n
  end
  return n + (alignment - rem)
end

--- Number of padding bytes needed to align `n` to `alignment`.
function types.padding_needed(n, alignment)
  return types.pad_to(n, alignment) - n
end

--- True if `sig` is a valid complete (single, complete) type signature,
-- e.g. "i", "s", "as", "(ii)", "a{sv}", "v".
function types.is_complete_type(sig)
  local ok = types.split_complete_type(sig)
  return ok
end

--- Maximum type nesting depth per the D-Bus spec (arrays, structs and
-- dict entries each count one level).
types.MAX_DEPTH = 32

--- Split the first complete type off a signature string.
-- Returns `true, complete_type, rest` on success,
-- `false, err_message` on failure.
-- `depth` is internal (container nesting so far).
function types.split_complete_type(sig, depth)
  depth = depth or 0
  if depth > types.MAX_DEPTH then
    return false, "type nesting too deep (max " .. types.MAX_DEPTH .. ")"
  end
  if #sig == 0 then
    return false, "empty signature"
  end
  local c = sig:sub(1, 1)
  if c == "a" then
    local ok, elem, rest = types.split_complete_type(sig:sub(2), depth + 1)
    if not ok then
      return false, "array missing element type: " .. sig
    end
    return true, sig:sub(1, 1 + #elem), rest
  elseif c == "(" then
    local rest = sig:sub(2)
    local fields = {}
    while true do
      if #rest == 0 then
        return false, "unterminated struct: " .. sig
      end
      if rest:sub(1, 1) == ")" then
        if #fields == 0 then
          return false, "empty struct: " .. sig
        end
        return true, sig:sub(1, #sig - #rest + 1), rest:sub(2)
      end
      local ok, field, rest2 = types.split_complete_type(rest, depth + 1)
      if not ok then
        return false, field
      end
      fields[#fields + 1] = field
      rest = rest2
    end
  elseif c == "{" then
    local ok, key, rest = types.split_complete_type(sig:sub(2), depth + 1)
    if not ok then
      return false, "dict entry missing key type: " .. sig
    end
    local ok2, val, rest2 = types.split_complete_type(rest, depth + 1)
    if not ok2 then
      return false, "dict entry missing value type: " .. sig
    end
    if rest2:sub(1, 1) ~= "}" then
      return false, "unterminated dict entry: " .. sig
    end
    -- keys must be basic types: single codes except containers and
    -- variants (the spec explicitly forbids 'v' as a key)
    if #key ~= 1 or not types.ALIGNMENT[key] or key == "a" or key == "v" then
      return false, "dict key must be a basic (non-container) type: " .. key
    end
    return true, sig:sub(1, #sig - #rest2 + 1), rest2:sub(2)
  elseif types.ALIGNMENT[c] then
    return true, c, sig:sub(2)
  else
    return false, "unknown type code: " .. c
  end
end

--- Validate a full signature (zero or more complete types).
-- Returns `true, n_types` or `false, err_message`.
-- Per spec: max 255 bytes total; dict entries are only valid as
-- elements of an array, never at the top level.
function types.validate_signature(sig)
  if #sig > 255 then
    return false, "signature too long (max 255 bytes)"
  end
  local n = 0
  local rest = sig
  while #rest > 0 do
    local ok, complete, rest2 = types.split_complete_type(rest)
    if not ok then
      return false, rest2
    end
    if complete:sub(1, 1) == "{" then
      return false, "dict entry only valid inside an array: " .. complete
    end
    n = n + 1
    rest = rest2
  end
  return true, n
end

--- Table for tagging values that carry an explicit D-Bus signature.
-- `dbus.variant(sig, value)` produces `{ _dbus_variant = true, signature = sig, value = value }`.
-- `sig` must be exactly ONE complete type (a variant cannot hold a
-- multi-type body).
function types.variant(signature, value)
  local ok, _, rest = types.split_complete_type(signature)
  if not ok then
    error("invalid variant signature '" .. tostring(signature) .. "'", 2)
  end
  if #rest > 0 then
    error("variant signature must be exactly one complete type: '"
      .. tostring(signature) .. "'", 2)
  end
  if signature == "h" then
    error("unix fd type 'h' is not supported by ldbus", 2)
  end
  return { _dbus_variant = true, signature = signature, value = value }
end

--- Test whether a value is a tagged Variant produced by `types.variant`.
function types.is_variant(v)
  return type(v) == "table" and v._dbus_variant == true
end

return types
