local common = require("hollow.ui.styles.common")
local list_row = require("hollow.ui.styles.list_row")
local sheet = require("hollow.ui.style.sheet")

local detail = {
  fg = "detail",
  hovered = { fg = "selected_muted" },
  selected = { fg = "selected_muted" },
}

return sheet.define("select", {
  title = common.title,
  counter = common.counter,
  empty = common.empty,
  muted = common.muted,
  key_hint = common.key_hint,
  match = common.key_hint,
  hint_separator = { fg = "divider" },
  label = {
    fg = "fg",
    hovered = { fg = "hover_fg" },
    selected = { fg = "selection_fg" },
  },
  detail = detail,
  detail_indent = sheet.merge(detail, list_row.slots.row_gap),
})
