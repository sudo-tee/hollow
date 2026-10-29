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
  pill = { radius = 4, padding = { x = 4 } },
  badge = { fg = "panel_bg", bold = true, radius = 4, padding = { x = 5, y = 1 } },
  kbd = { fg = "fg", bg = "input_bg", radius = 3, padding = { x = 4 } },
}
