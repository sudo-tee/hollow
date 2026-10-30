-- One text node, using the empty-state label tone.
local c = require("hollow.ui.components")
local label = require("hollow.ui.components.label")

return function(value)
  local input = type(value) == "table" and value or { text = value }
  if input._legacy_style then
    return c.text(
      input.text or input[1],
      input.style,
      { wrap = input.wrap, text_align = input.text_align }
    )
  end
  local options = {}
  for key, item in pairs(input) do
    options[key] = item
  end
  options.tone = options.tone or "empty"
  return label(options)
end
