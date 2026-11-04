--- Signature parsing: signature string -> node tree used by marshal.
-- Node format:
--   basic:      { code = "y" | "b" | "n" | ... }
--   array:      { code = "a", elem = node }
--   struct:     { code = "r", fields = { node, ... } }
--   dict entry: { code = "e", key = node, value = node }
-- The unix fd type 'h' parses but is rejected when used in
-- marshal/unmarshal (see marshal.lua), and rejected outright by
-- signature.parse for method signatures (see error policy below).
-- @module ldbus.signature

local types = require "ldbus.types"

local signature = {}

--- Parse one complete type from the head of `sig`.
-- Returns `node, rest` or `nil, err`.
local function parse_one(sig)
  local c = sig:sub(1, 1)
  if c == "a" then
    local elem, rest = parse_one(sig:sub(2))
    if not elem then
      return nil, rest
    end
    return { code = "a", elem = elem }, rest
  elseif c == "(" then
    local fields = {}
    local rest = sig:sub(2)
    while true do
      if #rest == 0 then
        return nil, "unterminated struct: " .. sig
      end
      if rest:sub(1, 1) == ")" then
        if #fields == 0 then
          return nil, "empty struct: " .. sig
        end
        return { code = "r", fields = fields }, rest:sub(2)
      end
      local field, rest2 = parse_one(rest)
      if not field then
        return nil, rest2
      end
      fields[#fields + 1] = field
      rest = rest2
    end
  elseif c == "{" then
    local key, rest = parse_one(sig:sub(2))
    if not key then
      return nil, rest
    end
    if not types.ALIGNMENT[key.code] or key.code == "a" then
      return nil, "dict key must be a basic type: " .. key.code
    end
    local value, rest2 = parse_one(rest)
    if not value then
      return nil, rest2
    end
    if rest2:sub(1, 1) ~= "}" then
      return nil, "unterminated dict entry: " .. sig
    end
    return { code = "e", key = key, value = value }, rest2:sub(2)
  elseif types.ALIGNMENT[c] then
    return { code = c }, sig:sub(2)
  else
    return nil, "unknown type code: " .. tostring(c)
  end
end

--- True if the node tree contains a unix fd ('h') anywhere.
local function contains_fd(node)
  if node.code == "h" then
    return true
  elseif node.code == "a" then
    return contains_fd(node.elem)
  elseif node.code == "r" then
    for _, f in ipairs(node.fields) do
      if contains_fd(f) then
        return true
      end
    end
    return false
  elseif node.code == "e" then
    return contains_fd(node.key) or contains_fd(node.value)
  end
  return false
end

--- Parse a full signature into a list of nodes.
-- Returns `nodes, err` where `nodes` is `{ node, ... }` (possibly empty).
-- Unix fd ('h') is rejected at parse time with a descriptive error.
function signature.parse(sig)
  local nodes = {}
  local rest = sig
  while #rest > 0 do
    local node, rest2 = parse_one(rest)
    if not node then
      return nil, "invalid signature '" .. sig .. "': " .. tostring(rest2)
    end
    if contains_fd(node) then
      return nil, "unix fd type 'h' is not supported by ldbus: " .. sig
    end
    nodes[#nodes + 1] = node
    rest = rest2
  end
  if #sig > 255 then
    return nil, "signature too long (max 255): " .. sig
  end
  return nodes
end

--- String form of a node tree (round-trips back to a signature).
function signature.node_to_string(node)
  local c = node.code
  if c == "a" then
    return "a" .. signature.node_to_string(node.elem)
  elseif c == "r" then
    local parts = {}
    for _, f in ipairs(node.fields) do
      parts[#parts + 1] = signature.node_to_string(f)
    end
    return "(" .. table.concat(parts) .. ")"
  elseif c == "e" then
    return "{" .. signature.node_to_string(node.key) .. signature.node_to_string(node.value) .. "}"
  end
  return c
end

return signature
