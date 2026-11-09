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

- `examples/bluez/` — org.bluez (Bluetooth) wrapper library: adapters,
  devices, discovery, properties as plain field access, signal-fed cache,
  GATT client + server, and LE advertisements (see below)
- `examples/bluetooth_scan.lua` — scan and list nearby LE devices
- `examples/gatt_server_demo.lua` — GATT server (peripheral): counter
  service, LE advertising with tunable parameters, notifications, and
  runtime advertising-parameter changes
- `examples/gatt_client_demo.lua` — GATT client (central): locate/connect,
  dump the GATT hierarchy, read the battery, subscribe to notifications
- `examples/server.lua` — calculator service (`dbus-send`-friendly)
- `examples/call_systemd.lua` — ListUnits on the system bus
- `examples/signal_monitor.lua` — session-bus lifecycle signals

## Bluetooth (org.bluez)

`require "bluez"` (from `examples/`) wraps the BlueZ D-Bus API. The cache is
kept fresh by ObjectManager/Properties signals, so enumeration never does I/O.

```lua
local bluez = require "bluez"
local bt = bluez.new()
local adapter = bt:default_adapter()
adapter:set_prop("Powered", true)            -- property Set
adapter:set_discovery_filter{ Transport = "le" }
adapter:start_discovery()
-- ... run a mainloop to receive signals ...
for _, dev in ipairs(bt:devices()) do
  print(dev:label(), dev:get_prop("RSSI"))   -- property Get from the cache
end
```

### Adapter property accessors and advertising

```lua
adapter:set_powered(true)
adapter:set_name("MyBox")                    -- Alias property
print(adapter:display_name())
adapter:set_discoverable(true, 30)           -- visible, 30 s windows
adapter:set_pairable(true)
print(adapter:get_discovery_filters()[1])

-- one-call LE advertising (creates + registers an LEAdvertisement1)
local adv = adapter:start_advertising{
  local_name = "MyBox",
  service_uuids = { "180f" },
  min_interval = 100, max_interval = 200,    -- ms (BlueZ >= 5.64)
}
adv:update{ LocalName = "Renamed" }          -- runtime parameter change
adapter:stop_advertising()
```

### GATT client (`bluez.gatt_client`, loaded automatically)

```lua
local svc = bt:find_service("180f")            -- short SIG UUIDs are expanded
local bat = bt:find_characteristic("2a19", svc)
local v = bat:read_value()                     -- ReadValue -> Lua string
bat:write_value("\42")                         -- WriteValue
local unsub = bat:subscribe(function(value)    -- StartNotify + listener
  print("value:", value)
end)
-- ... mainloop ...
unsub()
```

### GATT server + LE advertisement (`bluez.gatt_server`, loaded automatically)

Exports local GATT objects on your connection and registers them with
bluetoothd (`GattManager1` / `LEAdvertisingManager1`). A mainloop must be
running while registered — bluetoothd calls back into the exported objects.

```lua
local app = bluez.Application(bt, "/com/example/gatt")
local svc = app:service("180f")
local bat = svc:characteristic("2a19", { "read", "write", "notify" }, {
  value = "\42",                              -- cached value
  on_read  = function(opts) return "\42" end, -- optional dynamic value
  on_write = function(value, opts) ... end,
})
app:register(bt:default_adapter())

local adv = bluez.Advertisement(bt, "/com/example/adv", {
  local_name = "MyDevice",
  service_uuids = { "180f" },
  includes = { "tx-power" },               -- never combine "local-name"
  discoverable = true,                     -- with local_name (BlueZ rejects)
  discoverable_timeout = 30,               -- seconds, uint16 (BlueZ >= 5.54)
  appearance = 962,                        -- uint16 (BlueZ >= 5.55)
  duration = 4, timeout = 60,              -- seconds, uint16 (BlueZ >= 5.63)
  min_interval = 100, max_interval = 200,  -- ms, uint32 (BlueZ >= 5.64);
                                           -- min must be <= max
  manufacturer_data = { [0x0059] = "\1\2" }, -- a{qv}: uint16 id -> bytes
})
adv:register(bt:default_adapter())
adv:update{ LocalName = "Renamed" }        -- runtime parameter change;
                                           -- uint16 properties need an
                                           -- explicit variant:
adv:update{ DiscoverableTimeout = ldbus.variant("q", 0) }

bat:notify("\43")   -- push a new value to subscribed centrals
```

## API summary

| Call | Description |
|------|-------------|
| `ldbus.session()` / `ldbus.system()` / `ldbus.connect(addr)` | Connect and authenticate (Hello included); return `bus` or `nil, err` |
| `bus:call(dest, path, iface, member, args, opts)` | Synchronous (or yielding) call; returns unpacked reply body or `nil, err{name, message}` |
| `bus:call_noreply(dest, path, iface, member, args)` | Fire-and-forget call (NO_REPLY_EXPECTED) |
| `bus:object(path)` | Exported-object handle: `obj:method(member, in_sig, out_sig, fn)`, `obj:signal(member, sig)` |
| `bus:emit(path, iface, member, sig_or_tbl, values)` | Emit a signal |
| `bus:on_signal(iface, member, fn)` | Register a signal handler (member may be `nil` for interface-wide match) |
| `bus:off_signal(iface, member, fn)` | Remove a previously registered handler (local only; no RemoveMatch is sent) |
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
