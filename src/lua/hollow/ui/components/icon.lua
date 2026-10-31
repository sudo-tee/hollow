-- One text node; glyph names are shared with built-in widgets.
local icons = require("hollow.ui.icons")
local label = require("hollow.ui.components.label")
local props = require("hollow.ui.components.props")

return function(value)
  local p = props.text(value, "name")
  assert(icons[p.name], "unknown icon: " .. tostring(p.name))
  p.text = icons[p.name]
  return label(p)
end
