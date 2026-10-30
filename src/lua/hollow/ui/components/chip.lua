-- Shared structure for background-bearing atoms: one container and one text node.
local c = require("hollow.ui.components")
local props = require("hollow.ui.components.props")
local sheet = require("hollow.ui.style.sheet")

return function(recipe, p, text, overrides)
  local theme = p.theme or props.scope().theme
  local style = sheet.merge(recipe(theme, p).root, overrides, p.style)
  local root = {}
  for key, value in pairs(p) do
    root[key] = value
  end
  root.style = style
  if p.disabled then
    root.on_click = nil
  end
  return c.column(
    { c.text(text, { fg = style.fg, bold = style.bold }, { wrap = p.wrap or "none" }) },
    root
  )
end
