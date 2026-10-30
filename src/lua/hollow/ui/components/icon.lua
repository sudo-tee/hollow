-- One text node; glyph names are shared with built-in widgets.
local icons = require("hollow.ui.icons")
local label = require("hollow.ui.components.label")

return function(value)
  local input = type(value) == "table" and value or { name = value }
  local p = {}
  for key, item in pairs(input) do
    p[key] = item
  end
  assert(icons[p.name], "unknown icon: " .. tostring(p.name))
  p.text = icons[p.name]
  return label(p)
end
