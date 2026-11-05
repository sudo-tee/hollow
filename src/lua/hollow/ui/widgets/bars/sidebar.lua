local hollow = _G.hollow
local state = require("hollow.state").get()
local ui = hollow.ui
local content = require("hollow.ui.widgets.sidebar_content")
local util = require("hollow.util")
local shared = require("hollow.ui.shared")
local widget_core = require("hollow.ui.widgets.core")
local M = {}

-- Loaded after hollow.ui.pane; nil only while the UI runtime is bootstrapping.
local function dock()
  return package.loaded["hollow.ui.widgets.sidebar_dock"]
end

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
    state.ui.sidebar_handlers, state.ui.sidebar_hovered_id = nil, nil
    state.ui.mounted_sidebar = widget
    state.ui.sidebar_visible = widget.hidden ~= true
    widget_core.mount_widget(widget)
    if dock() then
      dock().invalidate()
    end
    request_layout_refresh()
  end
  function ui.sidebar.unmount()
    if dock() then
      dock().close(true)
    end
    widget_core.unmount_widget(state.ui.mounted_sidebar)
    state.ui.mounted_sidebar = nil
    state.ui.sidebar_visible = false
    state.ui.sidebar_handlers, state.ui.sidebar_hovered_id = nil, nil
    request_layout_refresh()
  end

  function ui.sidebar.toggle()
    if not state.ui.mounted_sidebar then
      return false
    end
    -- A docked sidebar is visible; toggling hides it and closes its pane.
    if dock() and dock().is_docked() then
      dock().close(true)
      state.ui.sidebar_visible = false
      request_layout_refresh()
      return false
    end
    state.ui.sidebar_visible = not state.ui.sidebar_visible
    request_layout_refresh()
    return state.ui.sidebar_visible
  end

  --- Toggle between the edge Clay surface and a split Lua pane.
  function ui.sidebar.dock(opts)
    if not dock() or not state.ui.mounted_sidebar then
      return nil
    end
    if dock().is_docked() then
      dock().close(false)
      return nil
    end
    return dock().dock(opts)
  end

  function ui.sidebar.is_docked()
    return dock() ~= nil and dock().is_docked()
  end

  function ui.sidebar.invalidate()
    if not state.ui.mounted_sidebar then
      return false
    end
    if dock() and dock().invalidate() then
      return true
    end
    local surface = state.ui.mounted_sidebar._sidebar_surface
    if surface then
      surface:invalidate()
    end
    if type(state.host_api.request_redraw) == "function" then
      state.host_api.request_redraw()
    end
    return true
  end

  local function edge_widget()
    local widget = state.ui.mounted_sidebar
    if widget and state.ui.sidebar_visible and not state.ui.sidebar_docked then
      return widget
    end
  end

  -- Only sidebar placement remains native. The content is a Clay surface.
  function ui._sidebar_state()
    local widget = edge_widget()
    if not widget then
      state.ui.sidebar_handlers = nil
      return nil
    end
    return {
      side = widget.side == "right" and "right" or "left",
      width = math.max(1, math.floor(tonumber(widget.width) or 24)),
      reserve = widget.reserve == true,
    }
  end

  -- This publication is independent of the active modal/overlay layout.
  function ui._sidebar_layout_prepare(width, height, cell_w, cell_h)
    local widget = edge_widget()
    ui._sidebar_layout_tree = nil
    ui._sidebar_layout_revision = 0
    ui._sidebar_layout_surface_id = 0
    if not widget then
      state.ui.sidebar_handlers = nil
      return
    end

    local surface = widget._sidebar_surface
    if not surface or surface.destroyed then
      surface = ui.layout.new({
        theme = widget._palette or shared.palette("sidebar"),
        render = function(ctx)
          local tree, handlers, ids = content.render(widget, ctx)
          widget._sidebar_handlers, widget._sidebar_ids = handlers, ids
          return tree
        end,
      })
      widget._sidebar_surface = surface
    end

    -- Match the original live edge sidebar until native invalidation is
    -- benchmarked: its render callback may depend on terminal state.
    surface:invalidate()
    local cols = math.max(1, math.floor(tonumber(widget.width) or 24))
    local hovered = state.ui.sidebar_hovered_id
    local nodes = surface:snapshot({
      width = (cols + 1) * cell_w,
      height = height,
      cell_w = cell_w,
      cell_h = cell_h,
      hovered_id = type(hovered) == "string"
          and hovered:sub(1, #surface.namespace) == surface.namespace
          and hovered:sub(#surface.namespace + 1)
        or nil,
    })

    -- The native host reports Clay ids. Dispatch clicks through the surface
    -- and translate hover callbacks to the original public inline span ids.
    local registered = {}
    for id in pairs(surface.callbacks) do
      local target = id
      registered[id] = {
        on_click = function()
          if widget._sidebar_surface == surface then surface:dispatch(target) end
        end,
      }
    end
    for local_id, span_id in pairs(widget._sidebar_ids or {}) do
      local entry = (widget._sidebar_handlers or {})[span_id]
      if entry then
        local target = surface.namespace .. local_id
        registered[target] = registered[target] or {}
        for _, field in ipairs({ "on_mouse_enter", "on_mouse_leave" }) do
          local callback = entry[field]
          if type(callback) == "function" then
            registered[target][field] = function(event)
              local payload = util.clone_value(event or {})
              payload.id = span_id
              callback(payload)
            end
          end
        end
      end
    end
    state.ui.sidebar_handlers = registered
    ui._sidebar_layout_tree = nodes
    ui._sidebar_layout_revision = surface.revision
    ui._sidebar_layout_surface_id = surface.id
  end

end
return M
