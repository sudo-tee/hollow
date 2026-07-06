--- Modal — overlay shell.
---
--- Creates an overlay widget, pushes it, returns a handle with close/invalidate.

local shared = require("hollow.ui.shared")
local theme_api = require("hollow.theme")
local ui = _G.hollow.ui
local click_registry = require("hollow.ui.builder.internal.click_registry")
local button_component = require("hollow.ui.builder.components.button")

local M = {}

---@param spec { theme?: string, render: function, keys?: function, width?: integer, height?: integer, max_height?: integer, chrome?: table, align?: string, backdrop?: any }
---@return HollowUiBuilderModal
function M.modal(spec)
  local theme
  if type(spec.theme) == "table" then
    theme = spec.theme
  else
    theme = theme_api.resolve_widget(spec.theme or "default")
  end

  local state = {
    hovered_id = nil,
  }

  local widget = ui.overlay.new({
    render = function()
      click_registry.reset()
      button_component.reset()
      local rows = spec.render(theme, state)
      return rows
    end,
    on_key = function(key, mods)
      if spec.keys then
        return spec.keys(key, mods)
      end
      return false
    end,
    on_event = function(name, payload)
      if name == "overlay:hover" then
        state.hovered_id = payload and payload.id or nil
      elseif name == "overlay:leave" then
        state.hovered_id = nil
      elseif name == "overlay:click" then
        if payload and payload.id then
          click_registry.dispatch(payload.id, payload.value)
        end
      end

      if spec.on_event then
        spec.on_event(name, payload)
      end
    end,
    width = spec.width,
    height = spec.height,
    max_height = spec.max_height,
    chrome = spec.chrome or shared.theme_overlay_chrome(theme),
    align = spec.align or "center",
    backdrop = spec.backdrop,
  })

  ui.overlay.push(widget)

  local handle = {
    widget = widget,
    close = function()
      ui.close_overlay_widget(widget)
    end,
    invalidate = function()
      -- no-op for now; future use
    end,
  }

  return handle
end

return M
