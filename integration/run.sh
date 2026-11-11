#!/bin/sh
# Run integration tests inside a private D-Bus session (dbus-run-session).
# Usage: ./integration/run.sh [test-script ...]
set -e
cd "$(dirname "$0")/.."

LUA=${LUA:-lua5.4}
export LUA_PATH="./src/?.lua;./src/?/init.lua;./?.lua"
export LUA_CPATH="$HOME/.lua5.4/lib/?.so;$LUA_CPATH"

if [ $# -gt 0 ]; then
  SCRIPTS="$*"
else
  SCRIPTS="integration/test_basic.lua integration/test_client_server.lua integration/test_fds.lua integration/test_signals.lua integration/test_mainloop.lua integration/test_bluez.lua"
fi

for script in $SCRIPTS; do
  echo "=== $script"
  dbus-run-session -- "$LUA" "$script"
done
echo "ALL INTEGRATION TESTS PASSED"
