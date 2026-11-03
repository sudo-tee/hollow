-- Docked sidebar: the mounted sidebar widget rendered inside a split Lua pane
-- instead of the native window-edge overlay. Inline sidebar rows are adapted
-- to a Clay tree; span ids stay the node ids so hover and click handlers match.
local hollow = _G.hollow
local state = require("hollow.state").get()
local ui = hollow.ui
local c = ui.components
local events = require("hollow.ui.widgets.bars.bar_events")
local shared = require("hollow.ui.shared")
local util = require("hollow.util")

local MODULE = "hollow.sidebar"
local docked
-- Set while dock() closes the pane to hide the sidebar rather than undock it.
local hide_on_close = false

local function refresh_layout()
  if type(state.host_api.request_layout_refresh) == "function" then
    state.host_api.request_layout_refresh()
  end
end

local function call(handlers, id, field, payload)
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
    on_click = entry and entry.on_click and function(event)
      local payload = util.clone_value(event)
      payload.id = id
      entry.on_click(payload)
    end or nil,
  })
end

local function divider(color, ctx)
  return c.column({
    c.column({}, { width = "grow", height = 1, style = { bg = color } }),
  }, { width = "grow", height = ctx.cell_h or 19, align_y = "center" })
end

-- Builds the pane tree and returns it with the span handlers and node->span ids.
local function render_rows(widget, ctx)
  local palette = widget._palette or shared.palette("sidebar")
  local handlers, seen, auto_id = {}, {}, 0
  local function next_auto_id()
    auto_id = auto_id + 1
    return "sidebar:auto:" .. auto_id
  end
  local rows = {}
  for _, row in ipairs(shared.render_widget_rows(widget)) do
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
  local surface = shared.sidebar_surface_style(widget.style, palette) or {}
  local edge = widget.side == "right" and "left" or "right"
  return c.column(rows, {
    width = "grow",
    height = "grow",
    scroll = true,
    padding = { x = 4 },
    style = { fg = surface.fg, bg = surface.bg, border = surface.border },
    border_width = surface.border and { [edge] = 1 } or nil,
  }),
    handlers,
    seen
end

ui.pane.register(MODULE, function()
  local handlers, ids, hovered = {}, {}, nil
  return {
    title = "Sidebar",
    on_mount = function(ctx)
      docked = ui.pane.get(ctx.pane_id)
      state.ui.sidebar_docked = true
      refresh_layout()
    end,
    on_unmount = function(ctx)
      if docked and docked.id == ctx.pane_id then
        docked = nil
        state.ui.sidebar_docked = false
        -- Closing the pane undocks back to the overlay unless dock()/toggle hid it.
        state.ui.sidebar_visible = state.ui.mounted_sidebar ~= nil and not hide_on_close
        hide_on_close = false
        refresh_layout()
      end
    end,
    render = function(ctx)
      local widget = state.ui.mounted_sidebar
      if not widget then
        return c.column(
          { c.text("No sidebar mounted", { fg = ctx.theme.muted or ctx.theme.fg }) },
          {
            width = "grow",
            height = "grow",
            padding = 8,
          }
        )
      end
      -- Pane hover is reported by node id; fire the span enter/leave handlers.
      local now = ctx.hovered_id and ids[ctx.hovered_id] or nil
      if now ~= hovered then
        call(handlers, hovered, "on_mouse_leave", { id = hovered })
        call(handlers, now, "on_mouse_enter", { id = now })
        hovered = now
      end
      local tree
      tree, handlers, ids = render_rows(widget, ctx)
      return tree
    end,
  }
end)

local M = {}

function M.is_docked()
  return docked ~= nil or state.ui.sidebar_docked == true
end

function M.invalidate()
  if docked then
    docked:invalidate()
    return true
  end
  return false
end

--- Close the docked pane; `hide` leaves the sidebar hidden instead of an overlay.
function M.close(hide)
  if not docked then
    return false
  end
  hide_on_close = hide == true
  return docked:close()
end

function M.dock(opts)
  opts = opts or {}
  local widget = state.ui.mounted_sidebar
  if not widget or docked then
    return nil
  end
  local current = util.safe_call(hollow.term.current_pane, nil)
  local size = current and current.size or {}
  local window_width = shared.window_size_snapshot().width
  local width = math.max(1, math.floor(tonumber(widget.width) or 24))
  -- Edge panes split the whole layout, so size them against the window.
  local ratio = opts.ratio
  if not ratio then
    local cell_w = (size.cols or 0) > 0 and (size.width or 0) / size.cols or 0
    ratio = cell_w > 0 and window_width > 0 and width * cell_w / window_width or 0.25
    ratio = math.max(0.1, math.min(0.5, ratio))
  end
  local previous = current and current.id
  local pane = ui.pane.split({
    module = MODULE,
    edge = opts.edge or (widget.side == "right" and "right" or "left"),
    ratio = ratio,
    on_complete = function(result)
      if not result.success then
        docked = nil
        state.ui.sidebar_docked = false
        refresh_layout()
      elseif previous and opts.focus ~= true then
        -- A sidebar is chrome: keep focus on the pane the user was working in.
        pcall(hollow.term.focus_pane_by_id, previous)
      end
    end,
  })
  if pane then
    docked = pane
    state.ui.sidebar_docked = true
    refresh_layout()
  end
  return pane
end

return M
