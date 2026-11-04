# ldbus

A pure Lua 5.4 implementation of the D-Bus wire protocol and client library.
No libdbus, no GDBus, no C bindings — just Lua 5.4's `string.pack`/`unpack`
plus the [lsocket](https://github.com/tomasguerez/lsocket) socket library.

## Features

- **Pure Lua 5.4** wire protocol: marshalling, message framing, SASL auth
- **Little-endian only** (matches every common D-Bus peer)
- Unix domain sockets, including Linux abstract names (`@name`)
- Idiomatic API: export objects, call methods, emit/receive signals,
  own well-known names
- **Coroutine mainloop**: handlers run as coroutine tasks; `bus:call`
  automatically yields while waiting for a reply (with deadlock-safe
  nested/cross-service calls). Without a mainloop, calls block synchronously.
- Built-in `org.freedesktop.DBus.Introspectable` support, XML generated
  from registered methods/signals
- Automatic Lua-error → D-Bus error reply conversion

## Requirements

- Lua 5.4 (`lua5.4`)
- [lsocket](https://luarocks.org/modules/tomas/lsocket) >= 1.4 (the only
  C dependency; provides sockets + `select`)

## Install

With LuaRocks (from this directory):

```sh
luarocks make ldbus-scm-1.rockspec
```

Or manually: copy `src/ldbus` into your `lua/5.4/` package path, and build
lsocket into your cpath, e.g.:

```sh
luarocks install lsocket  # or make && copy lsocket.so to ~/.lua5.4/lib/
```

## Quick start

```lua
local ldbus = require "ldbus"

-- Connect (raises on failure)
local bus = ldbus.session()          -- or ldbus.system() / ldbus.connect(addr)

-- Method call: returns the reply body, or nil + err table on D-Bus error
local id, err = bus:call("org.freedesktop.DBus", "/org/freedesktop/DBus",
                         "org.freedesktop.DBus", "GetId")
print("bus id:", id)

-- Export an object
local obj = bus:object("/com/example/Calc")
obj:method("Add", "ii", "i", function(a, b) return a + b end)
obj:signal("Changed", "i")

-- Own a well-known name
bus:request_name("com.example.Calc", ldbus.flags.DO_NOT_QUEUE)

-- Emit a signal
bus:emit("/com/example/Calc", "com.example.Calc", "Changed",
         { signature = "i", value = 42 })

-- Listen to signals (AddMatch is sent for you)
bus:on_signal("org.freedesktop.DBus", "NameOwnerChanged", function(msg)
  print(msg.interface, msg.member, msg.path, msg.body[1])
end)

-- Run the event loop; inside it, bus:call yields instead of blocking
bus:mainloop{ timeout = 0.1 }
```

See `examples/` for complete runnable scripts:

- `examples/server.lua` — calculator service (`dbus-send`-friendly)
- `examples/call_systemd.lua` — ListUnits on the system bus
- `examples/signal_monitor.lua` — session-bus lifecycle signals

## API summary

| Call | Description |
|------|-------------|
| `ldbus.session()` / `ldbus.system()` / `ldbus.connect(addr)` | Connect and authenticate (Hello included); return `bus` or `nil, err` |
| `bus:call(dest, path, iface, member, args, opts)` | Synchronous (or yielding) call; returns unpacked reply body or `nil, err{name, message}` |
| `bus:call_noreply(dest, path, iface, member, args)` | Fire-and-forget call (NO_REPLY_EXPECTED) |
| `bus:object(path)` | Exported-object handle: `obj:method(member, in_sig, out_sig, fn)`, `obj:signal(member, sig)` |
| `bus:emit(path, iface, member, sig_or_tbl, values)` | Emit a signal |
| `bus:on_signal(iface, member, fn)` | Register a signal handler (member may be `nil` for interface-wide match) |
| `bus:request_name(name, flags)` / `bus:release_name(name)` | Well-known name ownership; returns `ldbus.result.*` |
| `bus:pump(timeout)` / `bus:mainloop{...}` / `bus:quit()` | Event loop control |
| `bus.conn` | Low-level connection (unique_name, pending, send, pump) |
| `ldbus.mainloop(buses, opts)` | Run several buses in one loop (`opts = {timeout, init, ["until"], on_error}`) |
| `ldbus.variant(sig, value)` | Tagged-variant value for marshalling |
| `ldbus.errors.new(name, message)` | Raise a D-Bus error from a handler |

Errors: Lua errors inside method handlers become
`org.freedesktop.DBus.Error.Failed` replies (or the named error if you raise
an `ldbus.errors` object); incoming error replies surface as
`nil, err{name, message}` from `bus:call`.

## Testing

```sh
# Unit tests (mocked sockets, no bus needed)
busted --lua=lua5.4 spec

# Integration tests on a real private bus
./integration/run.sh
```

Integration uses `dbus-run-session`, so it exercises the real protocol stack:
Hello, method dispatch (success / Lua error / UnknownMethod), NO_REPLY_EXPECTED,
introspection XML, signal matching, and nested yielding calls across services.

## Limitations

- Little-endian hosts only (big-endian peers would need the other encoder)
- Unix fd passing (type `h`) is rejected at signature validation
- uint64 values ≥ 2^63 wrap (Lua 5.4 integers are signed 64-bit)
- SASL `EXTERNAL` auth only; other mechanisms (DBUS_COOKIE_SHA1) unsupported
- Single-threaded cooperative mainloop (coroutines, not OS threads)
