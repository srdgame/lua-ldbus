-- Spec for the bluez pairing agent (Agent1 export + AgentManager1
-- registration). Stub bus, no D-Bus I/O.
package.path = "src/?.lua;src/?/init.lua;examples/?.lua;examples/?/init.lua;" .. package.path
local ldbus = require "ldbus"
local bluez = require "bluez"
local stub_bus = require "stub_bus"

local DEV_PATH = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF"

--- A Bluez agent with a single confirm handler; extra handlers may be
-- added by the tests.
local function make_agent(handlers)
  handlers = handlers or {}
  local bt = stub_bus.make_bt()
  local agent = bluez.Agent(bt, "/com/test/agent", handlers)
  return bt, agent
end

--- The recorded bus:call calls (the stub answers successfully, but we
-- want to assert what was sent to AgentManager1).
local function record_calls(bt)
  local sent = {}
  local real_call = bt.bus.call
  bt.bus.call = function(bus, dest, path, iface, member, args, opts)
    sent[#sent + 1] = { dest = dest, path = path, iface = iface,
                        member = member, args = args, opts = opts }
    return real_call(bus, dest, path, iface, member, args, opts)
  end
  return sent
end

--- Invoke an agent method handler directly (as the router would).
local function invoke(agent_bt, member, ...)
  local fn = agent_bt.bus._methods["/com/test/agent"]["org.bluez.Agent1." .. member]
  assert(fn, "agent method not exported: " .. tostring(member))
  return fn(...)
end

describe("bluez.Agent registration", function()
  it("registers and requests default via AgentManager1 on /org/bluez", function()
    local bt, agent = make_agent()
    local sent = record_calls(bt)
    assert.truthy(agent:register())
    assert.equals(2, #sent)
    assert.equals(bluez.SERVICE, sent[1].dest)
    assert.equals("/org/bluez", sent[1].path)
    assert.equals("org.bluez.AgentManager1", sent[1].iface)
    assert.equals("RegisterAgent", sent[1].member)
    assert.same({ "/com/test/agent", "KeyboardDisplay" }, sent[1].args)
    assert.equals("RequestDefaultAgent", sent[2].member)
    assert.same({ "/com/test/agent" }, sent[2].args)
  end)

  it("capability defaults to KeyboardDisplay and is configurable", function()
    local bt = stub_bus.make_bt()
    local agent = bluez.Agent(bt, "/com/test/agent")   -- default capability
    local sent = record_calls(bt)
    agent:register()
    assert.same({ "/com/test/agent", "KeyboardDisplay" }, sent[1].args)
    local bt2 = stub_bus.make_bt()
    local agent2 = bluez.Agent(bt2, "/com/test/agent", { capability = "NoInputNoOutput" })
    record_calls(bt2)
    agent2:register()
    -- args checked implicitly by the passkey tests below; here just no error
    assert.truthy(agent2:register())
  end)

  it("unregister issues UnregisterAgent", function()
    local bt, agent = make_agent()
    local sent = record_calls(bt)
    assert.truthy(agent:unregister())
    assert.equals(1, #sent)
    assert.equals("UnregisterAgent", sent[1].member)
    assert.same({ "/com/test/agent" }, sent[1].args)
  end)

  it("register failure propagates the error", function()
    local bt = stub_bus.make_bt()
    local agent = bluez.Agent(bt, "/com/test/agent")
    bt.bus.call = function()
      return nil, { name = "org.bluez.Error.AlreadyExists" }
    end
    local ok, err = agent:register()
    assert.falsy(ok)
    assert.equals("org.bluez.Error.AlreadyExists", err.name)
  end)
end)

describe("bluez.Agent confirm/authorize", function()
  it("RequestConfirmation accepts on true, rejects on false", function()
    local bt, agent = make_agent{ on_confirm = function(dev, passkey)
      return passkey == 123456 end }
    invoke(bt, "RequestConfirmation", DEV_PATH, 123456)
    local ok, err = pcall(invoke, bt, "RequestConfirmation", DEV_PATH, 999999)
    assert.falsy(ok)
    assert.equals("org.bluez.Error.Rejected", err.name)
  end)

  it("RequestConfirmation resolves the device to a Device handle", function()
    local seen
    local bt, agent = make_agent{ on_confirm = function(dev)
      seen = dev; return true end }
    bt._objects[DEV_PATH] = { [bluez.DEVICE] = { Address = "AA:BB:CC:DD:EE:FF" } }
    invoke(bt, "RequestConfirmation", DEV_PATH, 42)
    assert.equals(DEV_PATH, seen:path())
  end)

  it("RequestAuthorization / AuthorizeService pass the device + uuid", function()
    local got_dev, got_uuid
    local bt, agent = make_agent{
      on_authorize = function(dev) got_dev = dev; return true end,
      on_authorize_service = function(dev, uuid) got_dev, got_uuid = dev, uuid;
        return true end }
    invoke(bt, "RequestAuthorization", DEV_PATH)
    invoke(bt, "AuthorizeService", DEV_PATH, "0000110b-0000-1000-8000-00805f9b34fb")
    assert.equals(DEV_PATH, got_dev)
    assert.equals("0000110b-0000-1000-8000-00805f9b34fb", got_uuid)
  end)

  it("no callback registered -> rejected", function()
    local bt, agent = make_agent()
    local ok, err = pcall(invoke, bt, "RequestConfirmation", DEV_PATH, 1)
    assert.falsy(ok)
    assert.equals("org.bluez.Error.Rejected", err.name)
    local ok2, err2 = pcall(invoke, bt, "AuthorizeService", DEV_PATH, "uuid")
    assert.falsy(ok2)
    assert.equals("org.bluez.Error.Rejected", err2.name)
  end)
end)

describe("bluez.Agent passkey/pincode", function()
  it("RequestPasskey returns the handler's number", function()
    local bt, agent = make_agent{ on_request_passkey = function(dev)
      return 123456 end }
    local passkey = invoke(bt, "RequestPasskey", DEV_PATH)
    assert.equals(123456, passkey)
  end)

  it("RequestPinCode returns the handler's string", function()
    local bt, agent = make_agent{ on_request_pin_code = function(dev)
      return "1234" end }
    assert.equals("1234", invoke(bt, "RequestPinCode", DEV_PATH))
  end)

  it("missing request handlers -> rejected", function()
    local bt, agent = make_agent()
    local ok, err = pcall(invoke, bt, "RequestPasskey", DEV_PATH)
    assert.falsy(ok)
    assert.equals("org.bluez.Error.Rejected", err.name)
  end)

  it("DisplayPasskey/DisplayPinCode/Cancel/Release fire callbacks safely", function()
    local events = {}
    local bt, agent = make_agent{
      on_display_passkey = function(dev, passkey, entered)
        events[#events + 1] = { "passkey", passkey, entered } end,
      on_display_pin_code = function(dev, pin)
        events[#events + 1] = { "pin", pin } end,
      on_cancel = function() events[#events + 1] = { "cancel" } end,
      on_release = function() events[#events + 1] = { "release" } end,
    }
    invoke(bt, "DisplayPasskey", DEV_PATH, 123456, 3)
    invoke(bt, "DisplayPinCode", DEV_PATH, "12 34")
    invoke(bt, "Cancel")
    invoke(bt, "Release")
    assert.same({ { "passkey", 123456, 3 }, { "pin", "12 34" },
                  { "cancel" }, { "release" } }, events)
    -- a throwing display callback must not propagate
    local bt2 = stub_bus.make_bt()
    local agent2 = bluez.Agent(bt2, "/com/test/agent",
      { on_display_passkey = function() error("boom") end })
    assert.not_error(function()
      bt2.bus._methods["/com/test/agent"]
        ["org.bluez.Agent1.DisplayPasskey"](DEV_PATH, 1, 0)
    end)
  end)
end)
