--- D-Bus error names and Lua-side error representation.
-- A D-Bus error reply maps to a DBusError table; a Lua error raised
-- inside a handler maps back to an error reply.
-- @module ldbus.errors

local middleclass = require "ldbus.class"

local errors = {}

errors.FAILED = "org.freedesktop.DBus.Error.Failed"
errors.UNKNOWN_METHOD = "org.freedesktop.DBus.Error.UnknownMethod"
errors.UNKNOWN_OBJECT = "org.freedesktop.DBus.Error.UnknownObject"
errors.UNKNOWN_INTERFACE = "org.freedesktop.DBus.Error.UnknownInterface"
errors.INVALID_ARGS = "org.freedesktop.DBus.Error.InvalidArgs"
errors.NAME_HAS_NO_OWNER = "org.freedesktop.DBus.Error.NameHasNoOwner"
errors.ACCESS_DENIED = "org.freedesktop.DBus.Error.AccessDenied"
errors.TIMEOUT = "org.freedesktop.DBus.Error.Timeout"

local DBusError = middleclass("DBusError")

function DBusError:initialize(err_name, msg)
  self.name = err_name or errors.FAILED
  self.message = msg or ""
end

function DBusError:__tostring()
  return self.name .. ": " .. self.message
end

--- Create a DBusError value (throw it with error() from handlers).
function errors.new(err_name, msg)
  return DBusError(err_name, msg)
end

--- Check whether a value is a DBusError.
function errors.is(v)
  return type(v) == "table" and v.isInstanceOf ~= nil
    and v:isInstanceOf(DBusError)
end

--- Build a DBusError from a parsed ERROR message (msg.body must be decoded).
function errors.from_message(msg)
  local text = ""
  if msg.body and type(msg.body[1]) == "string" then
    text = msg.body[1]
  end
  return errors.new(msg.error_name, text)
end

--- Build message.build() opts for an error reply to an incoming call.
-- flags carries NO_REPLY_EXPECTED so callers pumping later don't stall.
function errors.reply_opts(call, err_name, msg)
  return {
    type = "error",
    reply_serial = call.serial,
    destination = call.sender,
    error_name = err_name,
    signature = "s",
    body = { msg },
    flags = 1, -- NO_REPLY_EXPECTED
  }
end

return errors
