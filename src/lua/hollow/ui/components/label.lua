-- One text node; no wrapper is needed for foreground and bold paint.
local c = require("hollow.ui.components")
local props = require("hollow.ui.components.props")
local recipe = require("hollow.ui.recipes.label")
local shared = require("hollow.ui.shared")
local sheet = require("hollow.ui.style.sheet")

return function(value)
  local p = props.text(value)
  local theme = props.theme(p)
  local style = recipe(theme, { variant = p.tone or "default" }).root
  return c.text(p.text, shared.resolve_tokens(sheet.merge(style, p.style), theme), {
    wrap = p.wrap or "none",
    text_align = p.text_align,
  })
end
