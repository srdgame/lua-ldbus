--- Bus name acquisition: org.freedesktop.DBus.RequestName.
-- @module ldbus.name

local name = {}

name.FLAG = {
  ALLOW_REPLACEMENT = 1, -- others may take over the name
  REPLACE_EXISTING = 2,  -- take over if current owner allows replacement
  DO_NOT_QUEUE = 4,      -- fail instead of queueing if taken
}

name.RESULT = {
  PRIMARY_OWNER = 1,
  IN_QUEUE = 2,
  EXISTS = 3,
}

--- AddMatch rule string matching signals on an interface (+ optional member).
function name.match_signal(iface, member)
  local rule = "type='signal',interface='" .. iface .. "'"
  if member then
    rule = rule .. ",member='" .. member .. "'"
  end
  return rule
end

return name
