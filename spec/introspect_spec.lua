local Connection = require "ldbus.connection"
local router = require "ldbus.router"
local introspect = require "ldbus.introspect"
local message = require "ldbus.message"
local mock = require "mock_socket"

--- Connection with routing attached, over a mock io.
local function new_conn()
  local io_obj = mock({})
  local conn = Connection(io_obj)
  router.attach(conn)
  return conn, io_obj
end

--- Feed an incoming Introspect call and return the reply message.
local function introspect_call(conn, path)
  conn.buf:feed(message.build({
    type = "method_call", serial = 20,
    path = path, interface = "org.freedesktop.DBus.Introspectable",
    member = "Introspect", sender = ":1.9",
  }))
  conn:pump(0)
  local raw = conn.io:sent()
  return raw and message.parse(raw)
end

describe("ldbus.introspect", function()
  it("generates XML for registered methods and signals", function()
    local conn = new_conn()
    local obj = router.object(conn, "/com/example/Calc")
    router.method(obj, "com.example.Calc.Add", "ii", "i", function() end)
    router.method(obj, "com.example.Calc.Sub", "ii", "", function() end)
    obj.signals = { { member = "Changed", signature = "i" } }

    local xml = introspect.build(conn, "/com/example/Calc")
    assert.truthy(xml:find('<interface name="com%.example%.Calc">'))
    assert.truthy(xml:find('<method name="Add">'))
    -- "ii" becomes two separate arg elements (Add and Sub have two each)
    assert.equals(4, select(2, xml:gsub('<arg direction="in" type="i"/>', {})))
    assert.truthy(xml:find('<arg direction="out" type="i"/>'))
    assert.truthy(xml:find('<method name="Sub">'))
    -- no output signature means no out args, not an empty type
    assert.falsy(xml:find('direction="out" type=""'))
    assert.truthy(xml:find('<signal name="Changed">'))
    assert.truthy(xml:find('<arg type="i"/>'))
    assert.truthy(xml:find("^<!DOCTYPE node"))
    assert.truthy(xml:find("<node>"))
    assert.truthy(xml:find("</node>%s*$"))
  end)

  it("always includes the introspectable and peer built-ins", function()
    local conn = new_conn()
    router.object(conn, "/x")
    local xml = introspect.build(conn, "/x")
    assert.truthy(xml:find('interface name="org%.freedesktop%.DBus%.Introspectable"'))
    assert.truthy(xml:find('<method name="Introspect">'))
    assert.truthy(xml:find('interface name="org%.freedesktop%.DBus%.Peer"'))
    assert.truthy(xml:find('<method name="Ping"/>'))
  end)

  it("lists registered child paths", function()
    local conn = new_conn()
    router.object(conn, "/com/example")
    router.object(conn, "/com/example/Calc")
    router.object(conn, "/com/example/Calc/Advanced")
    local xml = introspect.build(conn, "/com/example")
    assert.truthy(xml:find('<node name="Calc"/>'))
    -- grandchildren are not listed, only direct children
    assert.falsy(xml:find("Advanced"))
  end)

  it("dispatches Introspect calls and replies with the XML", function()
    local conn, io_obj = new_conn()
    local obj = router.object(conn, "/calc")
    router.method(obj, "com.example.Calc.Add", "ii", "i", function() end)
    local reply = introspect_call(conn, "/calc")
    assert.equals("method_return", reply.type_name)
    assert.equals("s", reply.signature)
    assert.truthy(reply.body[1]:find('<method name="Add">'))
  end)

  it("errors on Introspect of an unknown path", function()
    local conn = new_conn()
    local reply = introspect_call(conn, "/nowhere")
    assert.equals("error", reply.type_name)
    assert.equals("org.freedesktop.DBus.Error.UnknownObject", reply.error_name)
  end)
end)
