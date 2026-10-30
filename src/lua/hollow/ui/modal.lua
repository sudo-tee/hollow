--- Modal — overlay shell.
---
--- Creates an overlay widget, pushes it, returns a handle with close/invalidate.

local shared = require("hollow.ui.shared")
local hollow = _G.hollow
local ui = hollow.ui
local overlay_stack = require("hollow.state").get().ui.overlay_stack
local box = require("hollow.ui.style.box")
local host_api = require("hollow.state").get().host_api

local M = {}

--- layout_events invalidates on named events; layout_refresh_after returns a
--- delay in milliseconds (or nil) after each layout render. Both are opt-in.
--- semantic_hover opts custom hover-dependent content into snapshot rebuilds;
--- ordinary hover paint stays native through hover_bg. Consumed events also rebuild.
---@param spec { theme?: string, render: function, keys?: function, width?: integer, height?: integer, max_height?: integer, chrome?: table, align?: string, backdrop?: any, theme_backdrop?: boolean, layout_events?: string[], layout_refresh_after?: function, on_unmount?: function }
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
  -- Deferred callbacks cannot be cancelled by the host. The slot is cleared
  -- on unmount so pending callbacks never retain the widget or its closures.
  local timer = { generation = 0 }
  local listeners = {}
  local function invalidate()
    if not timer.widget then
      return
    end
    local surface = timer.widget._layout_surface
    if surface then
      surface:invalidate()
    end
    -- Repaint only; pane geometry is unaffected by overlay content.
    if type(host_api.request_redraw) == "function" then
      host_api.request_redraw()
    elseif type(host_api.request_layout_refresh) == "function" then
      host_api.request_layout_refresh()
    end
  end
  local function schedule(delay)
    if not timer.widget or type(delay) ~= "number" or delay <= 0 then
      return
    end
    local now = hollow.util.host_now_ms(host_api)
    local deadline = now + math.max(1, math.ceil(delay))
    if timer.deadline and timer.deadline <= deadline then
      return
    end
    timer.generation = timer.generation + 1
    timer.deadline = deadline
    local generation = timer.generation
    host_api.defer(function()
      if not timer.widget or timer.generation ~= generation then
        return
      end
      timer.deadline = nil
      invalidate()
    end, math.max(1, math.ceil(delay)))
  end
  widget = ui.overlay.new({
    render = spec.render,
    on_mount = spec.on_mount,
    on_unmount = function()
      timer.widget = nil
      timer.generation = timer.generation + 1
      timer.deadline = nil
      for _, listener in ipairs(listeners) do
        hollow.events.off(listener)
      end
      listeners = {}
      if spec.on_unmount then
        spec.on_unmount()
      end
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
      if
        surface
        and spec.semantic_hover
        and (name == "overlay:hover" or name == "overlay:leave")
      then
        surface:invalidate()
      end

      local consumed = spec.on_event and spec.on_event(name, payload)
      if surface and (consumed or name == "overlay:click") then
        surface:invalidate()
      end
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
  widget._layout_live = spec.layout_live == true
  do
    local align = shared.normalize_overlay_align(widget.align)
    widget._layout_surface = ui.layout.new({
      theme = theme,
      frame = {
        width = shared.normalize_overlay_size(spec.width),
        height = shared.normalize_overlay_size(spec.height),
        max_height = shared.normalize_overlay_size(spec.max_height),
        align_x = align:find("left") and 0 or (align:find("right") and 2 or 1),
        align_y = (align == "center" or align:find("top")) and 0
          or (align:find("bottom") and 2 or 1),
      },
      render = function(ctx)
        local chrome = shared.normalize_overlay_chrome(widget.chrome, theme) or {}
        widget._layout_surface.frame.margin = box.normalize(chrome.margin)
        local padding = box.normalize(chrome.padding)
        local cell_w, cell_h = ctx.cell_w or 8, ctx.cell_h or 19
        padding.left, padding.right = padding.left + cell_w * 1.5, padding.right + cell_w * 1.5
        padding.top, padding.bottom = padding.top + cell_h, padding.bottom + cell_h * 0.5
        local content, preferred_height = spec.render(theme, state, ctx)
        if spec.layout_refresh_after then
          schedule(spec.layout_refresh_after())
        end
        if preferred_height and not shared.normalize_overlay_size(spec.height) then
          widget._layout_surface.frame.height = (preferred_height + padding.top + padding.bottom)
            / cell_h
        end
        return ui.components.column({ content }, {
          id = "dialog",
          label = spec.title or "Confirmation",
          padding = padding,
          style = chrome,
        })
      end,
    })
  end
  timer.widget = widget
  for _, name in ipairs(spec.layout_events or {}) do
    listeners[#listeners + 1] = hollow.events.on(name, invalidate)
  end
  ui.overlay.push(widget)

  local handle = {
    widget = widget,
    close = function()
      ui.close_overlay_widget(widget)
    end,
    invalidate = invalidate,
    schedule_refresh = schedule,
  }

  return handle
end

return M
