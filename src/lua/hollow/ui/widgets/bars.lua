local shared = require("hollow.ui.shared")

local hollow = _G.hollow
local state  = require("hollow.state").get()

-- ---------------------------------------------------------------------------
-- Bar item serialization
-- ---------------------------------------------------------------------------

local function serialize_bar_item(node, ctx)
  if type(node) ~= "table" then return nil end

  if node._type == "bar_tabs" then
    local tabs = {}
    for _, tab in ipairs(ctx.term.tabs or {}) do
      local tab_state = {
        id            = tab.id,
        title         = tab.title ~= "" and tab.title or "shell",
        index         = tab.index,
        is_active     = tab.is_active == true,
        is_hovered    = false,
        is_hover_close = false,
        pane          = tab.pane,
        panes         = tab.panes or {},
      }
      local style = node.style
      if type(style) == "function" then
        local ok, r = pcall(style, tab_state, ctx); style = ok and r or nil
      end
      local label = tab_state.title
      if type(node.format) == "function" then
        local ok, r = pcall(node.format, tab_state, ctx); if ok then label = r end
      end
      tabs[#tabs + 1] = shared.bar_value_to_segment(label, tab_state.title, style)
    end
    return { kind = "tabs", fit = node.fit == "content" and "content" or "fill", tabs = tabs }
  end

  if node._type == "bar_workspace" then
    local ws = ctx.term.workspace
    local ws_state = {
      index        = ws and ws.index or 1,
      name         = ws and ws.name  or "ws",
      is_active    = true,
      active_index = ws and ws.index or 1,
      count        = #ctx.term.workspaces,
    }
    local text = ws_state.name
    if type(node.format) == "function" then
      local ok, r = pcall(node.format, ws_state, ctx); if ok and type(r) == "string" then text = r end
    end
    local style = node.style
    if type(style) == "function" then
      local ok, r = pcall(style, ws_state, ctx); style = ok and r or nil
    end
    local seg = shared.bar_value_to_segment(text, ws_state.name, style)
    seg.kind = "segment"
    return seg
  end

  if node._type == "bar_time" then
    local seg = shared.style_to_segment(os.date(node.format or "%H:%M"), node.style)
    seg.kind = "segment"
    return seg
  end

  if node._type == "bar_key_legend" then
    local ls = hollow.keymap.get_leader_state()
    local text = ""
    if ls and ls.active and ls.next_display and #ls.next_display > 0 then
      text = " " .. table.concat(ls.next_display, "  ") .. " "
    end
    local seg = shared.style_to_segment(text, node.style)
    seg.kind = "segment"
    return seg
  end

  if node._type == "bar_custom" then
    local ok, rendered = pcall(node.render, ctx)
    if not ok then return nil end
    local seg
    if type(rendered) == "string" then
      seg = { kind = "segment", text = rendered, id = node.id }
    elseif type(rendered) == "table" then
      seg = shared.style_to_segment(rendered.text or "", rendered.style or rendered)
      seg.kind = "segment"
      seg.id   = seg.id or node.id
    end
    return seg
  end

  if node._type == "spacer" then return { kind = "spacer" } end

  if shared.is_span_node(node) then
    local seg = shared.style_to_segment(node.text or node.name or "", node.style)
    seg.kind = "segment"
    return seg
  end

  return nil
end

local function serialize_bar_widget(widget)
  if widget == nil then return nil end
  local ctx  = shared.widget_ctx()
  local items = shared.normalize_bar_items(shared.render_widget(widget))
  local out  = {}
  for _, item in ipairs(items) do
    local ok, serialized = pcall(serialize_bar_item, item, ctx)
    if serialized ~= nil then out[#out + 1] = serialized end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Bar node event routing
-- ---------------------------------------------------------------------------

local function mounted_bar_widget(surface)
  if surface == "topbar"    then return state.ui.mounted_topbar    end
  if surface == "bottombar" then return state.ui.mounted_bottombar end
  return nil
end

local function hovered_bar_id_key(surface)
  if surface == "topbar"    then return "topbar_hovered_id"    end
  if surface == "bottombar" then return "bottombar_hovered_id" end
  return nil
end

local function call_bar_node_handler(surface, node_id, field, payload)
  local widget = mounted_bar_widget(surface)
  if widget == nil or type(node_id) ~= "string" or node_id == "" then return false end
  local rendered = shared.normalize_bar_items(shared.render_widget(widget))

  local function visit(nodes)
    for _, node in ipairs(nodes) do
      if type(node) == "table" then
        if node._type == "group" then
          if visit(node.children or {}) then return true end
        elseif node._type == "bar_custom" and type(node.id) == "string" and node.id == node_id then
          if type(node[field]) == "function" then node[field](payload); return true end
        else
          local style = node.style
          if type(style) == "table" and style.id == node_id and type(style[field]) == "function" then
            style[field](payload); return true
          end
        end
      end
    end
    return false
  end

  return visit(rendered)
end

function hollow.ui.handle_bar_node_event(kind, payload)
  if type(payload) ~= "table" then return end
  local node_id = payload.id
  if type(node_id) ~= "string" or node_id == "" then return end
  local surface = kind:match("^(%a+bar):")
  if surface ~= "topbar" and surface ~= "bottombar" then return end
  local hovered_key = hovered_bar_id_key(surface)
  if hovered_key == nil then return end

  if kind == surface .. ":hover" then
    if state.ui[hovered_key] ~= node_id then
      if state.ui[hovered_key] ~= nil then
        call_bar_node_handler(surface, state.ui[hovered_key], "on_mouse_leave", { id = state.ui[hovered_key] })
      end
      state.ui[hovered_key] = node_id
      call_bar_node_handler(surface, node_id, "on_mouse_enter", payload)
    end
    return
  end

  if kind == surface .. ":leave" then
    if state.ui[hovered_key] ~= nil then
      call_bar_node_handler(surface, state.ui[hovered_key], "on_mouse_leave", { id = state.ui[hovered_key] })
      state.ui[hovered_key] = nil
    end
    return
  end

  if kind == surface .. ":click" then
    call_bar_node_handler(surface, node_id, "on_click", payload)
  end
end

-- ---------------------------------------------------------------------------
-- Public API: topbar / bottombar / sidebar
-- ---------------------------------------------------------------------------

hollow.ui.topbar = hollow.ui.topbar or {}

function hollow.ui.topbar.new(opts)    return hollow.ui.new_widget("topbar", opts) end
function hollow.ui.topbar.mount(widget)
  if state.ui.mounted_topbar and state.ui.mounted_topbar.on_unmount then
    state.ui.mounted_topbar.on_unmount()
  end
  state.ui.mounted_topbar = widget
  if widget.on_mount then widget.on_mount() end
end
function hollow.ui.topbar.unmount()
  local w = state.ui.mounted_topbar
  if w and w.on_unmount then w.on_unmount() end
  state.ui.mounted_topbar = nil
end
function hollow.ui.topbar.invalidate() return state.ui.mounted_topbar ~= nil end

hollow.ui.bottombar = hollow.ui.bottombar or {}

function hollow.ui.bottombar.new(opts)    return hollow.ui.new_widget("bottombar", opts) end
function hollow.ui.bottombar.mount(widget)
  if state.ui.mounted_bottombar and state.ui.mounted_bottombar.on_unmount then
    state.ui.mounted_bottombar.on_unmount()
  end
  state.ui.mounted_bottombar = widget
  if widget.on_mount then widget.on_mount() end
end
function hollow.ui.bottombar.unmount()
  local w = state.ui.mounted_bottombar
  if w and w.on_unmount then w.on_unmount() end
  state.ui.mounted_bottombar = nil
end
function hollow.ui.bottombar.invalidate() return state.ui.mounted_bottombar ~= nil end

hollow.ui.sidebar = hollow.ui.sidebar or {}

function hollow.ui.sidebar.new(opts)    return hollow.ui.new_widget("sidebar", opts) end
function hollow.ui.sidebar.mount(widget)
  if state.ui.mounted_sidebar and state.ui.mounted_sidebar.on_unmount then
    state.ui.mounted_sidebar.on_unmount()
  end
  state.ui.mounted_sidebar   = widget
  state.ui.sidebar_visible   = widget.hidden ~= true
  if widget.on_mount then widget.on_mount() end
end
function hollow.ui.sidebar.unmount()
  if state.ui.mounted_sidebar and state.ui.mounted_sidebar.on_unmount then
    state.ui.mounted_sidebar.on_unmount()
  end
  state.ui.mounted_sidebar  = nil
  state.ui.sidebar_visible  = false
end
function hollow.ui.sidebar.toggle()
  if state.ui.mounted_sidebar == nil then return false end
  state.ui.sidebar_visible = not state.ui.sidebar_visible
  return state.ui.sidebar_visible
end
function hollow.ui.sidebar.invalidate() return state.ui.mounted_sidebar ~= nil end

-- ---------------------------------------------------------------------------
-- Internal renderer queries
-- ---------------------------------------------------------------------------

function hollow.ui._topbar_state()    return serialize_bar_widget(state.ui.mounted_topbar)    end
function hollow.ui._bottombar_state() return serialize_bar_widget(state.ui.mounted_bottombar) end

function hollow.ui._bottombar_layout()
  if state.ui.mounted_bottombar == nil then return nil end
  local height = tonumber(state.ui.mounted_bottombar.height) or 0
  return { height = math.max(0, math.floor(height)) }
end

function hollow.ui._sidebar_state()
  if state.ui.mounted_sidebar == nil or not state.ui.sidebar_visible then return nil end
  local rows  = shared.render_widget_rows(state.ui.mounted_sidebar)
  local side  = state.ui.mounted_sidebar.side == "right" and "right" or "left"
  local width = tonumber(state.ui.mounted_sidebar.width) or 24
  local segments = {}
  for i, row in ipairs(rows) do
    segments[i] = hollow.ui.trim_row_for_width(row, width)
  end
  return {
    side    = side,
    width   = math.max(1, math.floor(width)),
    reserve = state.ui.mounted_sidebar.reserve == true,
    rows    = segments,
  }
end
