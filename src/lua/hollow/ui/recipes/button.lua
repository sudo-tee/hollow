local sheet = require("hollow.ui.style.sheet")

local hover = { fg = "hover_fg", bg = "hover_bg" }

return sheet.define("button", {
  root = {
    fg = "fg",
    radius = 4,
    padding = { left = 4, right = 4 },
    hover = hover,
    hovered = hover,
    selected = hover,
    disabled = { fg = "muted|fg", hover = false },
    variants = {
      default = {},
      ghost = {},
      primary = { fg = "primary_fg", bg = "primary_bg" },
      destructive = { fg = "destructive_fg", bg = "destructive_bg" },
    },
    sizes = {
      sm = { padding = { x = 6, y = 2 } },
      md = { padding = { x = 8, y = 3 } },
    },
  },
  -- Dialog buttons stay text-colored until emphasized by selection or hover.
  dialog = {
    fg = "fg",
    radius = 4,
    hovered = { fg = "selected_fg", bg = "button_emphasis_bg", bold = true },
    selected = { fg = "selected_fg", bg = "button_emphasis_bg", bold = true },
    variants = {
      default = {},
      primary = {
        fg = "primary_bg",
        hovered = { fg = "primary_fg", bg = "primary_bg" },
        selected = { fg = "primary_fg", bg = "primary_bg" },
      },
      destructive = {
        fg = "destructive_bg",
        hovered = { fg = "destructive_fg", bg = "destructive_bg" },
        selected = { fg = "destructive_fg", bg = "destructive_bg" },
      },
    },
  },
})
