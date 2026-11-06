--- Coroutine task scheduler used by the mainloop.
-- Tasks are coroutines; a task suspends with wait(serial, deadline) and
-- is resumed with the reply message when wake(serial, reply) fires.
-- @module ldbus.scheduler

local middleclass = require "ldbus.class"

local scheduler = middleclass("Scheduler")

--- Create a scheduler.
function scheduler:initialize()
  self.tasks = {}    -- coroutine -> record { co, key, deadline }
  self.ready = {}    -- FIFO of runnable records
  self.waiting = {}  -- wait-key -> record
  self.on_error = nil -- fn(err) for task errors (default: stderr)
end

--- Spawn a task: fn runs in a coroutine, args passed through.
function scheduler:spawn(fn, ...)
  local nargs = select("#", ...)
  local spawn_args = { ... }
  local co = coroutine.create(function()
    return fn(table.unpack(spawn_args, 1, nargs))
  end)
  local rec = { co = co }
  self.tasks[co] = rec
  self.ready[#self.ready + 1] = rec
  return rec
end

--- The record of the currently running task (or nil outside a task).
function scheduler:current()
  local co = (coroutine.running())
  return co and self.tasks[co] or nil
end

--- Wait keys combine the connection and serial (serials are only
--- unique per connection, and one scheduler may drive many connections).
-- Keys are built from the connection's plain io table (middleclass
-- instances all stringify as "instance of class ...", so `conn` itself
-- is not unique as a string).
-- Static method: scheduler.wait_key(conn, serial).
function scheduler.static.wait_key(conn, serial)
  return tostring(conn.io) .. ":" .. serial
end

--- Suspend the current task until wake(key, reply). Called from
--- inside a task. `deadline` (os.clock time) is optional.
function scheduler:wait(key, deadline)
  local rec = self:current()
  assert(rec, "scheduler:wait outside a task")
  rec.key = key
  rec.deadline = deadline
  self.waiting[key] = rec
  return coroutine.yield()
end

--- Resume the task waiting on `key` with `reply` (may be nil on
--- timeout). Returns true if a task was woken.
function scheduler:wake(key, reply)
  local rec = self.waiting[key]
  if not rec then
    return false
  end
  self.waiting[key] = nil
  rec.key = nil
  rec.deadline = nil
  rec.reply = reply
  self.ready[#self.ready + 1] = rec
  return true
end

--- Wake every waiting task whose deadline has passed (reply = nil).
function scheduler:check_deadlines(now)
  for key, rec in pairs(self.waiting) do
    if rec.deadline and now > rec.deadline then
      self:wake(key, nil)
    end
  end
end

local function default_on_error(err)
  io.stderr:write("ldbus: task error: ", tostring(err), "\n")
end

--- Run all ready tasks until the queue drains. Task errors are passed
--- to on_error; they never abort the run.
function scheduler:run()
  while #self.ready > 0 do
    local rec = table.remove(self.ready, 1)
    local co = rec.co
    if co and coroutine.status(co) ~= "dead" then
      local ok, yielded = coroutine.resume(co, rec.reply)
      rec.reply = nil
      if not ok then
        (self.on_error or default_on_error)(yielded)
        self.tasks[co] = nil
      elseif coroutine.status(co) == "suspended" then
        -- resumed on wake(); wait() already registered it
      else
        self.tasks[co] = nil
      end
    end
  end
end

--- Build a coroutine-friendly Connection:call replacement: send the
--- call, suspend until the reply wakes us, then translate the reply to
--- the call() return convention.
function scheduler:make_call(conn)
  return function(_, dest, path, iface, member, args, opts)
    opts = opts or {}
    local message = require "ldbus.message"
    local serial = conn:send({
      type = message.TYPE.METHOD_CALL,
      path = path,
      interface = iface,
      member = member,
      destination = dest,
      signature = opts.signature or "",
      body = args,
    })
    local timeout = opts.timeout or 25
    local key = scheduler.wait_key(conn, serial)
    conn.pending[serial] = function(msg)
      conn.pending[serial] = nil
      self:wake(key, msg)
    end
    local reply = self:wait(key, os.clock() + timeout)
    if not reply then
      return nil, { name = "org.freedesktop.DBus.Error.Timeout",
                    message = "call timed out" }
    end
    if reply.type == message.TYPE.ERROR then
      return nil, { name = reply.error_name, message = reply.body[1] or "" }
    end
    return reply.body
  end
end

return scheduler
