--- Buttons register callbacks declaratively during render.

local fire = require("hollow.ui.builder.fire")

---@class ClickRegistry
local M = {}

---@type table<string, function>
local registry = {}

function M.reset()
  registry = {}
end

---@param id string
---@param callback function
function M.register(id, callback)
  registry[id] = callback
end

---@param id string
---@param value any
function M.dispatch(id, value)
  local fn = registry[id]
  fire.fire(fn, value)
end

---@param id string
---@return function|nil
function M.lookup(id)
  return registry[id]
end

return M
