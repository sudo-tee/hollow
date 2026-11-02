-- One text node, using the title tone and bold by default.
local label = require("hollow.ui.components.label")
local props = require("hollow.ui.components.props")
local sheet = require("hollow.ui.style.sheet")

return function(value)
  local p = props.text(value)
  p.tone = p.tone or "title"
  p.style = sheet.merge({ bold = true }, p.style)
  return label(p)
end
