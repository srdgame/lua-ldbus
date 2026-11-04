--- Thin wrapper around lsocket for D-Bus connections.
-- Handles the lsocket non-blocking connect dance ("select writable,
-- then status() to confirm"), all-or-nothing sends, and the
-- almost-nonblocking recv contract (false means "would block").
-- @module ldbus.socketio

local lsocket = require "lsocket"

local socketio = {}

--- lsocket wants "\0name" for abstract unix sockets; D-Bus addresses
--- use "@name". Pass through plain paths unchanged.
function socketio.unix_path(path)
  if path:sub(1, 1) == "@" then
    return "\0" .. path:sub(2)
  end
  return path
end

--- Connect per a parsed address table (see ldbus.address.parse).
-- Returns a connected lsocket socket or nil + error message.
function socketio.connect(addr)
  local sock
  if addr.transport == "unix" then
    if addr.path then
      sock = lsocket.connect(socketio.unix_path(addr.path))
    elseif addr.abstract then
      sock = lsocket.connect(socketio.unix_path("@" .. addr.abstract))
    else
      return nil, "unix address needs path or abstract"
    end
  elseif addr.transport == "tcp" then
    sock = lsocket.connect(addr.host, tonumber(addr.port))
  else
    return nil, "unsupported transport: " .. tostring(addr.transport)
  end
  if not sock then
    return nil, "connect failed: " .. tostring(addr.transport)
  end

  -- finish the (possibly asynchronous) connect
  while true do
    local st, err = sock:status()
    if st == true then
      return sock
    elseif st == nil then
      return nil, "connect failed: " .. tostring(err)
    end
    -- st == false: still connecting, wait for writability
    local ready = lsocket.select(nil, { sock }, 10)
    if ready == nil then
      return nil, "connect timed out"
    end
  end
end

--- Send all of `data`, looping until complete (false from send means
--- "would block"; select for writability and retry).
-- Returns true or nil + error message.
function socketio.send_all(sock, data)
  local sent = 0
  while sent < #data do
    local n, err = sock:send(data:sub(sent + 1))
    if n == nil then
      return nil, "send failed: " .. tostring(err)
    elseif n == false then
      local ready = lsocket.select(nil, { sock }, 10)
      if ready == nil then
        return nil, "send timed out"
      end
    else
      sent = sent + n
    end
  end
  return true
end

--- One recv; returns a string chunk, or false when no data is ready,
--- or nil + error message on socket error.
function socketio.recv(sock)
  local chunk, err = sock:recv()
  if chunk == nil then
    if err == "closed" then
      return nil, "connection closed"
    end
    return nil, "recv failed: " .. tostring(err)
  end
  return chunk -- may be false (would block) or a string
end

--- Close if possible; tolerates already-closed sockets.
function socketio.close(sock)
  pcall(function() sock:close() end)
end

return socketio
