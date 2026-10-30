-- One viewport node, excluding children. Scrollbar metadata is native paint.
local box = require("hollow.ui.style.box")
local c = require("hollow.ui.components")
local list_row = require("hollow.ui.recipes.list_row")
local props = require("hollow.ui.components.props")

local function padding_right(value, ctx)
  if value == nil then
    return 0
  end
  if type(value) == "string" then
    local number, unit = value:match("^(%d*%.?%d+)(%a+)$")
    assert(number and (unit == "ch" or unit == "lh"), "invalid padding.right unit: " .. value)
    return tonumber(number) * (unit == "ch" and (ctx.cell_w or 8) or (ctx.cell_h or 19))
  end
  assert(type(value) == "number" and value >= 0, "invalid padding.right")
  return value
end

return function(value)
  local options, children = props.split(value)
  assert(type(options.id) == "string" and options.id ~= "", "scroll requires an id")
  local axis = options.axis or "y"
  assert(axis == "x" or axis == "y" or axis == "both", "invalid scroll axis")
  options.scroll, options.scroll_x = axis ~= "x", axis ~= "y"
  if options.scrollbar then
    local bar = options.scrollbar
    assert(
      type(bar) == "table" and type(bar.id) == "string" and bar.id ~= "",
      "scrollbar requires an id"
    )
    local scope = props.scope()
    local paint = list_row(options.theme or scope.theme).paint
    options.scrollbar_id = bar.id
    options.scrollbar_thumb_ratio = bar.ratio
    options.scrollbar_thumb_size = bar.size
    options.scrollbar_track_color = paint.scrollbar_track_color
    options.scrollbar_thumb_color = paint.scrollbar_thumb_color
    local padding = options.padding
    if padding == nil and type(options.style) == "table" then
      padding = options.style.padding
    end
    if type(padding) == "string" then
      padding = { top = padding, right = padding, bottom = padding, left = padding }
    else
      padding = box.parse(padding) or {}
    end
    -- Box shorthand mirrors right onto left; capture that before adding the gutter.
    padding.left = padding.left or padding.right or padding.top or 0
    local right = padding_right(padding.right or padding.top, scope.ctx)
    padding.right = right + math.max(8, scope.ctx.cell_w or 8)
    options.padding = padding
  end
  if options.disabled then
    options.on_click = nil
  end
  return c.column(children, options)
end
