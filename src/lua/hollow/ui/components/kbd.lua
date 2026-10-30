-- Two nodes: painted container and normalized key text.
local chip = require("hollow.ui.components.chip")
local recipe = require("hollow.ui.recipes.kbd")

return function(value)
  local p = type(value) == "table" and value or { key = value }
  local key = p.key or p[1] or ""
  local keymap = _G.hollow.keymap or {}
  if type(keymap.parse_chord) == "function" and type(keymap.format_chord) == "function" then
    local ok, parsed, mods = pcall(keymap.parse_chord, key)
    if ok then
      key = keymap.format_chord(parsed, mods)
    end
  end
  return chip(recipe, p, key)
end
