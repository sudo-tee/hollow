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

function M.cell_w(ctx)
  return (ctx and ctx.cell_w) or 8
end

function M.cell_h(ctx)
  return (ctx and ctx.cell_h) or 19
end

function M.unit(value, field, ctx)
  if type(value) ~= "string" then
    return value
  end
  ctx = ctx or {}
  local number, suffix = value:match("^(%d*%.?%d+)(%a+)$")
  assert(number and (suffix == "ch" or suffix == "lh"), "invalid " .. field .. " unit: " .. value)
  return tonumber(number) * (suffix == "ch" and M.cell_w(ctx) or M.cell_h(ctx))
end

return M
