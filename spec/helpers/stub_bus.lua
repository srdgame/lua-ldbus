-- Shared stub bus for the bluez example-package specs: records method
-- registrations and signal subscriptions, answers every call
-- successfully, and lets specs inspect/replay what happened.
local bluez = require "bluez"

local stub_bus = {}

function stub_bus.make_bus()
  local bus = { _methods = {}, _signals = {}, _offs = {} }

  function bus:on_signal(iface, member, fn, opts)
    self._signals[#self._signals + 1] =
      { iface = iface, member = member, fn = fn, opts = opts }
    return true
  end

  function bus:off_signal(iface, member, fn)
    self._offs[#self._offs + 1] = { iface = iface, member = member, fn = fn }
    for i, s in ipairs(self._signals) do
      if s.fn == fn then table.remove(self._signals, i) break end
    end
    return true
  end

  function bus:object(path)
    return {
      method = function(_, key, insig, outsig, fn)
        bus._methods[path] = bus._methods[path] or {}
        bus._methods[path][key] = fn
      end,
    }
  end

  function bus:call()
    return { {} }   -- success, empty reply body
  end

  function bus:emit() end

  return bus
end

--- A Bluez client over a fresh stub bus; refresh() fails silently
-- (empty cache) and the cache starts empty. `opts.fail_calls` makes
-- outbound calls fail (nil + err) so specs exercise the cache fallback
-- paths instead of the stub's empty success reply.
function stub_bus.make_bt(opts)
  local bt = bluez.new{ bus = stub_bus.make_bus() }
  if opts and opts.fail_calls then
    bt.bus.call = function()
      return nil, { name = "org.freedesktop.DBus.Error.UnknownMethod" }
    end
  end
  return bt
end

return stub_bus
