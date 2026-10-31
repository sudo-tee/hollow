-- Two shell nodes, plus one when an accent is painted; excludes content nodes.
local box = require("hollow.ui.style.box")
local c = require("hollow.ui.components")
local list_row = require("hollow.ui.recipes.list_row")
local props = require("hollow.ui.components.props")
local shared = require("hollow.ui.shared")
local sheet = require("hollow.ui.style.sheet")

local function gutter(color, radius)
  local inset = box.px(radius, 0)
  local children = {}
  if color and color ~= 0 then
    children[1] = c.column({}, {
      width = 2,
      height = "grow",
      style = { bg = color, radius = inset > 0 and 1 or 0 },
    })
  end
  return c.column(children, {
    width = 2,
    height = "grow",
    padding = { left = 0, right = 0, top = inset, bottom = inset },
  })
end

return function(value)
  local options, children = props.split(value)
  local theme = options.theme or props.scope().theme
  local paint = list_row(theme, options).paint
  local style = options._style
    or {
      bg = paint.fill_bg,
      radius = paint.fill_radius,
      hover = {
        bg = list_row(theme, { selected = options.selected, hovered = true }).paint.fill_bg,
      },
    }
  style = shared.resolve_tokens(sheet.merge(style, options.style), theme)
  local accent = options._accent
  if accent == nil then
    if options.accent == true then
      accent = paint.accent_bar or theme.panel_border
    elseif options.accent ~= nil then
      accent = options.accent
    else
      accent = paint.accent_bar
    end
  end
  if accent then
    accent = shared.resolve_tokens({ bg = accent }, theme).bg
  end
  options.role = options.role or "listitem"
  options.width = options.width or "grow"
  options.style = style
  options.on_click = not options.disabled and (options.on_activate or options.on_click) or nil
  return c.row({ gutter(accent, style.radius), children }, options)
end
