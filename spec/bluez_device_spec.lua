-- Spec for bluez Device1 convenience accessors and the Battery1 client.
-- Stub bus, cache-seeded, no D-Bus I/O.
package.path = "src/?.lua;src/?/init.lua;examples/?.lua;examples/?/init.lua;" .. package.path
local ldbus = require "ldbus"
local bluez = require "bluez"
local stub_bus = require "stub_bus"

local DEV_PATH = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF"
local BAT_UUID = "0000180f-0000-1000-8000-00805f9b34fb"

local function seeded_bt()
  local bt = stub_bus.make_bt{ fail_calls = true }
  bt._objects[DEV_PATH] = { [bluez.DEVICE] = {
    Address = "AA:BB:CC:DD:EE:FF",
    UUIDs = { BAT_UUID, "00001801-0000-1000-8000-00805f9b34fb" },
    Appearance = 962,
    TxPower = 0,
    Bonded = true,
    WakeAllowed = false,
    AdvertisingFlags = { 6 },
    AdvertisingData = {
      [8] = ldbus.variant("ay", { 104, 105 }),          -- ay -> untouched
      [255] = ldbus.variant("u", 7),                    -- other types unwrap
    },
    ManufacturerData = {
      [0x0059] = ldbus.variant("ay", { 1, 2, 3 }),      -- ay -> string
    },
    ServiceData = {
      ["0000fe95-0000-1000-8000-00805f9b34fb"] = ldbus.variant("ay", { 9 }),
    },
  } }
  return bt
end

describe("bluez Device1 accessors", function()
  it("reads scalar identity properties from the cache", function()
    local bt = seeded_bt()
    local dev = bt:device(DEV_PATH)
    assert.same({ BAT_UUID, "00001801-0000-1000-8000-00805f9b34fb" }, dev:uuids())
    assert.equals(962, dev:appearance())
    assert.equals(0, dev:tx_power())
    assert.is_true(dev:is_bonded())
    assert.falsy(dev:is_wake_allowed())
  end)

  it("set_wake_allowed issues a Properties.Set", function()
    local bt = seeded_bt()
    local dev = bt:device(DEV_PATH)
    local sent
    bt.bus.call = function(_, dest, path, iface, member, args, opts)
      sent = { dest = dest, path = path, iface = iface,
               member = member, args = args, opts = opts }
      return { {} }
    end
    assert.truthy(dev:set_wake_allowed(true))
    assert.equals(bluez.PROPS, sent.iface)
    assert.equals("Set", sent.member)
    assert.equals("ssv", sent.opts.signature)
    assert.same({ bluez.DEVICE, "WakeAllowed" }, { sent.args[1], sent.args[2] })
    assert.equals("b", sent.args[3].signature)
    assert.is_true(sent.args[3].value)
  end)

  it("advertising_flags returns plain byte ints", function()
    local dev = seeded_bt():device(DEV_PATH)
    assert.same({ 6 }, dev:advertising_flags())
  end)

  it("advertising_data unwraps variants and keeps ay as byte tables", function()
    local dev = seeded_bt():device(DEV_PATH)
    local ad = dev:advertising_data()
    assert.same({ 104, 105 }, ad[8])
    assert.equals(7, ad[255])
  end)

  it("manufacturer_data / service_data convert ay to strings", function()
    local dev = seeded_bt():device(DEV_PATH)
    local md = dev:manufacturer_data()
    assert.equals("\1\2\3", md[89])
    local sd = dev:service_data()
    assert.equals("\9", sd["0000fe95-0000-1000-8000-00805f9b34fb"])
  end)

  it("missing properties return nil", function()
    local bt = seeded_bt()
    bt._objects[DEV_PATH][bluez.DEVICE].ManufacturerData = nil
    local dev = bt:device(DEV_PATH)
    assert.equal(nil, dev:manufacturer_data())
  end)
end)

describe("bluez Battery1 client", function()
  it("enumerates batteries and reads Percentage", function()
    local bt = seeded_bt()
    bt._objects[DEV_PATH][bluez.BATTERY] = { Percentage = 88 }
    local bats = bt:batteries()
    assert.equals(1, #bats)
    assert.equals(DEV_PATH, bats[1]:path())
    assert.equals(88, bats[1]:percentage())
  end)

  it("returns an empty list when no battery interface exists", function()
    local bt = seeded_bt()
    assert.same({}, bt:batteries())
  end)
end)
