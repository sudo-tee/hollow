local sheet = require("hollow.ui.style.sheet")

return sheet.define("tab", {
  root = {
    fg = "muted",
    bold = false,
    radius = 4,
    padding = { x = 8, y = 3 },
    selected = { fg = "selection_fg", bg = "selection_bg", bold = true },
    variants = {
      -- The count badge sits flush against the label and shares its fill.
      badged = { padding = { right = 0 }, selected = { background_extend = 2 } },
    },
  },
})
