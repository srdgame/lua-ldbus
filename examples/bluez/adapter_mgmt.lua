--- bluez.adapter_mgmt: adapter management helpers on top of the bluez core
-- and GATT server modules. Extends Adapter with the org.bluez.Adapter1
-- administrative properties (name, power, discoverability, pairing window,
-- discovery filters) and a one-call LE advertising toggle:
--
--   local bluez = require "bluez"   -- loads adapter_mgmt automatically
--   local bt = bluez.new()
--   local adapter = bt:default_adapter()
--   adapter:set_powered(true)
--   adapter:set_name("MyBox")
--   adapter:set_discoverable(true, 30)     -- visible for 30 s windows
--   local adv = adapter:start_advertising{ local_name = "MyBox",
--     service_uuids = { "180f" }, min_interval = 100, max_interval = 200 }
--   adv:update{ LocalName = "Renamed" }    -- runtime parameter change
--   adapter:stop_advertising()
--
-- @module bluez.adapter_mgmt

local bluez = require "bluez"

local Adapter = bluez.Adapter

--------------------------------------------------------------------------------
-- Adapter1 administrative properties
--------------------------------------------------------------------------------

--- True when the adapter is powered on.
function Adapter:is_powered()
  return self:get_prop("Powered") == true
end

--- Power the adapter on/off.
function Adapter:set_powered(on)
  return self:set_prop("Powered", on and true or false)
end

--- Set the adapter's human-friendly name (Alias property).
function Adapter:set_name(alias)
  return self:set_prop("Alias", alias)
end

--- Current display name: Alias, then Name. (Named `display_name` because
-- `name` collides with middleclass's internal class-name attribute.)
function Adapter:display_name()
  return self:get_prop("Alias") or self:get_prop("Name")
end

--- Enable/disable discoverability. `timeout` is the visibility window in
-- seconds (0 = always discoverable); omit it to leave the timeout unchanged.
function Adapter:set_discoverable(on, timeout)
  local ok, err = self:set_prop("Discoverable", on and true or false)
  if not ok then
    return nil, err
  end
  if timeout ~= nil then
    ok, err = self:set_prop("DiscoverableTimeout", timeout)
    if not ok then
      return nil, err
    end
  end
  return true
end

--- Enable/disable pairability. `timeout` is the pairable window in
-- seconds (0 = always pairable); omit it to leave the timeout unchanged.
function Adapter:set_pairable(on, timeout)
  local ok, err = self:set_prop("Pairable", on and true or false)
  if not ok then
    return nil, err
  end
  if timeout ~= nil then
    ok, err = self:set_prop("PairableTimeout", timeout)
    if not ok then
      return nil, err
    end
  end
  return true
end

--- The currently active discovery filters (org.bluez.Adapter1
-- .GetDiscoveryFilters). Returns a list, or nil + err.
function Adapter:get_discovery_filters()
  local values, err = self:call("GetDiscoveryFilters")
  if not values then
    return nil, err
  end
  return values[1]
end

--------------------------------------------------------------------------------
-- LE advertising toggle (uses bluez.Advertisement from bluez.gatt_server)
--------------------------------------------------------------------------------

--- Create and register an LE advertisement on this adapter in one call.
-- `opts` is passed straight to bluez.Advertisement (local_name,
-- service_uuids, includes, min_interval/max_interval, ...). Calling it
-- again while advertising returns the existing handle unchanged.
-- Requires a running mainloop while registered.
function Adapter:start_advertising(opts)
  local bt = self._bt
  bt._advertisements = bt._advertisements or {}
  local existing = bt._advertisements[self._path]
  if existing then
    return existing
  end
  if not bluez.Advertisement then
    return nil, { name = "org.bluez.Error.NotSupported",
                  message = "bluez.gatt_server not available" }
  end
  local path = self._path .. "/lua_adv"
  local adv = bluez.Advertisement(bt, path, opts)
  local ok, err = adv:register(self)
  if not ok then
    return nil, err
  end
  bt._advertisements[self._path] = adv
  return adv
end

--- Unregister the advertisement started with :start_advertising.
-- Returns true, or nil + err (including when not currently advertising).
function Adapter:stop_advertising()
  local advs = self._bt._advertisements
  local adv = advs and advs[self._path]
  if not adv then
    return nil, { name = "org.bluez.Error.DoesNotExist",
                  message = "no active advertisement for " .. self._path }
  end
  local ok, err = adv:unregister(self)
  if not ok then
    return nil, err
  end
  advs[self._path] = nil
  return true
end

return true
