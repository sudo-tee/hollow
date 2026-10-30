local box = require("hollow.ui.style.box")
local shared = require("hollow.ui.shared")
local theme_api = require("hollow.theme")
local util = require("hollow.util")
local widget_core = require("hollow.ui.widgets.core")

---@type Hollow
local hollow = _G.hollow
local state = require("hollow.state").get()
---@type HollowUi
local ui = hollow.ui
local overlay_stack = state.ui.overlay_stack

ui.overlay = ui.overlay or {}

---@param widget HollowUiWidget
---@return HollowUiOverlaySerializedWidget
local function serialize_overlay_widget(widget)
  local palette = widget._palette or shared.palette(widget._kind or "all")
  local backdrop = widget.backdrop
  if widget._theme_backdrop then
    backdrop = palette.backdrop
  end
  return {
    clay = true,
    layout = widget._layout_snapshot,
    stack_context = widget._notify and "notification" or (widget._modal and "modal" or "overlay"),
    backdrop = shared.normalize_overlay_backdrop(backdrop),
  }
end

function ui._expire_overlays()
  local now = util.host_now_ms(state.host_api)

  for index = #overlay_stack, 1, -1 do
    local widget = overlay_stack[index]
    if type(widget and widget._expires_at) == "number" and widget._expires_at <= now then
      ui.close_overlay_widget(widget)
    end
  end
end

---@param opts HollowUiWidgetOptions
function ui.overlay.new(opts)
  local on_event = opts.on_event
  local widget
  opts.on_event = function(name, payload)
    if
      not widget._modal
      and name == "overlay:click"
      and payload
      and payload.id
      and widget._layout_surface
    then
      widget._layout_surface:dispatch(payload.id)
    end
    if on_event then
      return on_event(name, payload)
    end
  end
  widget = ui.new_widget("overlay", opts)
  return widget
end

--- Compatibility chrome fields replace whole boxes, unlike style layers.
---@param style? HollowUiSurfacePaint
---@param chrome? HollowUiChrome|boolean
---@param palette HollowUiTheme
---@return HollowUiChrome|nil
local function overlay_surface_style(style, chrome, palette)
  if type(style) ~= "table" then
    return shared.normalize_overlay_chrome(chrome, palette)
  end
  local source = util.clone_value(style)
  for key, value in pairs(type(chrome) == "table" and chrome or {}) do
    source[key] = util.clone_value(value)
  end
  return shared.normalize_overlay_chrome(source, palette)
end

---@param widget HollowUiWidget
function ui.overlay.push(widget)
  if not widget._layout_surface then
    local align = shared.normalize_overlay_align(widget.align)
    local surface
    surface = ui.layout.new({
      theme = widget._palette,
      frame = {
        width = shared.normalize_overlay_size(widget.width),
        height = shared.normalize_overlay_size(widget.height),
        max_height = shared.normalize_overlay_size(widget.max_height),
        align_x = align:find("left") and 0 or (align:find("right") and 2 or 1),
        align_y = (align == "center" or align:find("top")) and 0
          or (align:find("bottom") and 2 or 1),
      },
      render = function(ctx)
        local palette = widget._palette or shared.palette(widget._kind or "overlay")
        local chrome = overlay_surface_style(widget.style, widget.chrome, palette) or {}
        surface.frame.margin = box.normalize(chrome.margin)
        -- Base insets match the former native overlay panel.
        local padding = box.normalize(chrome.padding)
        local cell_w, cell_h = ctx.cell_w or 8, ctx.cell_h or 19
        padding.left, padding.right = padding.left + cell_w * 0.5, padding.right + cell_w * 0.5
        padding.top, padding.bottom = padding.top + cell_h, padding.bottom + cell_h * 0.5
        return ui.components.column({ widget.render(ctx) }, {
          id = "dialog",
          padding = padding,
          -- Notification groups provide their own per-toast chrome.
          style = widget._notify and {} or chrome,
        })
      end,
    })
    widget._layout_surface = surface
  end
  table.insert(overlay_stack, widget)
  widget_core.mount_widget(widget)
end

---@return HollowUiWidget|nil
function ui.overlay.pop()
  local widget = table.remove(overlay_stack)
  widget_core.unmount_widget(widget)
  return widget
end

function ui.overlay.clear()
  while #overlay_stack > 0 do
    ui.overlay.pop()
  end
end

function ui.overlay.depth()
  return #overlay_stack
end

---@param widget HollowUiWidget
---@return HollowUiWidget|nil
function ui.overlay.remove(widget)
  return ui.close_overlay_widget(widget)
end

function ui.resolve_theme(kind)
  return theme_api.resolve_widget(kind)
end

function ui._overlay_state()
  if #overlay_stack == 0 then
    return nil
  end

  return hollow
    .tbl(overlay_stack)
    :map(function(w)
      return serialize_overlay_widget(w)
    end)
    :get()
end
