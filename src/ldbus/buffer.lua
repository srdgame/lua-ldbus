--- Partial-read accumulator.
-- Socket reads may return small chunks or `false` (would-block); this
-- buffer accumulates them and serves two consumption modes:
--   * line mode (SASL handshake, "\r\n" terminated)
--   * frame mode (messages: `take(n)` once the total length is known)
-- @module ldbus.buffer

local middleclass = require "ldbus.class"

local Buffer = middleclass("Buffer")

function Buffer:initialize()
  self.data = ""
end

--- Append a chunk (any size, including "" or false, both ignored).
function Buffer:feed(chunk)
  if type(chunk) == "string" and #chunk > 0 then
    self.data = self.data .. chunk
  end
end

function Buffer:available()
  return #self.data
end

--- Peek without consuming; returns up to `n` bytes or nil if fewer available.
function Buffer:peek(n)
  if #self.data < n then
    return nil
  end
  return self.data:sub(1, n)
end

--- Consume exactly `n` bytes, or return nil if not enough buffered.
function Buffer:take(n)
  if #self.data < n then
    return nil
  end
  local s = self.data:sub(1, n)
  self.data = self.data:sub(n + 1)
  return s
end

--- Consume one "\r\n"-terminated line (including the terminator),
-- or nil if no complete line is buffered.
function Buffer:read_line()
  local idx = self.data:find("\r\n", 1, true)
  if not idx then
    return nil
  end
  local line = self.data:sub(1, idx + 1)
  self.data = self.data:sub(idx + 2)
  return line
end

--- Drop all buffered data.
function Buffer:clear()
  self.data = ""
end

return Buffer
