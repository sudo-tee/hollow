local sheet = require("hollow.ui.style.sheet")

-- Resolved against the switcher's derived terminal palette (fg, muted, subtle,
-- open, user, bell, bell_error), with `variant` = "active", "open" or "known".
-- Attention, program status and workspace hash colors are call-site overrides.
local states = { active = {}, open = {}, known = {} }

return sheet.define("workspace", {
  status = {
    fg = "subtle",
    bold = false,
    variants = sheet.merge(states, { active = { fg = "open", bold = true } }),
  },
  gap = { fg = "subtle" },
  name = {
    fg = "muted",
    bold = false,
    variants = sheet.merge(states, {
      active = { fg = "open", bold = true },
      open = { fg = "user" },
    }),
  },
  badge = { bold = true },
  cwd = { fg = "subtle", bold = false },
  domain_pill = { radius = 4 },
})
