-- Spec for the bluez GATT server extensions: opts unwrapping, authorize
-- callbacks, subscribe callbacks, descriptors and connection events.
-- Loads the examples/bluez package with a stub bus (no D-Bus I/O).
package.path = "src/?.lua;src/?/init.lua;examples/?.lua;examples/?/init.lua;" .. package.path
local ldbus = require "ldbus"
local bluez = require "bluez"
local common = require "bluez.gatt_common"

local DEV_PATH = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF"

--- A stub bus: records method registrations and signal subscriptions,
-- answers every call successfully, and can replay synthetic signals.
local function make_bus()
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

--- A Bluez client over the stub bus; refresh() fails silently (empty cache).
local function make_bt()
  return bluez.new{ bus = make_bus() }
end

--- Feed a synthetic PropertiesChanged(Device1, Connected) to the handler
-- the app registered (the last PROPS subscription on the bus).
local function feed_connected(bt, path, connected)
  local bus = bt.bus
  local last = bus._signals[#bus._signals]
  assert(last and last.iface == bluez.PROPS and last.member == "PropertiesChanged",
    "no PROPS subscription found")
  last.fn({ path = path, body = { bluez.DEVICE,
    { Connected = ldbus.variant("b", connected) }, {} } })
end

--- Build an app whose characteristic carries explicit handlers (the
-- authorize tests need char-level on_authorize).
local function make_char(bt, handlers)
  local app = bluez.Application(bt, "/com/test/gatt", {
    on_authorize = handlers.app_authorize })
  local svc = app:service("180f")
  local ch = svc:characteristic("2a19", { "read", "write" }, {
    value = "\1",
    on_read = handlers.on_read,
    on_write = handlers.on_write,
    on_authorize = handlers.char_authorize,
  })
  return app, ch
end

describe("bluez.gatt_common", function()
  it("unwrap_opts unwraps variants and resolves a cached device", function()
    local bt = make_bt()
    bt._objects[DEV_PATH] = { [bluez.DEVICE] = { Address = "AA:BB:CC:DD:EE:FF" } }
    local raw = {
      offset = ldbus.variant("u", 4),
      type = ldbus.variant("s", "request"),
      device = ldbus.variant("o", DEV_PATH),
    }
    local opts = common.unwrap_opts(raw, bt)
    assert.equals(4, opts.offset)
    assert.equals("request", opts.type)
    assert.equals(DEV_PATH, opts.device:path())
    -- input table untouched (immutability)
    assert.equals(4, raw.offset.value)
  end)

  it("unwrap_opts returns {} for nil and keeps unknown paths as strings", function()
    local bt = make_bt()
    assert.same({}, common.unwrap_opts(nil, bt))
    local opts = common.unwrap_opts(
      { device = ldbus.variant("o", "/org/bluez/hci0/dev_XX") }, bt)
    assert.equals("/org/bluez/hci0/dev_XX", opts.device)
  end)

  it("resolve_device returns a Device only on cache hit", function()
    local bt = make_bt()
    assert.equals("/p/x", common.resolve_device(bt, "/p/x"))
    bt._objects["/p/y"] = { [bluez.DEVICE] = {} }
    local dev = common.resolve_device(bt, "/p/y")
    assert.equals("/p/y", dev:path())
  end)
end)

describe("bluez authorize", function()
  it("char-level on_authorize false -> NotAuthorized error", function()
    local bt = make_bt()
    local app, ch = make_char(bt, {
      char_authorize = function() return false end })
    local read = bt.bus._methods["/com/test/gatt/service1/char1"]
      [bluez.GATT_CHAR .. ".ReadValue"]
    local ok, err = pcall(read, { offset = ldbus.variant("u", 0) })
    assert.falsy(ok)
    assert.truthy(ldbus.errors.is(err))
    assert.equals("org.bluez.Error.NotAuthorized", err.name)
  end)

  it("char-level authorize falls back to app-level", function()
    local bt = make_bt()
    local seen
    local app, ch = make_char(bt, {
      app_authorize = function(c, op) seen = op; return true end })
    local read = bt.bus._methods["/com/test/gatt/service1/char1"]
      [bluez.GATT_CHAR .. ".ReadValue"]
    local bytes = read({ offset = ldbus.variant("u", 0) })
    assert.equals(1, bytes[1])
    assert.equals("read", seen)
  end)

  it("char-level on_authorize overrides the app-level one", function()
    local bt = make_bt()
    local app_called, char_called = 0, 0
    local app, ch = make_char(bt, {
      app_authorize = function() app_called = app_called + 1; return true end,
      char_authorize = function() char_called = char_called + 1; return true end })
    local read = bt.bus._methods["/com/test/gatt/service1/char1"]
      [bluez.GATT_CHAR .. ".ReadValue"]
    read({})
    assert.equals(1, char_called)
    assert.equals(0, app_called)
  end)

  it("no authorize callback -> read/write pass through with unwrapped opts", function()
    local bt = make_bt()
    bt._objects[DEV_PATH] = { [bluez.DEVICE] = {} }
    local got_opts, wrote_opts
    local app, ch = make_char(bt, {
      on_read = function(opts) got_opts = opts; return "\9" end,
      on_write = function(v, opts) wrote_opts = opts end })
    local methods = bt.bus._methods["/com/test/gatt/service1/char1"]
    local raw = { offset = ldbus.variant("u", 7),
                  device = ldbus.variant("o", DEV_PATH) }
    local bytes = methods[bluez.GATT_CHAR .. ".ReadValue"](raw)
    assert.equals(9, bytes[1])
    assert.equals(7, got_opts.offset)
    assert.equals(DEV_PATH, got_opts.device:path())
    methods[bluez.GATT_CHAR .. ".WriteValue"]({ 1, 2 }, raw)
    assert.equals(7, wrote_opts.offset)
  end)

  it("authorize callback raising its own error propagates unchanged", function()
    local bt = make_bt()
    local app, ch = make_char(bt, {
      char_authorize = function()
        error(ldbus.errors.new("org.bluez.Error.Failed", "custom")) end })
    local read = bt.bus._methods["/com/test/gatt/service1/char1"]
      [bluez.GATT_CHAR .. ".ReadValue"]
    local ok, err = pcall(read, {})
    assert.falsy(ok)
    assert.equals("org.bluez.Error.Failed", err.name)
  end)
end)

describe("bluez descriptors", function()
  local bt, app, ch, desc

  before_each(function()
    bt = make_bt()
    app = bluez.Application(bt, "/com/test/gatt")
    local svc = app:service("180f")
    ch = svc:characteristic("2a19", { "read" }, { value = "\1" })
    desc = ch:descriptor("2901", { "read" }, { value = "Battery Level",
      on_authorize = function() return false end })
  end)

  it("creates a path under the characteristic", function()
    assert.equals("/com/test/gatt/service1/char1/desc1", desc:path())
  end)

  it("registers GattDescriptor1 methods", function()
    local m = bt.bus._methods["/com/test/gatt/service1/char1/desc1"]
    assert.truthy(m[bluez.GATT_DESC .. ".ReadValue"])
    assert.truthy(m[bluez.GATT_DESC .. ".WriteValue"])
    assert.truthy(m[bluez.PROPS .. ".Get"])
    assert.truthy(m[bluez.PROPS .. ".GetAll"])
  end)

  it("exposes UUID/Characteristic/Flags properties", function()
    local props = desc:_props()
    assert.equals("2901", props.UUID.value)
    assert.equals("/com/test/gatt/service1/char1",
      props.Characteristic.value)
    assert.same({ "read" }, props.Flags.value)
  end)

  it("descriptor ReadValue returns the value and honors on_authorize", function()
    local m = bt.bus._methods["/com/test/gatt/service1/char1/desc1"]
    local ok, err = pcall(m[bluez.GATT_DESC .. ".ReadValue"], {})
    assert.falsy(ok)
    assert.equals("org.bluez.Error.NotAuthorized", err.name)
    -- allow via the app-level callback fallback: replace the desc-level
    -- handler with an app-level allow-all
    desc.on_authorize = nil
    app._on_authorize = function() return true end
    local bytes = m[bluez.GATT_DESC .. ".ReadValue"]({})
    assert.equals(string.byte("B"), bytes[1])
  end)

  it("descriptor WriteValue updates the value and passes unwrapped opts", function()
    local wrote_value, wrote_opts
    local d2 = ch:descriptor("2902", { "write" }, {
      on_write = function(v, opts) wrote_value = v; wrote_opts = opts end })
    local m = bt.bus._methods["/com/test/gatt/service1/char1/desc2"]
    m[bluez.GATT_DESC .. ".WriteValue"]({ 65, 66 },
      { offset = ldbus.variant("u", 3) })
    assert.equals("AB", wrote_value)
    assert.equals(3, wrote_opts.offset)
    -- cached value updated, visible via Get
    local v = m[bluez.PROPS .. ".Get"](nil, "Value")
    assert.equals(65, v.value[1])
  end)

  it("a raising on_write rejects the write and keeps the cached value", function()
    local d2 = ch:descriptor("2902", { "write" }, {
      value = "original",
      on_write = function()
        error(ldbus.errors.new("org.bluez.Error.Failed", "nope")) end })
    local m = bt.bus._methods["/com/test/gatt/service1/char1/desc2"]
    local ok, err = pcall(m[bluez.GATT_DESC .. ".WriteValue"], { 65 }, {})
    assert.falsy(ok)
    assert.equals("org.bluez.Error.Failed", err.name)
    local v = m[bluez.PROPS .. ".Get"](nil, "Value")
    assert.equals(string.byte("o"), v.value[1])   -- still "original"
  end)

  it("GetManagedObjects includes desc entry + char Descriptors", function()
    local objs = bt.bus._methods["/com/test/gatt"]
      [bluez.OM .. ".GetManagedObjects"]()
    local dp = "/com/test/gatt/service1/char1/desc1"
    assert.truthy(objs[dp] and objs[dp][bluez.GATT_DESC])
    local cp = objs["/com/test/gatt/service1/char1"]
    assert.truthy(cp[bluez.GATT_CHAR].Descriptors, "Descriptors missing")
    assert.equals(dp, cp[bluez.GATT_CHAR].Descriptors.value[1])
  end)
end)

describe("bluez subscribe callbacks", function()
  it("StartNotify/StopNotify fire on_subscribe/on_unsubscribe", function()
    local bt = make_bt()
    local subs, unsubs = 0, 0
    local app = bluez.Application(bt, "/com/test/gatt")
    local svc = app:service("180f")
    local ch = svc:characteristic("2a19", { "read", "notify" }, {
      value = "\1",
      on_subscribe = function() subs = subs + 1 end,
      on_unsubscribe = function() unsubs = unsubs + 1 end,
    })
    local m = bt.bus._methods["/com/test/gatt/service1/char1"]
    m[bluez.GATT_CHAR .. ".StartNotify"]()
    assert.equals(1, subs)
    assert.is_true(ch._notifying)
    m[bluez.GATT_CHAR .. ".StopNotify"]()
    assert.equals(1, unsubs)
    assert.falsy(ch._notifying)
  end)

  it("a throwing subscribe callback does not break StartNotify", function()
    local bt = make_bt()
    local app = bluez.Application(bt, "/com/test/gatt")
    local svc = app:service("180f")
    local ch = svc:characteristic("2a19", { "notify" }, {
      value = "\1",
      on_subscribe = function() error("boom") end,
    })
    local m = bt.bus._methods["/com/test/gatt/service1/char1"]
    assert.not_error(function() m[bluez.GATT_CHAR .. ".StartNotify"]() end)
    assert.is_true(ch._notifying)
  end)
end)

describe("bluez connection events", function()
  it("on_connect / on_disconnect fire on Connected edge changes", function()
    local bt = make_bt()
    -- baseline: one device already connected, one not
    bt._objects[DEV_PATH] = { [bluez.DEVICE] = { Connected = true } }
    local other = "/org/bluez/hci0/dev_11_22_33_44_55_66"
    bt._objects[other] = { [bluez.DEVICE] = { Connected = false } }
    local connected, disconnected = {}, {}
    local app = bluez.Application(bt, "/com/test/gatt", {
      on_connect = function(dev) connected[#connected + 1] = dev end,
      on_disconnect = function(dev) disconnected[#disconnected + 1] = dev end,
    })
    app:register("/org/bluez/hci0")

    -- already-connected device: duplicate true is not an edge -> no callback
    feed_connected(bt, DEV_PATH, true)
    assert.equals(0, #connected)

    -- device 2 connects (unknown -> false baseline, so this is an edge)
    feed_connected(bt, other, true)
    assert.equals(1, #connected)
    assert.equals(other, connected[1]:path())

    -- repeated true (no edge) -> still one
    feed_connected(bt, other, true)
    assert.equals(1, #connected)

    -- disconnect
    feed_connected(bt, other, false)
    assert.equals(1, #disconnected)
    assert.equals(other, disconnected[1]:path())
  end)

  it("non-Device PropertiesChanged signals are ignored", function()
    local bt = make_bt()
    local fired = 0
    local app = bluez.Application(bt, "/com/test/gatt", {
      on_connect = function() fired = fired + 1 end })
    app:register("/org/bluez/hci0")
    local last = bt.bus._signals[#bt.bus._signals]
    last.fn({ path = DEV_PATH, body = { bluez.GATT_CHAR,
      { Value = ldbus.variant("ay", { 1 }) }, {} } })
    last.fn({ path = DEV_PATH, body = { bluez.DEVICE, { RSSI = ldbus.variant("n", -50) }, {} } })
    assert.equals(0, fired)
  end)

  it("only-on_disconnect config: a connect edge does not fire on_disconnect", function()
    local bt = make_bt()
    local disconnected = 0
    local app = bluez.Application(bt, "/com/test/gatt", {
      on_disconnect = function() disconnected = disconnected + 1 end })
    app:register("/org/bluez/hci0")
    feed_connected(bt, DEV_PATH, true)
    assert.equals(0, disconnected)
    feed_connected(bt, DEV_PATH, false)
    assert.equals(1, disconnected)
  end)

  it("re-registering does not stack duplicate connection watchers", function()
    local bt = make_bt()
    local fired = 0
    local app = bluez.Application(bt, "/com/test/gatt", {
      on_connect = function() fired = fired + 1 end })
    app:register("/org/bluez/hci0")
    local n_subs = #bt.bus._signals
    app:register("/org/bluez/hci0")            -- second register
    assert.equals(n_subs, #bt.bus._signals)    -- no extra subscription
    feed_connected(bt, DEV_PATH, true)
    assert.equals(1, fired)                    -- fired once, not twice
  end)

  it("unregister removes the connection watcher", function()
    local bt = make_bt()
    local fired = 0
    local app = bluez.Application(bt, "/com/test/gatt", {
      on_connect = function() fired = fired + 1 end })
    app:register("/org/bluez/hci0")
    local n_before = #bt.bus._signals  -- bluez cache subs + app's PROPS sub
    app:unregister("/org/bluez/hci0")
    -- handler removed from the stub bus
    local bus = bt.bus
    assert.equals(1, #bus._offs)
    assert.equals(n_before - 1, #bus._signals)
    feed_connected(bt, DEV_PATH, true)  -- must not reach a stale handler
    assert.equals(0, fired)
  end)
end)
