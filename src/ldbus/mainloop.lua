--- Coroutine mainloop: pumps connections, dispatches messages, and runs
--- scheduled tasks. Inside a running mainloop, bus:call() suspends the
--- calling task instead of blocking, and exported methods run as
--- coroutines (so handlers may call other services).
-- @module ldbus.mainloop

local scheduler = require "ldbus.scheduler"
local mainloop = {}

--- Normalize `buses` (one bus or a list) into { list_of_buses, list_of_conns }.
local function collect(buses)
  if buses.conn then -- single Bus
    buses = { buses }
  end
  local bus_list, conns = {}, {}
  for i, bus in ipairs(buses) do
    assert(bus.conn, "mainloop.run expects Bus objects")
    bus_list[#bus_list + 1] = bus
    conns[#conns + 1] = bus.conn
  end
  return bus_list, conns
end

local function install(conns, sched)
  for _, conn in ipairs(conns) do
    if conn.loop_mode then
      error("connection is already running inside a mainloop", 2)
    end
    conn.loop_mode = true
    conn._scheduler = sched
    conn._loop_call = sched:make_call(conn)
  end
end

local function uninstall(conns, bus_list)
  for _, conn in ipairs(conns) do
    conn.loop_mode = false
    conn._scheduler = nil
    conn._loop_call = nil
  end
  for _, bus in ipairs(bus_list) do
    bus._quit = false
  end
end

local function quit_requested(bus_list)
  for _, bus in ipairs(bus_list) do
    if bus._quit then
      return true
    end
  end
  return false
end

--- Run the loop over one bus or a list of buses (sharing one scheduler).
-- opts:
--   timeout = select/pump timeout in seconds (default 0.1)
--   init    = function() run as the first task
--   ["until"] = function() -> true stops the loop (test/one-shot helper)
--   on_error = function(err) task error hook (default: stderr)
-- Returns when quit() is called on any bus, opts.until fires, or the
-- connection closes/errors (then raises).
function mainloop.run(buses, opts)
  opts = opts or {}
  local bus_list, conns = collect(buses)
  local sched = scheduler()
  if opts.on_error then
    sched.on_error = opts.on_error
  end

  install(conns, sched)
  if opts.init then
    sched:spawn(opts.init)
    sched:run()
  end

  local timeout = opts.timeout or 0.1
  local ok, err = pcall(function()
    while true do
      for _, conn in ipairs(conns) do
        conn:pump(timeout)
      end
      sched:check_deadlines(os.clock())
      sched:run()
      if opts["until"] and opts["until"]() then
        return
      end
      if quit_requested(bus_list) then
        return
      end
    end
  end)

  uninstall(conns, bus_list)
  if not ok then
    error(err, 0)
  end
end

return mainloop
