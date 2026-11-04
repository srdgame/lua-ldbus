# Development helpers for ldbus.
# LUA_CPATH below is for lua5.4 scripts/examples only; busted picks up
# its own cpath from .busted.

LUACPATH54 = $(HOME)/.lua5.4/lib/?.so;./?.so;/usr/local/lib/lua/5.4/?.so;/usr/lib/x86_64-linux-gnu/lua/5.4/?.so

.PHONY: test test-verbose integration clean

test:
	busted --lua=lua5.4 spec

test-verbose:
	busted --lua=lua5.4 -v spec

integration:
	LUA_CPATH="$(LUACPATH54)" ./integration/run.sh

clean:
	find . -name '*.luac' -delete
	rm -f /tmp/ldbus-test-*.sock
