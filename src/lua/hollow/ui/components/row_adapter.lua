-- Compatibility adapter for inline rows; output uses list_item and rich nodes.
local box = require("hollow.ui.style.box")
local c = require("hollow.ui.components")
local inline = require("hollow.ui.components.rich")
local list_row = require("hollow.ui.recipes.list_row")
local props = require("hollow.ui.components.props")
local shared = require("hollow.ui.shared")
local M = {}

function M.line_height(theme, ctx)
  local padding = box.normalize(list_row(theme).indicator.padding)
  return props.cell_h(ctx) + padding.top + padding.bottom
end

function M.from_row(row, id, label, theme, ctx, on_click, plain)
  local serialized = shared.serialize_row_paint(row, theme)
  local flat = shared.flatten_span_nodes(row.children)
  local top, bottom, center = 0, 0, false
  for _, span in ipairs(flat) do
    local padding = box.normalize(span.style and span.style.padding)
    top, bottom = math.max(top, padding.top), math.max(bottom, padding.bottom)
  end
  for _, span in ipairs(flat) do
    if
      not span.spacer
      and tostring(span.text or ""):match("%S")
      and box.normalize(span.style and span.style.padding).top < top
    then
      center = true
    end
  end
  local content
  if plain then
    content = c.row(
      { c.text(label, { fg = theme.fg }, { wrap = "none" }) },
      { width = "grow", padding = { top = top, bottom = bottom } }
    )
  else
    content = inline(row.children, nil, {
      width = "grow",
      prefix = id,
      height = props.cell_h(ctx) + top + bottom,
      align_y = center and "center" or "start",
    })
  end
  return c.list_item({
    content,
    id = id,
    theme = theme,
    role = "listitem",
    label = label,
    width = "grow",
    height = props.cell_h(ctx) + top + bottom,
    _accent = serialized.accent_bar or false,
    _style = {
      bg = serialized.fill_bg,
      radius = serialized.fill_radius,
      hover = {
        bg = serialized.accent_bar and serialized.fill_bg
          or list_row(theme, { hovered = true }).paint.fill_bg,
      },
    },
    on_click = on_click,
  })
end

function M.row_height(row, ctx)
  local top, bottom = 0, 0
  for _, span in ipairs(shared.flatten_span_nodes(row.children)) do
    local padding = box.normalize(span.style and span.style.padding)
    top, bottom = math.max(top, padding.top), math.max(bottom, padding.bottom)
  end
  return props.cell_h(ctx) + top + bottom
end

return M
