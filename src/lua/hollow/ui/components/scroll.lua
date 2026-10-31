-- One viewport node, excluding children. Scrollbar metadata is native paint.
local box = require("hollow.ui.style.box")
local c = require("hollow.ui.components")
local list_row = require("hollow.ui.recipes.list_row")
local props = require("hollow.ui.components.props")
local shared = require("hollow.ui.shared")

local function padding_right(value, ctx)
  if value == nil then
    return 0
  end
  if type(value) == "string" then
    return props.unit(value, "padding.right", ctx)
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
    local ctx, theme = props.ctx(options), props.theme(options)
    local paint = options._legacy_paint
        and shared.serialize_row_paint({ scrollbar_track = true }, theme)
      or list_row(theme).paint
    options.scrollbar_id = bar.id
    options.scrollbar_thumb_ratio = bar.ratio
    options.scrollbar_thumb_size = bar.size
    if bar._raw_colors then
      options.scrollbar_track_color = bar.track_color
      options.scrollbar_thumb_color = bar.thumb_color
    else
      options.scrollbar_track_color = bar.track_color or paint.scrollbar_track_color
      options.scrollbar_thumb_color = bar.thumb_color or paint.scrollbar_thumb_color
    end
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
    local right = padding_right(padding.right or padding.top, ctx)
    padding.right = right + math.max(8, props.cell_w(ctx))
    options.padding = padding
  end
  if options.theme and options.style then
    options.style = shared.resolve_tokens(options.style, options.theme)
  end
  return c.column(children, options)
end
