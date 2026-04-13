local shared = require("hollow.ui.shared")

local hollow = _G.hollow
local state  = require("hollow.state").get()

-- ---------------------------------------------------------------------------
-- Overlay stack (shared mutable reference from state)
-- ---------------------------------------------------------------------------

local overlay_stack = state.ui.overlay_stack

-- ---------------------------------------------------------------------------
-- Widget factory
-- ---------------------------------------------------------------------------

local function validate_widget_opts(opts)
  if type(opts) ~= "table" then error("widget opts must be a table") end
  if type(opts.render) ~= "function" then error("widget opts.render must be a function") end
  return opts
end

function hollow.ui.new_widget(kind, opts)
  opts = validate_widget_opts(opts)
  return {
    _kind      = kind,
    render     = opts.render,
    on_event   = opts.on_event,
    on_key     = opts.on_key,
    on_mount   = opts.on_mount,
    on_unmount = opts.on_unmount,
    height     = opts.height,
    max_height = opts.max_height,
    width      = opts.width,
    side       = opts.side,
    align      = opts.align,
    backdrop   = opts.backdrop,
    chrome     = opts.chrome,
    hidden     = opts.hidden,
    reserve    = opts.reserve,
  }
end

-- ---------------------------------------------------------------------------
-- Overlay stack management
-- ---------------------------------------------------------------------------

function hollow.ui.close_overlay_widget(widget)
  for i = #overlay_stack, 1, -1 do
    if overlay_stack[i] == widget then
      table.remove(overlay_stack, i)
      if widget.on_unmount then widget.on_unmount() end
      return widget
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Event dispatch
-- ---------------------------------------------------------------------------

function hollow.ui.dispatch_widget_event(name, e)
  local widgets = {}
  if state.ui.mounted_topbar    ~= nil then widgets[#widgets + 1] = state.ui.mounted_topbar    end
  if state.ui.mounted_bottombar ~= nil then widgets[#widgets + 1] = state.ui.mounted_bottombar end
  if state.ui.mounted_sidebar   ~= nil then widgets[#widgets + 1] = state.ui.mounted_sidebar   end
  for _, w in ipairs(overlay_stack) do widgets[#widgets + 1] = w end
  for _, w in ipairs(widgets) do
    if type(w.on_event) == "function" then w.on_event(name, e) end
  end
end

function hollow.ui.dispatch_overlay_key(key, mods)
  local canonical_mods = hollow.keymap.format_mods(mods)
  for i = #overlay_stack, 1, -1 do
    local w = overlay_stack[i]
    if type(w.on_key) == "function" then
      local ok, consumed = pcall(w.on_key, key, canonical_mods)
      if ok and consumed then return true end
    end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Sidebar row trimming
-- ---------------------------------------------------------------------------

function hollow.ui.trim_row_for_width(row, max_chars)
  local flattened = shared.flatten_span_nodes(hollow.ui.overlay_row.nodes(row))
  local segments  = {}
  local remaining = math.max(0, math.floor(max_chars or 0))
  for _, node in ipairs(flattened) do
    if remaining <= 0 then break end
    if not node.spacer then
      local text = node.text or ""
      if #text > remaining then text = text:sub(1, remaining) end
      if #text > 0 then
        segments[#segments + 1] = shared.style_to_segment(text, node.style)
        remaining = remaining - #text
      end
    end
  end
  return segments
end
