local util = require("hollow.util")

local M = {}
M.section_padding = { top = 8 }
M.row_padding = { left = 4, top = 2, bottom = 2 }
M.section_indicator_padding = { left = 4, top = 8, bottom = 2 }

-- Keep the indicator column stable as selection and hover move between rows.
function M.indicator(ui, theme, selected, hovered, indent, padding)
  return ui.text("  " .. (indent or ""), {
    fg = selected and theme.panel_border or theme.muted,
    padding = padding or M.row_padding,
  })
end

function M.row(options, theme, selected, hovered, default_bg)
  options.fill_bg =
    util.state_value(selected, hovered, theme.selection_bg, theme.hover_bg, default_bg)
  options.fill_radius = 4
  options.accent_bar = selected and theme.panel_border or nil
  options.scrollbar_track_color = theme.scrollbar_track
  options.scrollbar_thumb_color = theme.scrollbar_thumb
  return options
end

return M
