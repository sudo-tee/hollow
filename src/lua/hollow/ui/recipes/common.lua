-- Shared style presets, exposed publicly as `hollow.ui.styles`. Values are
-- palette tokens. Treat as immutable; derive with `ui.style(preset, ...)`.

---@type HollowUiStylePresets
return {
  muted = { fg = "muted" },
  title = { fg = "title", bold = true },
  label = { fg = "title" },
  empty = { fg = "empty" },
  counter = { fg = "counter" },
  key_hint = { fg = "panel_border", bold = true },
  pill = require("hollow.ui.recipes.pill").slots.root,
  badge = require("hollow.ui.recipes.badge").slots.root,
  kbd = require("hollow.ui.recipes.kbd").slots.root,
}
