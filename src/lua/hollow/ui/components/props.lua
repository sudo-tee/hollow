-- Shared props and render scope for component constructors.
local shared = require("hollow.ui.shared")
local M = {}

function M.split(value, opts)
  value = value or {}
  if opts ~= nil then
    return opts, value
  end
  local props, children = {}, {}
  for key, item in pairs(value) do
    if type(key) == "number" then
      children[key] = item
    else
      props[key] = item
    end
  end
  return props, children
end

function M.scope()
  return M._scope or { theme = shared.palette("select"), ctx = {} }
end

return M
