-- One text node, using the title tone and bold by default.
local label = require("hollow.ui.components.label")
local sheet = require("hollow.ui.style.sheet")

return function(value)
  local input = type(value) == "table" and value or { text = value }
  local p = {}
  for key, item in pairs(input) do
    p[key] = item
  end
  p.tone = p.tone or "title"
  p.style = sheet.merge({ bold = true }, p.style)
  return label(p)
end
