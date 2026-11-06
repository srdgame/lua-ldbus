local scheduler = require "ldbus.scheduler"

describe("ldbus.scheduler", function()
  it("spawn runs a task immediately on run()", function()
    local sched = scheduler()
    local ran = false
    sched:spawn(function() ran = true end)
    assert.is_false(ran) -- not yet: runs on run()
    sched:run()
    assert.is_true(ran)
  end)

  it("spawn(fn, ...) passes arguments", function()
    local sched = scheduler()
    local a, b
    sched:spawn(function(x, y) a, b = x, y end, 1, "two")
    sched:run()
    assert.equals(1, a)
    assert.equals("two", b)
  end)

  it("wait/wake: task suspends until its serial wakes it", function()
    local sched = scheduler()
    local result
    sched:spawn(function()
      local reply = sched:wait(42)
      result = reply and reply.value
    end)
    sched:run()
    assert.is_nil(result) -- suspended
    assert.is_false(sched:wake(7, { value = "wrong" })) -- unknown serial
    assert.is_true(sched:wake(42, { value = "ok" }))
    sched:run()
    assert.equals("ok", result)
  end)

  it("task errors do not kill other tasks", function()
    local sched = scheduler()
    local errors_seen = {}
    sched.on_error = function(err) errors_seen[#errors_seen + 1] = err end
    local after = false
    sched:spawn(function() error("boom") end)
    sched:spawn(function() after = true end)
    sched:run()
    assert.is_true(after)
    assert.equals(1, #errors_seen)
    assert.truthy(tostring(errors_seen[1]):find("boom"))
  end)

  it("wait with deadline expires (returns nil reply)", function()
    local sched = scheduler()
    local timed_out = "not yet"
    sched:spawn(function()
      local reply = sched:wait(5, os.clock() - 1) -- already past
      timed_out = reply == nil
    end)
    sched:run() -- task suspends with deadline
    sched:check_deadlines(os.clock())
    sched:run()
    assert.is_true(timed_out)
  end)

  it("non-expired deadlines keep the task waiting", function()
    local sched = scheduler()
    local done = false
    sched:spawn(function()
      sched:wait(9, os.clock() + 10)
      done = true
    end)
    sched:run()
    sched:check_deadlines(os.clock())
    sched:run()
    assert.is_false(done)
    assert.is_true(sched:wake(9, {}))
    sched:run()
    assert.is_true(done)
  end)

  it("nested spawn inside a task works", function()
    local sched = scheduler()
    local result
    sched:spawn(function()
      sched:spawn(function() result = "inner" end)
      sched:run() -- tasks may run nested schedulers
    end)
    sched:run()
    assert.equals("inner", result)
  end)
end)
