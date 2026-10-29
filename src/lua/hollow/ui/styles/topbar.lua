local sheet = require("hollow.ui.style.sheet")

local levels = {
  info = { fg = "notify_levels.info", bold = true },
  success = { fg = "notify_levels.success", bold = true },
  warn = { fg = "notify_levels.warn", bold = true },
  error = { fg = "notify_levels.error", bold = true },
}

-- Bar items resolve against `shared.bar_palette()`; `attention` resolves
-- against the select palette with `variant` = the pending activity level.
return sheet.define("topbar", {
  divider = { fg = "divider" },
  new_tab = {
    bg = "tab_inactive_bg",
    fg = "tab_inactive_fg",
    radius = 4,
    padding = { left = 5, right = 5, top = 1, bottom = 2 },
    margin = { left = 1 },
    hover = { bg = "tab_hover_bg", fg = "tab_hover_fg" },
  },
  new_tab_shifted = { padding = { left = 2, right = 7 } },
  attention_button = {
    padding = { left = 6, right = 6 },
    margin = { right = 6 },
    radius = 4,
    hover = { bg = "tab_hover_bg" },
  },
  attention = { fg = "muted", bold = false, variants = levels },
})
