-- Shared props and render scope for component constructors.
local shared = require("hollow.ui.shared")
local M = {}
M.LIST_BUDGET = 410

-- Splits a props table into a fresh props copy and its positional children.
-- With explicit `opts` (the `(children, opts)` form) both are returned as given.
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

-- Text-like components accept a bare value, `{ value }` or `{ [field] = value }`.
function M.text(value, field)
  field = field or "text"
  local options = M.split(type(value) == "table" and value or { [field] = value })
  if options[field] == nil and type(value) == "table" then
    options[field] = value[1]
  end
  return options
end

function M.copy(value)
  local result = {}
  for key, item in pairs(value or {}) do
    result[key] = item
  end
  return result
end

function M.scope()
  return M._scope or { theme = shared.palette("select"), ctx = {} }
end

function M.theme(options)
  return options and options.theme or M.scope().theme
end

function M.ctx(options)
  return options and options.ctx or M.scope().ctx
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
