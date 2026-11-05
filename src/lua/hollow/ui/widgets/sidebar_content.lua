-- One Clay tree for docked and window-edge sidebars.
-- The inline row DSL is interpreted here only, never by either host.
local hollow = _G.hollow
local ui = hollow.ui
local c = ui.components
local events = require("hollow.ui.widgets.bars.bar_events")
local shared = require("hollow.ui.shared")
local util = require("hollow.util")

local M = {}

function M.call(handlers, id, field, payload)
  local entry = id and handlers[id]
  if entry and type(entry[field]) == "function" then
    entry[field](payload)
  end
end

local function run(span, handlers, seen)
  local style = span.style or {}
  local text = c.text(span.text, style, { wrap = "none" })
  local id = style.id
  if not id then
    if style.bg or style.border or style.radius then
      return c.column({ text }, { style = style })
    end
    return text
  end
  local node_id, n = id, 1
  while seen[node_id] do
    n = n + 1
    node_id = id .. "#" .. n
  end
  seen[node_id] = id
  local entry = handlers[id]
  return c.column({ text }, {
    id = node_id,
    label = span.text,
    style = style,
    -- Hover-only spans need a hit target too; clicking them does nothing.
    on_click = entry and (entry.on_click or entry.on_mouse_enter or entry.on_mouse_leave)
      and function(event)
        if entry.on_click then
          local payload = util.clone_value(event)
          payload.id = id
          entry.on_click(payload)
        end
      end
      or nil,
  })
end

local function divider(color, ctx)
  return c.column({
    c.column({}, { width = "grow", height = 1, style = { bg = color } }),
  }, { width = "grow", height = ctx.cell_h or 19, align_y = "center" })
end

-- Builds the pane tree and returns it with the span handlers and node->span ids.
function M.render(widget, ctx)
  local rendered = shared.render_widget(widget)
  local palette = widget._palette or shared.palette("sidebar")
  local handlers, seen, auto_id = {}, {}, 0
  local function next_auto_id()
    auto_id = auto_id + 1
    return "sidebar:auto:" .. auto_id
  end
  local rows = {}
  if type(rendered) == "table" and type(rendered.kind) == "number" then
    rows[1] = rendered
  else
    for _, row in ipairs(shared.normalize_widget_rows(rendered)) do
    events.register(row.children, handlers, next_auto_id)
    local paint, text_style = shared.serialize_row_paint(row, palette, ctx.hovered_id)
    if paint.divider then
      rows[#rows + 1] = divider(paint.divider, ctx)
    else
      local runs = {}
      local flat =
        shared.flatten_span_nodes(shared.normalize_inline_nodes(row.children), text_style)
      for _, span in ipairs(flat) do
        runs[#runs + 1] = span.spacer and c.spacer() or run(span, handlers, seen)
      end
      rows[#rows + 1] = c.row(runs, {
        width = "grow",
        style = paint.fill_bg and { bg = paint.fill_bg, radius = paint.fill_radius } or nil,
      })
    end
    end
  end
  local surface = shared.sidebar_surface_style(widget.style, palette) or {}
  local edge = widget.side == "right" and "left" or "right"
  return c.column(rows, {
    width = "grow",
    height = "grow",
    scroll = true,
    padding = { x = 4, top = ctx.edge_sidebar and (ctx.cell_h or 19) or nil },
    style = { fg = surface.fg, bg = surface.bg, border = surface.border, alpha = surface.alpha },
    border_width = surface.border and { [edge] = 1 } or nil,
  }),
    handlers,
    seen
end

return M
