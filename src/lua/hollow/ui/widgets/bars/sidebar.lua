local hollow = _G.hollow
local state = require("hollow.state").get()
local ui = hollow.ui
local shared = require("hollow.ui.shared")
local widget_core = require("hollow.ui.widgets.core")
local M = {}
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
  end
  function ui.sidebar.unmount()
    widget_core.unmount_widget(state.ui.mounted_sidebar)
    state.ui.mounted_sidebar = nil
    state.ui.sidebar_visible = false
  end

  function ui.sidebar.toggle()
    if not state.ui.mounted_sidebar then
      return false
    end
    state.ui.sidebar_visible = not state.ui.sidebar_visible
    return state.ui.sidebar_visible
  end

  function ui._sidebar_state()
    local widget = state.ui.mounted_sidebar
    if not widget or not state.ui.sidebar_visible then
      return nil
    end

    local width = math.max(1, math.floor(tonumber(widget.width) or 24))
    local rows = {}
    for index, row in ipairs(shared.render_widget_rows(widget)) do
      rows[index] = ui.trim_row_for_width(row, width)
    end

    return {
      side = widget.side == "right" and "right" or "left",
      width = width,
      reserve = widget.reserve == true,
      rows = rows,
    }
  end
end
return M
