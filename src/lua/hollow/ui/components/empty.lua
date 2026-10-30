-- One text node, using the empty-state label tone.
local label = require("hollow.ui.components.label")

return function(value)
  local input = type(value) == "table" and value or { text = value }
  local options = {}
  for key, item in pairs(input) do
    options[key] = item
  end
  options.tone = options.tone or "empty"
  return label(options)
end
