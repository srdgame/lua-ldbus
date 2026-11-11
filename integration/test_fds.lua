-- Integration: unix fd ('h') passing between two connections through
-- dbus-daemon (SCM_RIGHTS via lsocket sendfd/recvfd).
-- Run via integration/run.sh (inside dbus-run-session).
local Connection = require "ldbus.connection"
local lsocket = require "lsocket"

--- Plain-Lua helpers (no busted in integration scripts).
local function equals(a, b, what)
  assert(a == b, (what or "value") .. ": expected " .. tostring(b)
    .. ", got " .. tostring(a))
end

local server = assert(Connection.connect("session"))
local client = assert(Connection.connect("session"))
print("server:", server.unique_name, "client:", client.unique_name)

local base = ("/tmp/ldbus-fd-test-%d"):format(os.time())

--- Create a connected unix socket pair and queue `payload` in the
--- socket buffer. Returns the carrier socket and the fd of its
--- connecting side (reading from the fd yields the payload).
local function fd_with_payload(n, payload)
  local path = base .. "-" .. n .. ".sock"
  local srv = assert(lsocket.bind(path))
  local carrier = assert(lsocket.connect(path))
  local accepted = assert(srv:accept())
  assert(accepted:send(payload) > 0)
  srv:close()
  return carrier, carrier:getfd()
end

-- raw dispatch on the server: the router method-handler path does not
-- support returning fds, so replies with fds are sent manually here
local got_givefd, got_givefd_index
local carriers = {} -- write ends kept alive until script cleanup
server.on_message = function(msg)
  if msg.type == 1 and msg.member == "ReturnFd" then
    local carrier, fd = fd_with_payload(1, "hello-fd")
    carriers[#carriers + 1] = carrier
    assert(server:send({
      type = "method_return", reply_serial = msg.serial,
      destination = msg.sender, signature = "h", body = { 0 },
      fds = { fd },
    }))
  elseif msg.type == 1 and msg.member == "GiveFd" then
    -- body 'h' was resolved to the real fd through msg.fds
    got_givefd_index = msg.fds[1] == msg.body[1]
    local wrapped = lsocket.wrapfd(msg.body[1])
    got_givefd = wrapped:recv()
    wrapped:close()
    assert(server:send({
      type = "method_return", reply_serial = msg.serial,
      destination = msg.sender, signature = "", body = {},
    }))
  end
end

--- Send a call from the client and pump both sides until the reply.
local function call(member, opts)
  opts = opts or {}
  local serial = client:send({
    type = "method_call", destination = server.unique_name,
    path = "/com/example/Fd", interface = "com.example.Fd",
    member = member,
    signature = opts.signature or "",
    body = opts.body,
    fds = opts.fds,
  })
  local reply
  client.pending[serial] = function(msg) reply = msg end
  local deadline = os.clock() + 2
  while not reply and os.clock() < deadline do
    server:pump(0.05)
    client:pump(0.05)
  end
  assert(reply, "no reply for " .. member)
  if reply.type_name == "error" then
    error(member .. " -> " .. tostring(reply.error_name) .. ": "
      .. tostring(reply.body[1]))
  end
  return reply
end

-- 1) server -> client: reply carries one fd whose read end is returned
local reply = call("ReturnFd")
equals("method_return", reply.type_name, "ReturnFd reply type")
equals(1, reply.n_fds, "ReturnFd n_fds")
local fd = reply.body[1]
equals("number", type(fd), "fd decoded to integer")
local wrapped = lsocket.wrapfd(fd)
equals("hello-fd", wrapped:recv(), "payload read from received fd")
wrapped:close()
print("ReturnFd ok, fd", fd)

-- 2) client -> server: call body 'h' + opts.fds, server reads the fd
local carrier2, fd2 = fd_with_payload(2, "client-fd-data")
reply = call("GiveFd", { signature = "h", body = { 0 }, fds = { fd2 } })
equals("method_return", reply.type_name, "GiveFd reply type")
equals("client-fd-data", got_givefd, "payload read by server handler")
equals(true, got_givefd_index, "msg.fds[1] == resolved body index")
carrier2:close()
print("GiveFd ok")

server:close()
client:close()
for _, c in ipairs(carriers) do
  c:close()
end
os.remove(base .. "-1.sock")
os.remove(base .. "-2.sock")
print("test_fds PASSED")
