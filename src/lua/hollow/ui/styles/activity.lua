local common = require("hollow.ui.styles.common")
local list_row = require("hollow.ui.styles.list_row")
local sheet = require("hollow.ui.style.sheet")

local PILL_PADDING = { left = 8, right = 8, top = 3, bottom = 3 }
local selected_fg = { fg = "selection_fg" }

-- Entry rows resolve with `variant = "read"` once an entry is acknowledged.
-- State accents, stale ages and workspace pill colors are call-site overrides.
return sheet.define("activity", {
  title = common.title,
  muted = common.muted,
  label = common.label,
  counter = common.counter,
  empty = common.empty,
  success = { fg = "notify_levels.success" },
  row = { fg = "fg", hovered = { fg = "hover_fg" }, selected = selected_fg },
  marker = common.muted,
  primary = {
    fg = "fg",
    bold = true,
    hovered = { fg = "hover_fg" },
    selected = selected_fg,
    variants = {
      read = { fg = "muted", bold = false, hovered = { fg = "muted" }, selected = selected_fg },
    },
  },
  secondary = { fg = "muted", selected = { fg = "selected_muted" } },
  time = { fg = "muted", selected = selected_fg },
  dismiss = { fg = "muted", selected = selected_fg },
  dismiss_gap = { padding = { left = 4, right = 4 } },
  pill = { radius = 4, padding = PILL_PADDING },
  pill_gap = { padding = PILL_PADDING },
  category_arrow = sheet.merge(
    common.muted,
    list_row.slots.section_gap,
    { selected = selected_fg }
  ),
  category_title = sheet.merge(common.title, { selected = selected_fg }),
  category_count = { fg = "counter", selected = selected_fg },
})
