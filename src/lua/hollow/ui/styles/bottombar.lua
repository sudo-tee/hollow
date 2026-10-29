local sheet = require("hollow.ui.style.sheet")

-- Resolved against the special-mode palette built in bars/bottombar.lua.
return sheet.define("bottombar", {
  chip = {
    bold = true,
    radius = 4,
    padding = { left = 2, right = 2, top = 1, bottom = 1 },
    margin = { right = 1 },
    variants = {
      copy = { bg = "copy_bg", fg = "accent" },
      quick_select = { bg = "quick_select_bg", fg = "accent" },
      action = { bg = "chip_bg", fg = "chip_fg" },
      leader = { bg = "leader_bg", fg = "fg" },
    },
  },
  key = { fg = "fg", bg = "hint_key_bg", bold = true, radius = 4, padding = { x = 1, y = 0 } },
  search = { bg = "copy_bg", radius = 4, padding = { x = 2, y = 1 }, margin = { right = 1 } },
  label = { fg = "muted" },
  query = { fg = "chip_fg" },
  -- Special-mode palettes may omit counter; the native text color then applies.
  counter = { fg = "counter" },
  selection = { fg = "accent", bold = true },
})
