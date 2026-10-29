--- Modal — overlay shell.
---
--- Creates an overlay widget, pushes it, returns a handle with close/invalidate.

local shared = require("hollow.ui.shared")
local hollow = _G.hollow
local ui = hollow.ui
local overlay_stack = require("hollow.state").get().ui.overlay_stack
local box = require("hollow.ui.style.box")
local button_component = require("hollow.ui.builder.components.button")
local click_registry = require("hollow.ui.builder.internal.click_registry")

local M = {}

---@param spec { theme?: string, render: function, keys?: function, width?: integer, height?: integer, max_height?: integer, chrome?: table, align?: string, backdrop?: any, theme_backdrop?: boolean }
---@return HollowUiModalHandle|nil
function M.modal(spec)
  -- Preserve unfinished input and questions; never replace an active modal.
  for _, existing in ipairs(overlay_stack) do
    if existing._modal then
      return nil
    end
  end

  local theme
  if type(spec.theme) == "table" then
    theme = spec.theme
  else
    theme = shared.widget_theme(spec.theme or "default")
  end

  local state = {
    hovered_id = nil,
  }

  local widget
  widget = ui.overlay.new({
    render = function()
      click_registry.reset()
      button_component.reset()
      local rows = spec.render(theme, state)
      return rows
    end,
    on_key = function(key, mods)
      if spec.keys then
        local consumed = spec.keys(key, mods)
        if widget._layout_surface and consumed then
          widget._layout_surface:invalidate()
        end
        return consumed
      end
      return false
    end,
    on_event = function(name, payload)
      local surface = widget._layout_surface
      if surface and payload and payload.id then
        local local_id = surface:local_id(payload.id)
        if name == "overlay:click" then
          surface:dispatch(payload.id)
        end
        payload = hollow.util.clone_value(payload)
        payload.id = local_id
      end
      if name == "overlay:hover" then
        state.hovered_id = payload and payload.id or nil
      elseif name == "overlay:leave" then
        state.hovered_id = nil
      end
      if surface and (name == "overlay:hover" or name == "overlay:leave") then
        surface:invalidate()
      end

      local consumed = spec.on_event and spec.on_event(name, payload)
      local scroll_delta = payload and payload.delta or 0
      if name == "overlay:scroll" and scroll_delta ~= 0 and not consumed and spec.keys then
        spec.keys(scroll_delta < 0 and "arrow_down" or "arrow_up", 0)
      end
    end,
    width = spec.width,
    height = spec.height,
    max_height = spec.max_height,
    chrome = spec.chrome or shared.theme_overlay_chrome(theme),
    align = spec.align or "center",
    backdrop = spec.backdrop,
  })

  widget._palette = theme
  widget._theme_backdrop = spec.theme_backdrop == true
  widget._modal = true
  if spec.layout_render then
    local align = shared.normalize_overlay_align(widget.align)
    widget._layout_surface = ui.layout.new({
      theme = theme,
      frame = {
        width = shared.normalize_overlay_size(spec.width),
        height = shared.normalize_overlay_size(spec.height),
        align_x = align:find("left") and 0 or (align:find("right") and 2 or 1),
        align_y = align:find("top") and 0 or (align:find("bottom") and 2 or 1),
      },
      render = function(ctx)
        local chrome = shared.normalize_overlay_chrome(widget.chrome, theme) or {}
        widget._layout_surface.frame.margin = box.normalize(chrome.margin)
        local padding = box.normalize(chrome.padding)
        local cell_w, cell_h = ctx.cell_w or 8, ctx.cell_h or 19
        padding.left, padding.right = padding.left + cell_w * 0.5, padding.right + cell_w * 0.5
        padding.top, padding.bottom = padding.top + cell_h, padding.bottom + cell_h * 0.5
        return ui.layout.column({ spec.layout_render(theme, state, ctx) }, {
          id = "dialog",
          label = spec.title or "Confirmation",
          padding = padding,
          style = chrome,
        })
      end,
    })
  end
  ui.overlay.push(widget)

  local handle = {
    widget = widget,
    close = function()
      ui.close_overlay_widget(widget)
    end,
    invalidate = function()
      if widget._layout_surface then
        widget._layout_surface:invalidate()
      end
    end,
  }

  return handle
end

return M
