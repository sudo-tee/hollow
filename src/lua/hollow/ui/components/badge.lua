-- Two nodes: painted container and text.
local chip = require("hollow.ui.components.chip")
local recipe = require("hollow.ui.recipes.badge")

return function(value)
  local p = type(value) == "table" and value or { text = value }
  return chip(recipe, p, p.text or p[1], { bg = p.color })
end
