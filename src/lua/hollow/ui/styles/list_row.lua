local sheet = require("hollow.ui.style.sheet")

local ROW_PADDING = { left = 4, top = 2, bottom = 2 }
local ACCENT = "parts.list_row.accent|panel_border"
local SECTION_BG = "selected_detail_bg|panel_bg"

local indicator = { fg = "muted", padding = ROW_PADDING, selected = { fg = ACCENT } }

return sheet.define("list_row", {
  -- Raw `ui.row({ variant = ... })` node paint.
  root = {
    fg = "fg",
    radius = 4,
    hovered = { fg = "hover_fg", bg = "hover_bg" },
    selected = { fg = "selection_fg", bg = "selection_bg" },
    disabled = { fg = "muted|fg" },
    variants = {
      selectable = {},
      section = { bg = SECTION_BG },
    },
  },
  -- Row options for built-in lists: merge into the options passed to `ui.row`.
  paint = {
    fill_radius = 4,
    scrollbar_track_color = "parts.scrollbar.track|scrollbar_track",
    scrollbar_thumb_color = "parts.scrollbar.thumb|scrollbar_thumb",
    hovered = { fill_bg = "hover_bg" },
    selected = { fill_bg = "selection_bg", accent_bar = ACCENT },
    variants = {
      selectable = {},
      section = { fill_bg = SECTION_BG },
    },
  },
  -- Serialization defaults for raw rows that leave these options unset. Only
  -- selected `selectable` rows get an accent; the track matches the native
  -- default. Thumbs without a part inherit the final native panel border.
  raw_paint = {
    scrollbar_track_color = "parts.scrollbar.track|#5a6375",
    variants = {
      selectable = { selected = { accent_bar = ACCENT } },
      section = {},
    },
  },
  -- Leading gutter keeps labels stable as selection moves between rows.
  indicator = indicator,
  section_indicator = sheet.merge(indicator, { padding = { top = 8 } }),
  -- Spacing shared with other sheets through `list_row.slots`.
  row_gap = { padding = ROW_PADDING },
  section_gap = { padding = { top = 8 } },
})
