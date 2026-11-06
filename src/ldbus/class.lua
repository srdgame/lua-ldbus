--- middleclass accessor for all ldbus classes.
-- Prefers an installed copy of middleclass; falls back to the git
-- submodule in this repository.
-- @module ldbus.class

if not pcall(require, "middleclass") then
  package.path = "middleclass/?.lua;" .. package.path
end
return require "middleclass"
