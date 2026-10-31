-- Shared structure for background-bearing atoms: one container and one text node.
local c = require("hollow.ui.components")
local props = require("hollow.ui.components.props")
local shared = require("hollow.ui.shared")
local sheet = require("hollow.ui.style.sheet")

return function(recipe, p, text, overrides)
  local theme = props.theme(p)
  p.style = shared.resolve_tokens(sheet.merge(recipe(theme, p).root, overrides, p.style), theme)
  return c.column({
    c.text(text, { fg = p.style.fg, bold = p.style.bold }, { wrap = p.wrap or "none" }),
  }, p)
end
