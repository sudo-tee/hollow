-- Two nodes: painted container and text.
local chip = require("hollow.ui.components.chip")
local props = require("hollow.ui.components.props")
local recipe = require("hollow.ui.recipes.badge")

return function(value)
  local p = props.text(value)
  return chip(recipe, p, p.text, { bg = p.color })
end
