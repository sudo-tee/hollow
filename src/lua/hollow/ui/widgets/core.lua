local shared = require("hollow.ui.shared")

---@type Hollow
local hollow = _G.hollow
local state = require("hollow.state").get()
---@type HollowUi
local ui = hollow.ui
local overlay_stack = state.ui.overlay_stack

---@param opts any
---@return HollowUiWidgetOptions
local function validate_widget_opts(opts)
  if type(opts) ~= "table" then
    error("widget opts must be a table")
  end

  if type(opts.render) ~= "function" then
    error("widget opts.render must be a function")
  end

  return opts
end

---@param widget HollowUiWidget|nil
local function mount_widget(widget)
  if widget ~= nil and type(widget.on_mount) == "function" then
    widget.on_mount()
  end
end

---@param widget HollowUiWidget|nil
local function unmount_widget(widget)
  if widget ~= nil and type(widget.on_unmount) == "function" then
    widget.on_unmount()
  end
end

---@return HollowUiWidget[]
local function mounted_widgets()
  local widgets = {}

  if state.ui.mounted_topbar ~= nil then
    widgets[#widgets + 1] = state.ui.mounted_topbar
  end
  if state.ui.mounted_bottombar ~= nil then
    widgets[#widgets + 1] = state.ui.mounted_bottombar
  end
  if state.ui.mounted_sidebar ~= nil then
    widgets[#widgets + 1] = state.ui.mounted_sidebar
  end
  for _, widget in ipairs(overlay_stack) do
    widgets[#widgets + 1] = widget
  end

  return widgets
end

---@param row HollowUiRow
---@param max_chars number|nil
---@return HollowUiSegment[]
local function trim_row_for_width(row, max_chars)
  local flattened = shared.flatten_span_nodes(ui.overlay_row.nodes(row))
  local segments = {}
  local remaining = math.max(0, math.floor(max_chars or 0))

  for _, node in ipairs(flattened) do
    if remaining <= 0 then
      break
    end

    if not node.spacer then
      local text = node.text or ""
      if #text > remaining then
        text = text:sub(1, remaining)
      end
      if #text > 0 then
        segments[#segments + 1] = shared.style_to_segment(text, node.style)
        remaining = remaining - #text
      end
    end
  end

  return segments
end

---@param kind string
---@param opts HollowUiWidgetOptions
---@return HollowUiWidget
function ui.new_widget(kind, opts)
  opts = validate_widget_opts(opts)
  return {
    _kind = kind,
    render = opts.render,
    on_event = opts.on_event,
    on_key = opts.on_key,
    on_mount = opts.on_mount,
    on_unmount = opts.on_unmount,
    height = opts.height,
    max_height = opts.max_height,
    width = opts.width,
    side = opts.side,
    align = opts.align,
    backdrop = opts.backdrop,
    chrome = opts.chrome,
    style = opts.style,
    layout = opts.layout,
    hidden = opts.hidden,
    reserve = opts.reserve,
  }
end

---@param widget HollowUiWidget
---@return HollowUiWidget|nil
function ui.close_overlay_widget(widget)
  for index = #overlay_stack, 1, -1 do
    if overlay_stack[index] == widget then
      table.remove(overlay_stack, index)
      unmount_widget(widget)
      return widget
    end
  end

  return nil
end

---@param name string
---@param payload HollowUiNodeEventPayload
function ui.dispatch_widget_event(name, payload)
  for _, widget in ipairs(mounted_widgets()) do
    if type(widget.on_event) == "function" then
      widget.on_event(name, payload)
    end
  end
end

---@param key string
---@param mods HollowUiKeyMods
---@return boolean
function ui.dispatch_overlay_key(key, mods)
  local canonical_mods = hollow.keymap.format_mods(mods)

  for index = #overlay_stack, 1, -1 do
    local widget = overlay_stack[index]
    if type(widget.on_key) == "function" then
      local ok, consumed = pcall(widget.on_key, key, canonical_mods)
      if ok and consumed then
        return true
      end
    end
  end

  return false
end

ui.trim_row_for_width = trim_row_for_width

return {
  mount_widget = mount_widget,
  unmount_widget = unmount_widget,
}
