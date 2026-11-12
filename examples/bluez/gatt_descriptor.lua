--- bluez.gatt_descriptor: locally exported org.bluez.GattDescriptor1
-- objects, attached to characteristics via
-- LocalCharacteristic:descriptor(). ReadValue/WriteValue run the
-- descriptor-level (or application-level) on_authorize callback first,
-- then hand the handler a plain unwrapped options table.
--
-- @module bluez.gatt_descriptor

local ldbus = require "ldbus"
local bluez = require "bluez"

-- middleclass: same lookup strategy as the core module.
if not pcall(require, "middleclass") then
  package.path = "middleclass/?.lua;" .. package.path
end
local middleclass = require "middleclass"

local common = require "bluez.gatt_common"

local to_bytes = bluez.to_bytes
local from_bytes = bluez.from_bytes

--------------------------------------------------------------------------------
-- LocalDescriptor: one exported org.bluez.GattDescriptor1 object
--------------------------------------------------------------------------------

local LocalDescriptor = middleclass("LocalDescriptor")

function LocalDescriptor:initialize(char, uuid, path, flags, handlers)
  handlers = handlers or {}
  self.char = char
  self.uuid = uuid
  self._path = path
  self.flags = flags or {}
  self.on_read = handlers.on_read
  self.on_write = handlers.on_write
  self.on_authorize = handlers.on_authorize
  self._value = handlers.value

  local obj = char.service.app.bt.bus:object(path)

  common.export_properties(obj,
    function(name) return self:_prop(name) end,
    function() return self:_props() end)

  obj:method(common.GATT_DESC_IFACE .. ".ReadValue", "a{sv}", "ay",
    function(opts)
      local unwrapped = common.unwrap_opts(opts, char.service.app.bt)
      common.authorize(self, "read", unwrapped)
      if self.on_read then
        return to_bytes(self.on_read(unwrapped))
      end
      if self._value ~= nil then
        return to_bytes(self._value)
      end
      error("reading not supported")
    end)

  obj:method(common.GATT_DESC_IFACE .. ".WriteValue", "aya{sv}", "",
    function(bytes, opts)
      local unwrapped = common.unwrap_opts(opts, char.service.app.bt)
      common.authorize(self, "write", unwrapped)
      local value = from_bytes(bytes)
      -- run on_write before caching so a raising (rejecting) on_write
      -- leaves the cached value untouched
      if self.on_write then
        self.on_write(value, unwrapped)
      end
      self._value = value
    end)
end

--- The D-Bus object path of this descriptor.
function LocalDescriptor:path()
  return self._path
end

local BASE_PROPS = { UUID = "s", Characteristic = "o", Flags = "as" }

function LocalDescriptor:_prop(name)
  local kind = BASE_PROPS[name]
  if kind then
    return ldbus.variant(kind, name == "Flags" and self.flags
      or name == "UUID" and self.uuid or self.char._path)
  end
  if name == "Value" and self._value ~= nil then
    return ldbus.variant("ay", to_bytes(self._value))
  end
  return nil
end

function LocalDescriptor:_props()
  local out = {}
  for name in pairs(BASE_PROPS) do
    out[name] = self:_prop(name)
  end
  if self._value ~= nil then
    out.Value = ldbus.variant("ay", to_bytes(self._value))
  end
  return out
end

bluez.LocalDescriptor = LocalDescriptor

return true
