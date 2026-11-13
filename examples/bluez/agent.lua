--- bluez.agent: pairing agent support. Exports an org.bluez.Agent1
-- object and registers it with bluetoothd via
-- org.bluez.AgentManager1 so the local daemon consults us during
-- pairing and service authorization:
--
--   local bluez = require "bluez"   -- loads the agent module automatically
--   local agent = bluez.Agent(bt, "/com/example/agent", {
--     capability = "KeyboardDisplay",      -- default; see Agent1 docs
--     on_confirm = function(device, passkey)
--       return passkey == 123456           -- false -> Rejected
--     end,
--     on_authorize = function(device) return true end,
--     on_request_passkey = function(device) return 123456 end,
--   })
--   agent:register()      -- RegisterAgent + RequestDefaultAgent
--   ...
--   agent:unregister()
--
-- A mainloop must be running while the agent is registered --
-- bluetoothd calls back into the exported object. Handlers returning
-- false (or absent, for the confirm/authorize/request family) reply
-- org.bluez.Error.Rejected; display/cancel/release callbacks run
-- fire-and-forget (errors are reported on stderr, never propagated).
--
-- @module bluez.agent

local ldbus = require "ldbus"
local bluez = require "bluez"

-- middleclass: same lookup strategy as the core module.
if not pcall(require, "middleclass") then
  package.path = "middleclass/?.lua;" .. package.path
end
local middleclass = require "middleclass"

local common = require "bluez.gatt_common"

local REJECTED = "org.bluez.Error.Rejected"

--- Build a handler for a request-style Agent1 method: device paths are
-- resolved to Device handles, a false return (or a missing callback)
-- raises Rejected which the router turns into the D-Bus error reply.
local function requester(bt, fn, what)
  return function(device_path, ...)
    if not fn then
      error(ldbus.errors.new(REJECTED, "no " .. what .. " handler"))
    end
    local dev = common.resolve_device(bt, device_path)
    local result = fn(dev, ...)
    if result == false then
      error(ldbus.errors.new(REJECTED, what .. " rejected"))
    end
    return result, ...   -- passkey/pincode handlers return a value
  end
end

--------------------------------------------------------------------------------
-- Agent: one exported org.bluez.Agent1 object + AgentManager1 registration
--------------------------------------------------------------------------------

local Agent = middleclass("Agent")

--- Create a pairing agent bound to `path` (a unique object path on our
-- bus, e.g. "/com/example/agent"). `opts` handlers all receive the
-- Device handle first (resolved from the object path when cached):
--   capability             = "" | "DisplayOnly" | "DisplayYesNo" |
--                            "KeyboardOnly" | "NoInputNoOutput" |
--                            "KeyboardDisplay" (default)
--   on_confirm             = fn(device, passkey) -> bool
--   on_authorize           = fn(device) -> bool
--   on_authorize_service   = fn(device, uuid) -> bool
--   on_request_pin_code    = fn(device) -> pin string
--   on_request_passkey     = fn(device) -> passkey number
--   on_display_passkey     = fn(device, passkey, entered)
--   on_display_pin_code    = fn(device, pin)
--   on_cancel              = fn()   -- current request was cancelled
--   on_release             = fn()   -- bluetoothd released the agent
function Agent:initialize(bt, path, opts)
  opts = opts or {}
  self._bt = bt
  self._path = path
  self._capability = opts.capability or "KeyboardDisplay"

  local obj = bt.bus:object(path)

  obj:method("org.bluez.Agent1.Release", "", "", function()
    common.pcall_safe(opts.on_release)
  end)

  obj:method("org.bluez.Agent1.RequestPinCode", "o", "s",
    requester(bt, opts.on_request_pin_code, "pin code"))

  obj:method("org.bluez.Agent1.RequestPasskey", "o", "u",
    requester(bt, opts.on_request_passkey, "passkey"))

  obj:method("org.bluez.Agent1.DisplayPasskey", "osu", "", function(dev, key, entered)
    common.pcall_safe(opts.on_display_passkey,
      common.resolve_device(bt, dev), key, entered)
  end)

  obj:method("org.bluez.Agent1.DisplayPinCode", "os", "", function(dev, pin)
    common.pcall_safe(opts.on_display_pin_code,
      common.resolve_device(bt, dev), pin)
  end)

  obj:method("org.bluez.Agent1.RequestConfirmation", "ou", "",
    requester(bt, opts.on_confirm, "confirmation"))

  obj:method("org.bluez.Agent1.RequestAuthorization", "o", "",
    requester(bt, opts.on_authorize, "authorization"))

  obj:method("org.bluez.Agent1.AuthorizeService", "os", "",
    requester(bt, opts.on_authorize_service, "service"))

  obj:method("org.bluez.Agent1.Cancel", "", "", function()
    common.pcall_safe(opts.on_cancel)
  end)
end

--- The D-Bus object path of this agent.
function Agent:path()
  return self._path
end

--- Register with bluetoothd (org.bluez.AgentManager1.RegisterAgent)
-- and make it the default agent (RequestDefaultAgent). Requires a
-- running mainloop. Returns true, or nil + err.
function Agent:register()
  local values, err = self._bt.bus:call(bluez.SERVICE, bluez.MANAGER_ROOT,
    bluez.AGENT_MANAGER, "RegisterAgent",
    { self._path, self._capability }, { signature = "os" })
  if not values then
    return nil, err
  end
  values, err = self._bt.bus:call(bluez.SERVICE, bluez.MANAGER_ROOT,
    bluez.AGENT_MANAGER, "RequestDefaultAgent",
    { self._path }, { signature = "o" })
  if not values then
    return nil, err
  end
  return true
end

--- Unregister the agent (org.bluez.AgentManager1.UnregisterAgent).
-- Returns true, or nil + err.
function Agent:unregister()
  local values, err = self._bt.bus:call(bluez.SERVICE, bluez.MANAGER_ROOT,
    bluez.AGENT_MANAGER, "UnregisterAgent",
    { self._path }, { signature = "o" })
  if not values then
    return nil, err
  end
  return true
end

bluez.Agent = Agent

return true
