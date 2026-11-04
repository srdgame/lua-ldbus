--- Current uid lookup (for SASL EXTERNAL auth).
-- @module ldbus.uid

local uid = {}

--- Read the real uid from /proc/self/status.
-- Returns number, or nil + error message.
function uid.current_uid(read_status)
  local f
  if read_status then
    f = read_status()
  else
    f = io.open("/proc/self/status", "r")
  end
  if not f then
    return nil, "cannot read /proc/self/status"
  end
  local found
  for line in f:lines() do
    local u = line:match("^Uid:%s+(%d+)")
    if u then
      found = tonumber(u)
      break
    end
  end
  f:close()
  if not found then
    return nil, "no Uid entry in /proc/self/status"
  end
  return found
end

--- Hex-encode a byte string ("1000" -> "31303030").
function uid.hex_encode(s)
  return (s:gsub(".", function(c)
    return ("%02x"):format(c:byte())
  end))
end

--- The SASL EXTERNAL identity for uid `n`: hex-encoded ASCII of the
-- decimal uid string, as D-Bus requires.
function uid.external_identity(n)
  return uid.hex_encode(tostring(n))
end

return uid
