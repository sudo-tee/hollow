local sheet = require("hollow.ui.style.sheet")

return sheet.define("label", {
  root = {
    fg = "fg",
    variants = {
      default = {},
      muted = { fg = "muted" },
      title = { fg = "title" },
      empty = { fg = "empty" },
      counter = { fg = "counter" },
    },
  },
})
