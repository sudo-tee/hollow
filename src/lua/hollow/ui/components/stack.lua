-- One container node, excluding children.
local c = require("hollow.ui.components")
local props = require("hollow.ui.components.props")
local sheet = require("hollow.ui.style.sheet")

return function(value)
  local options, children = props.split(value)
  local direction = options.direction or "column"
  assert(direction == "row" or direction == "column", "invalid stack direction")
  if options.divided then
    local theme = options.theme or props.scope().theme
    options.style = sheet.merge({ border = theme.divider }, options.style)
    local widths = {}
    for key, width in pairs(options.border_width or {}) do
      widths[key] = width
    end
    if widths.between_children == nil then
      widths.between_children = 1
    end
    options.border_width = widths
  end
  if options.disabled then
    options.on_click = nil
  end
  return (direction == "row" and c.row or c.column)(children, options)
end
