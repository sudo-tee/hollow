-- One text node; no wrapper is needed for foreground and bold paint.
local c = require("hollow.ui.components")
local props = require("hollow.ui.components.props")
local recipe = require("hollow.ui.recipes.label")
local sheet = require("hollow.ui.style.sheet")

return function(value)
  local p = type(value) == "table" and value or { text = value }
  local theme = p.theme or props.scope().theme
  local style = recipe(theme, { variant = p.tone or "default" }).root
  return c.text(p.text or p[1], sheet.merge(style, p.style), {
    wrap = p.wrap or "none",
    text_align = p.text_align,
  })
end
