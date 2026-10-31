-- One panel and one text node. Action text shares the notification's click target.
local c = require("hollow.ui.components")
local props = require("hollow.ui.components.props")
local recipe = require("hollow.ui.recipes.notify")
local shared = require("hollow.ui.shared")
local sheet = require("hollow.ui.style.sheet")

return function(options)
  options = options or {}
  local theme = options.theme or props.scope().theme
  local level = options.level or "info"
  local variant = recipe.slots.message.variants[level] and level or nil
  local style = shared.resolve_tokens(
    sheet.merge(recipe(theme, { variant = variant }).message, options.text_style),
    theme
  )
  local text = tostring(options.text or "")
  if options.action and options.action.label then
    text = text .. "  [" .. options.action.label .. "]"
  end
  local root = {}
  for key, value in pairs(options) do
    root[key] = value
  end
  root.theme = theme
  root.inset = root.inset or "modal"
  root.label = root.label or text
  if not root.on_click and options.action then
    root.on_click = options.action.on_click or options.action.fn
  end
  if root.disabled then
    root.on_click = nil
  end
  root[1] = c.text(text, style, { wrap = "none" })
  return c.panel(root)
end
