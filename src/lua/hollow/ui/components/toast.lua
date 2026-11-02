-- One panel and one text node. Action text shares the notification's click target.
local c = require("hollow.ui.components")
local props = require("hollow.ui.components.props")
local recipe = require("hollow.ui.recipes.notify")
local shared = require("hollow.ui.shared")
local sheet = require("hollow.ui.style.sheet")

return function(value)
  local options = props.split(value)
  local theme = props.theme(options)
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
  options.theme = theme
  options.inset = options.inset or "modal"
  options.label = options.label or text
  if not options.on_click and options.action then
    options.on_click = options.action.on_click or options.action.fn
  end
  options[1] = c.text(text, style, { wrap = "none" })
  return c.panel(options)
end
