local shared = require("hollow.ui.shared")

local M = {}
M.section_padding = { top = 8 }
M.row_padding = { left = 4, top = 2, bottom = 2 }
M.section_indicator_padding = { left = 4, top = 8, bottom = 2 }

-- Keep the indicator column stable as selection and hover move between rows.
function M.indicator(ui, theme, selected, hovered, indent, padding)
  local fg = theme.muted
  if selected then
    fg = shared.part_color(theme, "list_row", "accent", theme.panel_border)
  end
  return ui.text("  " .. (indent or ""), {
    fg = fg,
    padding = padding or M.row_padding,
  })
end

function M.row(options, theme, selected, hovered, default_bg)
  local style = shared.resolve_component_style("list_row", theme, { default_bg = default_bg }, {
    selected = selected,
    hovered = hovered,
  })
  options.fill_bg = style.bg
  options.fill_radius = style.radius
  options.accent_bar = nil
  if selected then
    options.accent_bar = shared.part_color(theme, "list_row", "accent", theme.panel_border)
  end
  options.scrollbar_track_color =
    shared.part_color(theme, "scrollbar", "track", theme.scrollbar_track)
  options.scrollbar_thumb_color =
    shared.part_color(theme, "scrollbar", "thumb", theme.scrollbar_thumb)
  return options
end

function M.hovered(state, id)
  return shared.node_state(state, id).hovered
end

return M
