local shared = require("hollow.ui.shared")
local util = require("hollow.util")
local widget_core = require("hollow.ui.widgets.core")

---@type Hollow
local hollow = _G.hollow
local state = require("hollow.state").get()
---@type HollowUi
local ui = hollow.ui
local overlay_stack = state.ui.overlay_stack

ui.overlay = ui.overlay or {}

---@param row HollowUiRow
---@return HollowUiOverlaySerializedRow
local function serialize_overlay_row(row)
  local serialized = { segments = {} }

  for _, node in ipairs(shared.flatten_span_nodes(ui.overlay_row.nodes(row))) do
    if not node.spacer then
      serialized.segments[#serialized.segments + 1] = shared.style_to_segment(node.text or "", node.style)
    end
  end

  if type(row) == "table" and row._overlay_row == true then
    serialized.fill_bg = row.fill_bg
    serialized.divider = row.divider
    serialized.scrollbar_track = row.scrollbar_track == true
    serialized.scrollbar_thumb = row.scrollbar_thumb == true
    serialized.scrollbar_track_color = row.scrollbar_track_color
    serialized.scrollbar_thumb_color = row.scrollbar_thumb_color
  end

  return serialized
end

---@param widget HollowUiWidget
---@return HollowUiOverlaySerializedWidget
local function serialize_overlay_widget(widget)
  local rows = shared.render_widget_rows(widget)
  local serialized_rows = {}

  for index, row in ipairs(rows) do
    serialized_rows[index] = serialize_overlay_row(row)
  end

  return {
    align = shared.normalize_overlay_align(widget.align),
    backdrop = shared.normalize_overlay_backdrop(widget.backdrop),
    chrome = shared.normalize_overlay_chrome(widget.chrome),
    width = shared.normalize_overlay_size(widget.width),
    height = shared.normalize_overlay_size(widget.height),
    max_height = shared.normalize_overlay_size(widget.max_height),
    rows = serialized_rows,
  }
end

local function expire_timed_overlays()
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
  return ui.new_widget("overlay", opts)
end

---@param widget HollowUiWidget
function ui.overlay.push(widget)
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
  return shared.resolve_widget_theme(kind)
end

function ui._overlay_state()
  if #overlay_stack == 0 then
    return nil
  end

  expire_timed_overlays()
  if #overlay_stack == 0 then
    return nil
  end

  local result = {}
  for _, widget in ipairs(overlay_stack) do
    result[#result + 1] = serialize_overlay_widget(widget)
  end
  return result
end
