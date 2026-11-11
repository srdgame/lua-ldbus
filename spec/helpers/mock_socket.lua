--- Scripted mock socket for auth/buffer tests.
-- The mock replays canned replies and records everything sent.
-- Usage:
--   local mock = require "helpers.mock_socket"
--   local io_obj = mock({ replies = { "OK 1234\r\n" } })
--   io_obj:send("\0")            -- recorded in io_obj.written
--   io_obj:read_line()           -- pops from replies (feed Buffer)
--
-- It also exposes a `pending` buffer so tests can push more data
-- between calls: io_obj:feed("chunk").
local middleclass = require "ldbus.class"

local mock = middleclass("MockIo")

function mock:initialize(opts)
  opts = opts or {}
  local Buffer = require "ldbus.buffer"
  self.buf = Buffer()
  self.replies = opts.replies or {}
  self.fds = opts.fds or {}
  self.written = {}
  self.sent_fds = {}
  self.closed = false
end

--- Queue extra data to be returned by subsequent reads.
function mock:feed(s)
  self.buf:feed(s)
end

function mock:send(s)
  self.written[#self.written + 1] = s
  return true
end

function mock:read_line()
  while true do
    local line = self.buf:read_line()
    if line then
      return line
    end
    local next_reply = table.remove(self.replies, 1)
    if not next_reply then
      return nil
    end
    self.buf:feed(next_reply)
  end
end

--- Queue an fd to be delivered by the next recv() (SCM_RIGHTS).
function mock:feed_fd(fd)
  self.fds[#self.fds + 1] = fd
end

--- Simulate a recv-driven socket: return next chunk from replies
-- (each entry is one recv chunk) paired with the next queued fd
-- (if any), false when nothing is ready.
function mock:recv()
  local chunk = table.remove(self.replies, 1)
  local fd = table.remove(self.fds, 1)
  if chunk == nil and fd ~= nil then
    chunk = "" -- an fd always travels with at least one data byte
  end
  if chunk then
    return chunk, fd
  end
  return false
end

--- Send with fds (SCM_RIGHTS); records fds for assertions.
function mock:send_with_fds(bytes, fds)
  self.written[#self.written + 1] = bytes
  for _, fd in ipairs(fds or {}) do
    self.sent_fds[#self.sent_fds + 1] = fd
  end
  return true
end

function mock:wait_readable(timeout)
  -- only queued replies/fds count: buffered data lives in the
  -- consumer's own buffer, not ours
  return self.replies[1] ~= nil or self.fds[1] ~= nil
end

function mock:close()
  self.closed = true
end

function mock:sent()
  return table.concat(self.written)
end

return mock
