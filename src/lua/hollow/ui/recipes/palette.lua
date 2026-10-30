local common = require("hollow.ui.recipes.common")
local list_row = require("hollow.ui.recipes.list_row")
local sheet = require("hollow.ui.style.sheet")

return sheet.define("palette", {
  title = common.title,
  counter = common.counter,
  empty = common.empty,
  muted = common.muted,
  key_hint = common.key_hint,
  match = common.key_hint,
  section_title = sheet.merge(common.title, list_row.slots.section_gap),
  -- Active domains override fg with the terminal's green at the call site.
  bullet = { fg = "muted", bold = false },
  label = {
    fg = "fg",
    hovered = { fg = "selected_fg" },
    selected = { fg = "selected_fg" },
  },
  right = { fg = "panel_border|muted" },
})
