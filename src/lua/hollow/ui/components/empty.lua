-- One text node, using the empty-state label tone.
local label = require("hollow.ui.components.label")
local props = require("hollow.ui.components.props")

return function(value)
  local p = props.text(value)
  p.tone = p.tone or "empty"
  return label(p)
end
