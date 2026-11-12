package = "ldbus"
version = "scm-1"

source = {
  url = "git://github.com/example/lua-ldbus.git",
}

description = {
  summary = "Pure Lua 5.4 D-Bus client library",
  detailed = [[
    A D-Bus implementation in pure Lua 5.4: wire protocol marshalling,
    SASL EXTERNAL authentication, message framing, exported objects,
    signals, name ownership, and a coroutine-based mainloop.
    Uses lsocket for socket I/O; no libdbus or other C bindings.
    lsocket is not distributed on LuaRocks -- build it from source
    (https://github.com/srdgame/lsocket.git) and put lsocket.so on your
    cpath before using this rock.
  ]],
  homepage = "https://github.com/example/lua-ldbus",
  license = "MIT",
}

dependencies = {
  "lua >= 5.4, < 5.5",
  "middleclass >= 4.1",
}

build = {
  type = "builtin",
  modules = {
    ["ldbus"]            = "src/ldbus/init.lua",
    ["ldbus.address"]    = "src/ldbus/address.lua",
    ["ldbus.auth"]       = "src/ldbus/auth.lua",
    ["ldbus.buffer"]     = "src/ldbus/buffer.lua",
    ["ldbus.connection"] = "src/ldbus/connection.lua",
    ["ldbus.errors"]     = "src/ldbus/errors.lua",
    ["ldbus.introspect"] = "src/ldbus/introspect.lua",
    ["ldbus.mainloop"]   = "src/ldbus/mainloop.lua",
    ["ldbus.marshal"]    = "src/ldbus/marshal.lua",
    ["ldbus.message"]    = "src/ldbus/message.lua",
    ["ldbus.name"]       = "src/ldbus/name.lua",
    ["ldbus.router"]     = "src/ldbus/router.lua",
    ["ldbus.scheduler"]  = "src/ldbus/scheduler.lua",
    ["ldbus.signature"]  = "src/ldbus/signature.lua",
    ["ldbus.socketio"]   = "src/ldbus/socketio.lua",
    ["ldbus.types"]      = "src/ldbus/types.lua",
    ["ldbus.uid"]        = "src/ldbus/uid.lua",
  },
}
