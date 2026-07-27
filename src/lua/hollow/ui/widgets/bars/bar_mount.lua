local hollow = _G.hollow
local state = require("hollow.state").get()
local ui = hollow.ui
local widget_core = require("hollow.ui.widgets.core")
local M = {}
function M.active(surface)
  if surface == "topbar" then
    return state.ui.mounted_topbar
  end
  if surface == "bottombar" then
    return state.ui.mounted_bottombar
  end
end

function M.install(invalidate, configured)
  local function define(namespace, kind, state_key, visibility_key)
    function namespace.new(opts)
      return ui.new_widget(kind, opts)
    end

    function namespace.mount(widget)
      widget_core.unmount_widget(state.ui[state_key])
      state.ui[state_key] = widget
      if visibility_key then
        state.ui[visibility_key] = widget.hidden ~= true
      end
      widget_core.mount_widget(widget)
      invalidate(kind)
    end

    function namespace.unmount()
      widget_core.unmount_widget(state.ui[state_key])
      state.ui[state_key] = nil
      if visibility_key then
        state.ui[visibility_key] = false
      end
      invalidate(kind)
    end

    function namespace.invalidate()
      if (M.active(kind) or configured(kind)) == nil then
        return false
      end
      invalidate(kind)
      return true
    end
  end

  ui.topbar = ui.topbar or {}
  ui.bottombar = ui.bottombar or {}
  define(ui.topbar, "topbar", "mounted_topbar")
  define(ui.bottombar, "bottombar", "mounted_bottombar")
end

function M.widget(surface, configured)
  return M.active(surface) or configured(surface)
end
return M
