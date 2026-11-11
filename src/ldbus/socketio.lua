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

--- Send `data` together with one file descriptor via SCM_RIGHTS in a
--- single sendmsg (so the fd and the frame bytes arrive in order).
--- `false` (EAGAIN) queues no bytes and no control data, so retrying
--- is safe; a partial write means the fd was already queued with the
--- first segment and only the remainder goes out via plain send.
-- Returns true or nil + error message.
function socketio.send_with_fd(sock, data, fd)
  local nwr, err = sock:sendfd(fd, data)
  if nwr == nil then
    return nil, "send failed: " .. tostring(err)
  elseif nwr == false then
    local ready = lsocket.select(nil, { sock }, 10)
    if ready == nil then
      return nil, "send timed out"
    end
    nwr, err = sock:sendfd(fd, data)
    if nwr == nil then
      return nil, "send failed: " .. tostring(err)
    elseif nwr == false then
      return nil, "send timed out"
    end
  end
  if nwr < #data then
    return socketio.send_all(sock, data:sub(nwr + 1))
  end
  return true
end

--- One recvmsg; returns `chunk, fd` (fd is nil when none arrived with
--- this chunk), or false when no data is ready, or nil + error message
--- on socket error/closed. Works on any socket (fds are simply absent
--- from plain data).
function socketio.recvfd(sock)
  local fd, chunk, err = sock:recvfd()
  if fd == nil and chunk == nil then
    if err == nil then
      return nil, "connection closed"
    end
    return nil, "recv failed: " .. tostring(err)
  end
  if fd == false then
    return false
  end
  return chunk, fd
end

--- One recv (data only); returns a string chunk, or false when no data
--- is ready, or nil + error message on socket error. A concurrently
--- arriving fd is returned as the second value by recvfd; callers that
--- must not drop fds use recvfd directly.
function socketio.recv(sock)
  return (socketio.recvfd(sock))
end

--- Close if possible; tolerates already-closed sockets.
function socketio.close(sock)
  pcall(function() sock:close() end)
end

return socketio
