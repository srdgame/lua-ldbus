--- D-Bus SASL handshake (EXTERNAL mechanism only).
-- Flow: send \0, then "AUTH EXTERNAL <hex(uid)>" and expect "OK <guid>",
-- then send "BEGIN". REJECTED is an error (ldbus only speaks EXTERNAL).
-- @module ldbus.auth

local auth = {}

--- Run the handshake over `io`, an object with:
--   io:send(string)             -- raw write
--   io:read_line() -> string|nil -- "\r\n"-terminated line or nil on EOF
-- `identity` is the hex-encoded uid (see ldbus.uid.external_identity).
-- Returns the server GUID on success, or nil + error message.
function auth.negotiate(io, identity)
  io:send("\0")
  io:send("AUTH EXTERNAL " .. identity .. "\r\n")

  local line = io:read_line()
  if not line then
    return nil, "connection closed during auth"
  end
  line = line:gsub("\r\n$", "")

  local ok_cmd, guid = line:match("^(OK)%s+(%x+)$")
  if ok_cmd then
    io:send("BEGIN\r\n")
    return guid
  end

  if line:match("^REJECTED") then
    return nil, "auth rejected by server (ldbus only supports EXTERNAL): " .. line
  end

  if line:match("^ERROR") or line:match("^DATA") then
    -- give up after the first unexpected response
    return nil, "unexpected auth response: " .. line
  end

  return nil, "unexpected auth response: " .. line
end

--- Convenience: negotiate using an already-open socket-style object
-- with `send` and a Buffer for reads, via `recv_more` to pull chunks.
-- Not used by tests; connection.lua wires this up itself.
return auth
