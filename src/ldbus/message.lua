--- D-Bus message framing: 16-byte fixed header + header fields + body.
-- Little-endian only (D-Bus allows big-endian; the bus itself uses
-- whatever the sender sent, and we only ever speak little-endian).
-- @module ldbus.message

local marshal = require "ldbus.marshal"
local types = require "ldbus.types"
local signature = require "ldbus.signature"

local message = {}

message.TYPE = {
  METHOD_CALL = 1,
  METHOD_RETURN = 2,
  ERROR = 3,
  SIGNAL = 4,
}

message.FLAG = {
  NO_REPLY_EXPECTED = 1,
  NO_AUTOSTART = 2,
}

message.FIELD = {
  PATH = 1,
  INTERFACE = 2,
  MEMBER = 3,
  ERROR_NAME = 4,
  REPLY_SERIAL = 5,
  DESTINATION = 6,
  SENDER = 7,
  SIGNATURE = 8,
  UNIX_FDS = 9,
}

local PROTOCOL_VERSION = 1
local ENDIANNESS = string.byte("l")
local FIXED_HEADER_LEN = 16
local FIELD_SIGNATURE = "a{yv}"

--- Human-readable message type names (also used for validation).
message.TYPE_NAME = {
  [message.TYPE.METHOD_CALL] = "method_call",
  [message.TYPE.METHOD_RETURN] = "method_return",
  [message.TYPE.ERROR] = "error",
  [message.TYPE.SIGNAL] = "signal",
}

local fields_nodes = assert(signature.parse(FIELD_SIGNATURE))
local field_entry_node = assert(signature.parse("(yv)"))[1]

--- Header field key -> (value, its signature).
local FIELD_VALUE_SIG = {
  [message.FIELD.PATH] = { "o" },
  [message.FIELD.INTERFACE] = { "s" },
  [message.FIELD.MEMBER] = { "s" },
  [message.FIELD.ERROR_NAME] = { "s" },
  [message.FIELD.REPLY_SERIAL] = { "u" },
  [message.FIELD.DESTINATION] = { "s" },
  [message.FIELD.SENDER] = { "s" },
  [message.FIELD.SIGNATURE] = { "g" },
  [message.FIELD.UNIX_FDS] = { "u" },
}

--- Byte length needed to read the total message size from a prefix.
-- Once 16 bytes of the fixed header are available, message.total_len
-- can compute the full frame size.
function message.fixed_header_len()
  return FIXED_HEADER_LEN
end

--- Total wire length of a message given its 16-byte fixed header.
-- Returns number, or nil + reason when the header is incomplete/invalid.
function message.total_len(header)
  if #header < FIXED_HEADER_LEN then
    return nil, "need " .. FIXED_HEADER_LEN .. " header bytes"
  end
  if header:byte(1) ~= ENDIANNESS then
    return nil, "only little-endian messages are supported"
  end
  local body_len = string.unpack("<I4", header, 5)
  local fields_len = string.unpack("<I4", header, 13)
  local body_start = types.pad_to(FIXED_HEADER_LEN + fields_len, 8)
  return body_start + body_len
end

--- Build a complete message.
-- opts:
--   type         "method_call"|"method_return"|"error"|"signal" (or number)
--   serial       required uint32
--   path         object path (method_call/signal)
--   interface, member, error_name, destination, sender
--   reply_serial uint32
--   signature    body signature string ("" or nil for no body)
--   body         list of values matching signature
--   flags        number (message.FLAG bits)
--   fds          list of unix fds to attach (SCM_RIGHTS); must match
--                the number of 'h' values in the signature (max 1)
-- Returns the full wire bytes.
function message.build(opts)
  local mtype = opts.type
  if type(mtype) == "string" then
    mtype = message.TYPE[string.upper(mtype)]
  end
  if type(mtype) ~= "number" or not message.TYPE_NAME[mtype] then
    error("invalid message type: " .. tostring(opts.type), 2)
  end
  if not (opts.serial and opts.serial > 0) then
    error("message serial required (nonzero)", 2)
  end

  -- encode body first (its length goes in the fixed header)
  local body = ""
  if opts.signature and #opts.signature > 0 then
    if not opts.body then
      error("body signature '" .. opts.signature .. "' given without body values", 2)
    end
    body = marshal.encode_signature(opts.signature, opts.body)
  end

  -- validate fds against the signature's 'h' count
  local fds = opts.fds or {}
  local n_fds_wanted = marshal.count_fds(opts.signature or "")
  if #fds ~= n_fds_wanted then
    error(string.format(
      "signature '%s' encodes %d fd(s) but %d were given"
        .. " (body fd indices are filled in automatically)",
      tostring(opts.signature or ""), n_fds_wanted, #fds), 2)
  end
  if #fds > 1 then
    error("at most one fd per message (lsocket SCM_RIGHTS limit)", 2)
  end

  -- collect header fields
  local fields = {}
  local function set_field(key, value)
    fields[key] = types.variant(FIELD_VALUE_SIG[key][1], value)
  end
  if opts.path then
    set_field(message.FIELD.PATH, opts.path)
  end
  if opts.interface then
    set_field(message.FIELD.INTERFACE, opts.interface)
  end
  if opts.member then
    set_field(message.FIELD.MEMBER, opts.member)
  end
  if opts.error_name then
    set_field(message.FIELD.ERROR_NAME, opts.error_name)
  end
  if opts.reply_serial then
    set_field(message.FIELD.REPLY_SERIAL, opts.reply_serial)
  end
  if opts.destination then
    set_field(message.FIELD.DESTINATION, opts.destination)
  end
  if opts.sender then
    set_field(message.FIELD.SENDER, opts.sender)
  end
  if opts.signature and #opts.signature > 0 then
    set_field(message.FIELD.SIGNATURE, opts.signature)
  end
  if #fds > 0 then
    set_field(message.FIELD.UNIX_FDS, #fds)
  end

  -- Header field entries are placed at wire offset 16, back to back.
  -- The array length lives ONLY in fixed header bytes 12-15: the fields
  -- data itself contains NO length prefix (per the D-Bus spec, the
  -- header fields array is special-cased this way).
  local entry_nodes, entry_values = {}, {}
  local keys = {}
  for key in pairs(fields) do
    keys[#keys + 1] = key
  end
  table.sort(keys) -- deterministic field order
  for _, key in ipairs(keys) do
    entry_nodes[#entry_nodes + 1] = field_entry_node
    entry_values[#entry_values + 1] = { key, fields[key] }
  end
  local fields_data = marshal.encode(entry_nodes, entry_values, FIXED_HEADER_LEN)
  local fields_len = #fields_data
  local pad = types.padding_needed(FIXED_HEADER_LEN + fields_len, 8)

  -- 16-byte fixed header: endianness, type, flags, version,
  -- body length, serial, header-fields array length
  local fixed = string.pack("<BBBB I4 I4 I4",
    ENDIANNESS, mtype, opts.flags or 0, PROTOCOL_VERSION,
    #body, opts.serial, fields_len)

  return fixed .. fields_data .. string.rep("\0", pad) .. body
end

--- Decode the header-fields array of a complete message into
-- `{ [field_key] = variant_value }`. Returns the table or nil + error.
local function parse_fields(data, fields_len)
  -- The fields region holds raw (yv) entries starting at offset 16, with
  -- no array length prefix (see build). Reconstruct the standard a(yv)
  -- framing (length + mandatory pad before the first entry) so the normal
  -- decoder can walk it; offsets stay 8-aligned either way. The length
  -- excludes the padding, per spec.
  local fields_raw = string.pack("<I4", fields_len) .. "\0\0\0\0"
    .. data:sub(FIXED_HEADER_LEN + 1, FIXED_HEADER_LEN + fields_len)
  local entries, fields_err = marshal.decode_signature(FIELD_SIGNATURE, fields_raw)
  if not entries then
    return nil, "invalid header fields: " .. tostring(fields_err)
  end
  return entries[1] or {}
end

--- Number of unix fds the message carries (0 when the UNIX_FDS field
-- is absent). Reads only the fixed header and header fields; the body
-- is not decoded, so this is safe to call on a partially delivered
-- frame whose body references not-yet-received fds.
function message.fd_count(data)
  if #data < FIXED_HEADER_LEN then
    return 0
  end
  local _, _, fields_len = string.unpack("<I4I4I4", data, 5)
  if #data < FIXED_HEADER_LEN + fields_len then
    return 0
  end
  local fields = parse_fields(data, fields_len)
  local v = fields[message.FIELD.UNIX_FDS]
  if types.is_variant(v) then
    return v.value
  end
  return v or 0
end

--- Parse a complete message.
-- `fds` is the message's fd array (SCM_RIGHTS); body 'h' values are
-- resolved to real fds through it. Returns a message table:
--   { type, type_name, flags, serial, reply_serial, path, interface,
--     member, error_name, destination, sender, signature, body,
--     body_len, n_fds, fds }
-- or nil + error message.
function message.parse(data, fds)
  if #data < FIXED_HEADER_LEN then
    return nil, "message too short"
  end
  if data:byte(1) ~= ENDIANNESS then
    return nil, "only little-endian messages are supported"
  end
  local mtype = data:byte(2)
  local flags = data:byte(3)
  local version = data:byte(4)
  if version ~= PROTOCOL_VERSION then
    return nil, "unsupported protocol version " .. version
  end
  local body_len, serial, fields_len = string.unpack("<I4I4I4", data, 5)
  if #data < FIXED_HEADER_LEN + fields_len + body_len then
    return nil, "message data truncated"
  end

  local fields, fields_err = parse_fields(data, fields_len)
  if not fields then
    return nil, fields_err
  end

  -- header field values are variants; unwrap them
  local function field(key)
    local v = fields[key]
    if types.is_variant(v) then
      return v.value
    end
    return v
  end

  local body_start = types.pad_to(FIXED_HEADER_LEN + fields_len, 8)
  local n_fds = field(message.FIELD.UNIX_FDS) or 0
  local msg = {
    type = mtype,
    type_name = message.TYPE_NAME[mtype],
    flags = flags,
    serial = serial,
    body_len = body_len,
    reply_serial = field(message.FIELD.REPLY_SERIAL),
    path = field(message.FIELD.PATH),
    interface = field(message.FIELD.INTERFACE),
    member = field(message.FIELD.MEMBER),
    error_name = field(message.FIELD.ERROR_NAME),
    destination = field(message.FIELD.DESTINATION),
    sender = field(message.FIELD.SENDER),
    signature = field(message.FIELD.SIGNATURE) or "",
    n_fds = n_fds,
    fds = fds,
  }

  if msg.type == message.TYPE.METHOD_CALL and not msg.path then
    return nil, "method call without PATH header field"
  end

  if body_len > 0 then
    if not msg.signature or #msg.signature == 0 then
      return nil, "message body present without SIGNATURE field"
    end
    local body_raw = data:sub(body_start + 1, body_start + body_len)
    local values, err = marshal.decode_signature(msg.signature, body_raw, fds)
    if not values then
      return nil, "invalid message body: " .. err
    end
    msg.body = values
  else
    msg.body = {}
  end

  return msg
end

return message
