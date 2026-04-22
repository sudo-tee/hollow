local shared = require("hollow.ui.shared")
local widget_core = require("hollow.ui.widgets.core")

---@type Hollow
local hollow = _G.hollow
local state = require("hollow.state").get()
---@type HollowUi
local ui = hollow.ui

---@param node HollowUiBarTabsNode
---@param ctx HollowWidgetCtx
---@return HollowUiTabsLayout
local function serialize_tabs(node, ctx)
  local tabs = {}

  for _, tab in ipairs(ctx.term.tabs or {}) do
    local tab_state = {
      id = tab.id,
      title = tab.title ~= "" and tab.title or "shell",
      index = tab.index,
      is_active = tab.is_active == true,
      is_hovered = false,
      is_hover_close = false,
      pane = tab.pane,
      panes = tab.panes or {},
    }

    local style = node.style
    if type(style) == "function" then
      local ok, result = pcall(style, tab_state, ctx)
      style = ok and result or nil
    end

    local label = tab_state.title
    if type(node.format) == "function" then
      local ok, result = pcall(node.format, tab_state, ctx)
      if ok then
        label = result
      end
    end

    tabs[#tabs + 1] = shared.bar_value_to_segment(label, tab_state.title, style)
  end

  return {
    kind = "tabs",
    fit = node.fit == "content" and "content" or "fill",
    tabs = tabs,
  }
end

---@param node HollowUiBarWorkspaceNode
---@param ctx HollowWidgetCtx
---@return HollowUiSegment
local function serialize_workspace(node, ctx)
  local workspace = ctx.term.workspace
  local workspace_state = {
    index = workspace and workspace.index or 1,
    name = workspace and workspace.name or "ws",
    is_active = true,
    active_index = workspace and workspace.index or 1,
    count = #ctx.term.workspaces,
  }

  local text = workspace_state.name
  if type(node.format) == "function" then
    local ok, result = pcall(node.format, workspace_state, ctx)
    if ok and type(result) == "string" then
      text = result
    end
  end

  local style = node.style
  if type(style) == "function" then
    local ok, result = pcall(style, workspace_state, ctx)
    style = ok and result or nil
  end

  local segment = shared.bar_value_to_segment(text, workspace_state.name, style)
  segment.kind = "segment"
  return segment
end

---@param node HollowUiBarTimeNode
---@return HollowUiSegment
local function serialize_time(node)
  local segment = shared.style_to_segment(os.date(node.format or "%H:%M"), node.style)
  segment.kind = "segment"
  return segment
end

---@param node HollowUiBarKeyLegendNode
---@return HollowUiSegment
local function serialize_key_legend(node)
  ---@type HollowLeaderState|nil
  local leader_state = hollow.keymap.get_leader_state()
  local text = ""
  if leader_state and leader_state.active and leader_state.next_display and #leader_state.next_display > 0 then
    text = " " .. table.concat(leader_state.next_display, "  ") .. " "
  end

  local segment = shared.style_to_segment(text, node.style)
  segment.kind = "segment"
  return segment
end

---@param node HollowUiBarCustomNode
---@param ctx HollowWidgetCtx
---@return HollowUiSegment|nil
local function serialize_custom(node, ctx)
  local ok, rendered = pcall(node.render, ctx)
  if not ok then
    return nil
  end

  local segment
  if type(rendered) == "string" then
    segment = { kind = "segment", text = rendered, id = node.id }
  elseif type(rendered) == "table" then
    segment = shared.style_to_segment(rendered.text or "", rendered.style or rendered)
    segment.kind = "segment"
    segment.id = segment.id or node.id
  end

  return segment
end

---@alias HollowUiBarSerializableNode
---| HollowUiRenderableNode
---| HollowUiBarTabsNode
---| HollowUiBarWorkspaceNode
---| HollowUiBarTimeNode
---| HollowUiBarKeyLegendNode
---| HollowUiBarCustomNode

---@param node HollowUiBarSerializableNode|nil
---@param ctx HollowWidgetCtx
---@return HollowUiSegment|HollowUiTabsLayout|{kind:"spacer"}|nil
local function serialize_bar_item(node, ctx)
  if type(node) ~= "table" then
    return nil
  end

  if node._type == "bar_tabs" then
    return serialize_tabs(node, ctx)
  end
  if node._type == "bar_workspace" then
    return serialize_workspace(node, ctx)
  end
  if node._type == "bar_time" then
    return serialize_time(node)
  end
  if node._type == "bar_key_legend" then
    return serialize_key_legend(node)
  end
  if node._type == "bar_custom" then
    return serialize_custom(node, ctx)
  end
  if node._type == "spacer" then
    return { kind = "spacer" }
  end
  if shared.is_span_node(node) then
    local segment = shared.style_to_segment(node.text or node.name or "", node.style)
    segment.kind = "segment"
    return segment
  end

  return nil
end

---@param widget HollowUiWidget|nil
---@return (HollowUiSegment|HollowUiTabsLayout|{kind:"spacer"})[]|nil
local function serialize_bar_widget(widget)
  if widget == nil then
    return nil
  end

  local ctx = shared.widget_ctx()
  local items = shared.normalize_bar_items(shared.render_widget(widget))
  local serialized = {}

  for _, item in ipairs(items) do
    local ok, value = pcall(serialize_bar_item, item, ctx)
    if ok and value ~= nil then
      serialized[#serialized + 1] = value
    end
  end

  return serialized
end

---@param surface string
---@return HollowUiWidget|nil
local function mounted_bar_widget(surface)
  if surface == "topbar" then
    return state.ui.mounted_topbar
  end
  if surface == "bottombar" then
    return state.ui.mounted_bottombar
  end
  return nil
end

---@param surface string
---@return string|nil
local function hovered_bar_id_key(surface)
  if surface == "topbar" then
    return "topbar_hovered_id"
  end
  if surface == "bottombar" then
    return "bottombar_hovered_id"
  end
  return nil
end

---@param node HollowUiRenderableNode|HollowUiBarCustomNode
---@param node_id string
---@param field "on_click"|"on_mouse_enter"|"on_mouse_leave"
---@param payload HollowUiBarNodePayload
---@return boolean
local function visit_bar_nodes(node, node_id, field, payload)
  if type(node) ~= "table" then
    return false
  end

  if node._type == "group" then
    for _, child in ipairs(node.children or {}) do
      if visit_bar_nodes(child, node_id, field, payload) then
        return true
      end
    end
    return false
  end

  if node._type == "bar_custom" and type(node.id) == "string" and node.id == node_id then
    if type(node[field]) == "function" then
      node[field](payload)
      return true
    end
    return false
  end

  local style = node.style
  if type(style) == "table" and style.id == node_id and type(style[field]) == "function" then
    style[field](payload)
    return true
  end

  return false
end

---@param surface string
---@param node_id string
---@param field "on_click"|"on_mouse_enter"|"on_mouse_leave"
---@param payload HollowUiBarNodePayload
---@return boolean
local function call_bar_node_handler(surface, node_id, field, payload)
  local widget = mounted_bar_widget(surface)
  if widget == nil or type(node_id) ~= "string" or node_id == "" then
    return false
  end

  local rendered = shared.normalize_bar_items(shared.render_widget(widget))
  for _, node in ipairs(rendered) do
    if visit_bar_nodes(node, node_id, field, payload) then
      return true
    end
  end

  return false
end

---@param namespace table<string, fun(...):any>
---@param kind string
---@param state_key string
---@param visibility_key string|nil
local function define_mount_api(namespace, kind, state_key, visibility_key)
  function namespace.new(opts)
    return ui.new_widget(kind, opts)
  end

  function namespace.mount(widget)
    widget_core.unmount_widget(state.ui[state_key])
    state.ui[state_key] = widget
    if visibility_key ~= nil then
      state.ui[visibility_key] = widget.hidden ~= true
    end
    widget_core.mount_widget(widget)
  end

  function namespace.unmount()
    widget_core.unmount_widget(state.ui[state_key])
    state.ui[state_key] = nil
    if visibility_key ~= nil then
      state.ui[visibility_key] = false
    end
  end

  function namespace.invalidate()
    return state.ui[state_key] ~= nil
  end
end

ui.topbar = ui.topbar or {}
ui.bottombar = ui.bottombar or {}
ui.sidebar = ui.sidebar or {}

define_mount_api(ui.topbar, "topbar", "mounted_topbar", nil)
define_mount_api(ui.bottombar, "bottombar", "mounted_bottombar", nil)
define_mount_api(ui.sidebar, "sidebar", "mounted_sidebar", "sidebar_visible")

function ui.sidebar.toggle()
  if state.ui.mounted_sidebar == nil then
    return false
  end

  state.ui.sidebar_visible = not state.ui.sidebar_visible
  return state.ui.sidebar_visible
end

---@param kind string
---@param payload HollowUiBarNodePayload|any
function ui.handle_bar_node_event(kind, payload)
  if type(payload) ~= "table" then
    return
  end

  local node_id = payload.id
  if type(node_id) ~= "string" or node_id == "" then
    return
  end

  local surface = kind:match("^(%a+bar):")
  if surface ~= "topbar" and surface ~= "bottombar" then
    return
  end

  local hovered_key = hovered_bar_id_key(surface)
  if hovered_key == nil then
    return
  end

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

function ui._topbar_state()
  return serialize_bar_widget(state.ui.mounted_topbar)
end

function ui._bottombar_state()
  return serialize_bar_widget(state.ui.mounted_bottombar)
end

function ui._bottombar_layout()
  if state.ui.mounted_bottombar == nil then
    return nil
  end

  local height = tonumber(state.ui.mounted_bottombar.height) or 0
  return { height = math.max(0, math.floor(height)) }
end

function ui._sidebar_state()
  if state.ui.mounted_sidebar == nil or not state.ui.sidebar_visible then
    return nil
  end

  local rows = shared.render_widget_rows(state.ui.mounted_sidebar)
  local side = state.ui.mounted_sidebar.side == "right" and "right" or "left"
  local width = tonumber(state.ui.mounted_sidebar.width) or 24
  local segments = {}

  for index, row in ipairs(rows) do
    segments[index] = ui.trim_row_for_width(row, width)
  end

  return {
    side = side,
    width = math.max(1, math.floor(width)),
    reserve = state.ui.mounted_sidebar.reserve == true,
    rows = segments,
  }
end
