local sheet = require("hollow.ui.style.sheet")

-- Resolved with `variant` = the notification level; unknown levels use `title`.
return sheet.define("notify", {
  message = {
    fg = "title",
    bold = true,
    variants = {
      info = { fg = "notify_levels.info" },
      success = { fg = "notify_levels.success" },
      warn = { fg = "notify_levels.warn" },
      error = { fg = "notify_levels.error" },
    },
  },
})
