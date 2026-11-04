--- org.freedesktop.DBus.Introspectable support: generate the XML
--- description of a registered object (methods, signals, children, and
--- the built-in Introspectable/Peer interfaces).
-- @module ldbus.introspect

local introspect = {}

local INTROSPECTABLE_IFACE = "org.freedesktop.DBus.Introspectable"
local PEER_IFACE = "org.freedesktop.DBus.Peer"

local DOCTYPE = '<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object '
  .. 'Introspection 1.0//EN" '
  .. '"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">'

local function esc(s)
  return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    :gsub('"', "&quot;"))
end

--- XML for one method: <arg direction="in" type="..."/> per complete
--- type in the input signature, one <arg direction="out" type="..."/>
--- per complete type in the output signature.
local function method_xml(name, in_sig, out_sig)
  local parts = { '<method name="' .. esc(name) .. '">' }
  -- split complete types out of a signature string
  local function each_complete(sig, fn)
    local pos = 1
    while pos <= #sig do
      local c = sig:sub(pos, pos)
      local len
      if c == "a" then
        len = 1
        while sig:sub(pos + len, pos + len) == "a" do
          len = len + 1
        end
        if sig:sub(pos + len, pos + len) == "(" then
          local depth = 0
          for i = pos + len, #sig do
            local cc = sig:sub(i, i)
            if cc == "(" then depth = depth + 1 end
            if cc == ")" then
              depth = depth - 1
              if depth == 0 then len = i - pos + 1 break end
            end
          end
        else
          len = len + 1
        end
      elseif c == "(" then
        local depth = 0
        for i = pos, #sig do
          local cc = sig:sub(i, i)
          if cc == "(" then depth = depth + 1 end
          if cc == ")" then
            depth = depth - 1
            if depth == 0 then len = i - pos + 1 break end
          end
        end
      else
        len = 1
      end
      fn(sig:sub(pos, pos + len - 1))
      pos = pos + len
    end
  end

  each_complete(in_sig or "", function(t)
    parts[#parts + 1] = '<arg direction="in" type="' .. t .. '"/>'
  end)
  each_complete(out_sig or "", function(t)
    parts[#parts + 1] = '<arg direction="out" type="' .. t .. '"/>'
  end)
  parts[#parts + 1] = "</method>"
  return table.concat(parts)
end

local function signal_xml(name, sig)
  local parts = { '<signal name="' .. esc(name) .. '">' }
  for t in (sig or ""):gmatch(".") do
    parts[#parts + 1] = '<arg type="' .. t .. '"/>'
  end
  parts[#parts + 1] = "</signal>"
  return table.concat(parts)
end

--- Build the introspection XML for the object at `path`.
-- Methods are grouped by interface when registered as "iface.member";
-- wildcard registrations (plain "member") land in "ldbus.local".
-- Children are registered paths one level below `path`.
function introspect.build(conn, path)
  local obj = conn.objects and conn.objects[path]
  local interfaces = {} -- iface name -> { methods = {...}, signals = {...} }

  local function iface_slot(name)
    local slot = interfaces[name]
    if not slot then
      slot = { methods = {}, signals = {} }
      interfaces[name] = slot
    end
    return slot
  end

  if obj then
    for key, m in pairs(obj.methods) do
      local iface = "ldbus.local"
      local member = key
      local dot = key:match("^([%w_.]+)%.([%w_]+)$")
      if dot then
        iface = key:match("^(.+)%.(%w+)$")
        member = key:match("^.+%.(%w+)$")
      end
      local slot = iface_slot(iface)
      slot.methods[#slot.methods + 1] = method_xml(member, m.in_sig, m.out_sig)
    end
    for _, s in ipairs(obj.signals or {}) do
      iface_slot("ldbus.local").signals[#iface_slot("ldbus.local").signals + 1]
        = signal_xml(s.member, s.signature)
    end
  end

  -- built-ins
  local intro_slot = iface_slot(INTROSPECTABLE_IFACE)
  intro_slot.methods[#intro_slot.methods + 1] =
    method_xml("Introspect", "", "s")
  local peer_slot = iface_slot(PEER_IFACE)
  peer_slot.methods[#peer_slot.methods + 1] = "<method name=\"Ping\"/>"

  local parts = { DOCTYPE, "<node>" }
  local names = {}
  for n in pairs(interfaces) do
    names[#names + 1] = n
  end
  table.sort(names)
  for _, n in ipairs(names) do
    local slot = interfaces[n]
    parts[#parts + 1] = '<interface name="' .. esc(n) .. '">'
    for _, mx in ipairs(slot.methods) do
      parts[#parts + 1] = mx
    end
    for _, sx in ipairs(slot.signals) do
      parts[#parts + 1] = sx
    end
    parts[#parts + 1] = "</interface>"
  end

  -- direct children among registered paths
  local prefix = (path == "/" and "" or path) .. "/"
  local children = {}
  for p in pairs(conn.objects or {}) do
    if p:sub(1, #prefix) == prefix then
      local rest = p:sub(#prefix + 1)
      if not rest:find("/") then
        children[#children + 1] = rest
      end
    end
  end
  table.sort(children)
  for _, c in ipairs(children) do
    parts[#parts + 1] = '<node name="' .. esc(c) .. '"/>'
  end

  parts[#parts + 1] = "</node>"
  return table.concat(parts, "\n") .. "\n"
end

--- Answer an incoming Introspect call. Returns message.build opts,
--- or nil (not an introspect call / unknown object) to let the caller
--- continue with normal method dispatch.
function introspect.reply(conn, msg)
  if msg.interface ~= INTROSPECTABLE_IFACE or msg.member ~= "Introspect" then
    return nil
  end
  if not (conn.objects and conn.objects[msg.path]) then
    return nil
  end
  return {
    type = "method_return",
    reply_serial = msg.serial,
    destination = msg.sender,
    signature = "s",
    body = { introspect.build(conn, msg.path) },
  }
end

return introspect
