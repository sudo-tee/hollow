local shared = require("hollow.ui.shared")

local hollow      = _G.hollow
local state       = require("hollow.state").get()
local overlay_stack = state.ui.overlay_stack

-- ---------------------------------------------------------------------------
-- hollow.ui.overlay.*
-- ---------------------------------------------------------------------------

hollow.ui.overlay = hollow.ui.overlay or {}

function hollow.ui.overlay.new(opts)  return hollow.ui.new_widget("overlay", opts) end

function hollow.ui.overlay.push(widget)
  table.insert(overlay_stack, widget)
  if widget.on_mount then widget.on_mount() end
end

function hollow.ui.overlay.pop()
  local widget = table.remove(overlay_stack)
  if widget and widget.on_unmount then widget.on_unmount() end
  return widget
end

function hollow.ui.overlay.clear()
  while #overlay_stack > 0 do hollow.ui.overlay.pop() end
end

function hollow.ui.overlay.depth() return #overlay_stack end

function hollow.ui.overlay.remove(widget) return hollow.ui.close_overlay_widget(widget) end

-- ---------------------------------------------------------------------------
-- Theme shorthand
-- ---------------------------------------------------------------------------

function hollow.ui.resolve_theme(kind) return shared.resolve_widget_theme(kind) end

-- ---------------------------------------------------------------------------
-- Internal renderer query: _overlay_state
-- ---------------------------------------------------------------------------

function hollow.ui._overlay_state()
  if #overlay_stack == 0 then return nil end

  -- Expire timed overlays.
  local now = shared.monotonic_now_ms()
  for i = #overlay_stack, 1, -1 do
    local w = overlay_stack[i]
    if type(w and w._expires_at) == "number" and w._expires_at <= now then
      hollow.ui.close_overlay_widget(w)
    end
  end
  if #overlay_stack == 0 then return nil end

  local overlay_row = hollow.ui.overlay_row
  local result = {}
  for _, widget in ipairs(overlay_stack) do
    local widget_rows = shared.render_widget_rows(widget)
    local seg_rows    = {}
    for i, row in ipairs(widget_rows) do
      local serialized = { segments = {} }
      for _, node in ipairs(shared.flatten_span_nodes(overlay_row.nodes(row))) do
        if not node.spacer then
          serialized.segments[#serialized.segments + 1] =
            shared.style_to_segment(node.text or "", node.style)
        end
      end
      if type(row) == "table" and row._overlay_row == true then
        serialized.fill_bg             = row.fill_bg
        serialized.divider             = row.divider
        serialized.scrollbar_track     = row.scrollbar_track == true
        serialized.scrollbar_thumb     = row.scrollbar_thumb == true
        serialized.scrollbar_track_color = row.scrollbar_track_color
        serialized.scrollbar_thumb_color = row.scrollbar_thumb_color
      end
      seg_rows[i] = serialized
    end
    result[#result + 1] = {
      align      = shared.normalize_overlay_align(widget.align),
      backdrop   = shared.normalize_overlay_backdrop(widget.backdrop),
      chrome     = shared.normalize_overlay_chrome(widget.chrome),
      width      = shared.normalize_overlay_size(widget.width),
      height     = shared.normalize_overlay_size(widget.height),
      max_height = shared.normalize_overlay_size(widget.max_height),
      rows       = seg_rows,
    }
  end
  return result
end
