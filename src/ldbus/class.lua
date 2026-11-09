--- middleclass accessor for all ldbus classes.
-- Prefers an installed copy of middleclass; falls back to the git
-- submodule in this repository.
--
-- middleclass v4.1 usage rules observed by this codebase (violations
-- fail silently or collide, so keep them in mind when adding code):
--
-- * Instantiate with `Class(args)`; declare instance methods with
--   `function Class:method()` (routes through the class __newindex).
-- * Static functions must be `function Class.static.fn()`; a plain
--   `function Class.fn()` becomes an instance method.
-- * Instance methods named `name`, `super`, `static` or `subclasses`
--   SILENTLY fail: those keys exist raw on the class table, so the
--   class __newindex never fires (use display_name etc.).
-- * Instance fields shadow instance methods by lookup name — keep
--   private fields underscore-prefixed (e.g. `_path` + `path()`).
-- * All middleclass instances stringify identically ("instance of
--   class X") — never use tostring(instance) as a table key.
-- * Declaring `__index`/`__newindex`/`__tostring` as instance methods
--   works: real methods win first, unknown keys fall through.
--
-- @module ldbus.class

if not pcall(require, "middleclass") then
  package.path = "middleclass/?.lua;" .. package.path
end
return require "middleclass"
