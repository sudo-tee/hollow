local common = require("hollow.ui.styles.common")
local sheet = require("hollow.ui.style.sheet")

-- Rows resolve with `variant = row.kind` ("workspace", "tab" or "pane").
-- Attention, focus and program status colors are dynamic call-site overrides.
return sheet.define("mux_navigator", {
  title = common.title,
  muted = common.muted,
  empty = common.empty,
  subtle = { fg = "subtle" },
  filter = { fg = "muted" },
  filter_bell = { fg = "notify_levels.warn" },
  prefix = {
    fg = "title",
    bold = false,
    hovered = { fg = "title" },
    selected = { fg = "selected_fg", bold = true },
    variants = { workspace = { bold = true }, tab = {}, pane = { fg = "muted" } },
  },
  marker = {
    fg = "title",
    bold = false,
    hovered = { fg = "title" },
    selected = { fg = "selected_fg" },
    variants = {
      workspace = {},
      tab = {},
      pane = { fg = "muted", hovered = { fg = "muted" }, selected = { fg = "muted" } },
    },
  },
  status = { bold = true },
  value = {
    fg = "fg",
    bold = false,
    hovered = { fg = "hover_fg" },
    selected = { fg = "selected_fg", bold = true },
    variants = { workspace = {}, tab = {}, pane = { fg = "notify_levels.success" } },
  },
})
