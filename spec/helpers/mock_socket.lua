--- Scripted mock socket for auth/buffer tests.
-- The mock replays canned replies and records everything sent.
-- Usage:
--   local mock = require "helpers.mock_socket"
--   local io_obj = mock.new({ replies = { "OK 1234\r\n" } })
--   io_obj:send("\0")            -- recorded in io_obj.written
--   io_obj:read_line()           -- pops from replies (feed Buffer)
--
-- It also exposes a `pending` buffer so tests can push more data
-- between calls: io_obj:feed("chunk").
local mock = {}

mock.__index = mock

function mock.new(opts)
  opts = opts or {}
  local Buffer = require "ldbus.buffer"
  return setmetatable({
    buf = Buffer.new(),
    replies = opts.replies or {},
    written = {},
    closed = false,
  }, mock)
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

--- Simulate a recv-driven socket: return next chunk from replies
-- (each entry is one recv chunk), false when empty.
function mock:recv()
  local chunk = table.remove(self.replies, 1)
  if chunk then
    return chunk
  end
  return false
end

function mock:wait_readable(timeout)
  -- only queued replies count: buffered data lives in the consumer's
  -- own buffer, not ours
  return self.replies[1] ~= nil
end

function mock:close()
  self.closed = true
end

function mock:sent()
  return table.concat(self.written)
end

return mock
