local hollow = _G.hollow
local state = require("hollow.state").get()
local ui = hollow.ui
local events = require("hollow.ui.widgets.bars.bar_events")
local shared = require("hollow.ui.shared")
local widget_core = require("hollow.ui.widgets.core")
local M = {}

local function request_layout_refresh()
  if
    type(state.host_api) == "table" and type(state.host_api.request_layout_refresh) == "function"
  then
    state.host_api.request_layout_refresh()
  end
end

function M.install()
  ui.sidebar = ui.sidebar or {}

  function ui.sidebar.new(opts)
    return ui.new_widget("sidebar", opts)
  end

  function ui.sidebar.mount(widget)
    widget_core.unmount_widget(state.ui.mounted_sidebar)
    state.ui.mounted_sidebar = widget
    state.ui.sidebar_visible = widget.hidden ~= true
    widget_core.mount_widget(widget)
    request_layout_refresh()
  end
  function ui.sidebar.unmount()
    widget_core.unmount_widget(state.ui.mounted_sidebar)
    state.ui.mounted_sidebar = nil
    state.ui.sidebar_visible = false
    request_layout_refresh()
  end

  function ui.sidebar.toggle()
    if not state.ui.mounted_sidebar then
      return false
    end
    state.ui.sidebar_visible = not state.ui.sidebar_visible
    request_layout_refresh()
    return state.ui.sidebar_visible
  end

  function ui._sidebar_state()
    local widget = state.ui.mounted_sidebar
    if not widget or not state.ui.sidebar_visible then
      state.ui.sidebar_handlers = nil
      return nil
    end

    local width = math.max(1, math.floor(tonumber(widget.width) or 24))
    local rows, row_styles = {}, {}
    local palette = widget._palette or shared.palette("sidebar")
    local handlers, auto_id = {}, 0
    local function next_auto_id()
      auto_id = auto_id + 1
      return "sidebar:auto:" .. auto_id
    end
    local hovered_id = state.ui.sidebar_hovered_id
    for index, row in ipairs(shared.render_widget_rows(widget)) do
      events.register(row.children, handlers, next_auto_id)
      if hovered_id ~= nil then
        local resolved = {}
        for key, value in pairs(row) do
          resolved[key] = value
        end
        resolved.children = events.resolve_value("sidebar", row.children)
        row = resolved
      end
      local paint, text_style = shared.serialize_row_paint(row, palette, hovered_id)
      rows[index] = ui.trim_row_for_width(row, width, palette, text_style)
      row_styles[index] = paint
    end
    -- Handler maps are the state.ui mailbox read by bar_events.
    state.ui.sidebar_handlers = handlers

    return {
      side = widget.side == "right" and "right" or "left",
      width = width,
      reserve = widget.reserve == true,
      rows = rows,
      row_styles = row_styles,
      style = shared.sidebar_surface_style(widget.style, palette),
    }
  end
end
return M
