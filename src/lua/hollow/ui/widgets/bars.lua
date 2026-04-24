local shared = require("hollow.ui.shared")
local widget_core = require("hollow.ui.widgets.core")

---@type Hollow
local hollow = _G.hollow
local state = require("hollow.state").get()
---@type HollowUi
local ui = hollow.ui

local BAR_EVENT_FIELDS = {
  "on_click",
  "on_mouse_enter",
  "on_mouse_leave",
}

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

---@param surface string|nil
---@param style any
---@return boolean
local function is_hovered_bar_style(surface, style)
  if surface ~= "topbar" and surface ~= "bottombar" then
    return false
  end
  if type(style) ~= "table" or type(style.id) ~= "string" or style.id == "" then
    return false
  end

  local hovered_key = hovered_bar_id_key(surface)
  return hovered_key ~= nil and state.ui[hovered_key] == style.id
end

---@param surface string|nil
---@param style any
---@return any
local function resolve_bar_hover_style(surface, style)
  if type(style) ~= "table" then
    return style
  end

  if not is_hovered_bar_style(surface, style) then
    return style
  end

  local hover = type(style.hover) == "table" and style.hover or nil
  if hover == nil then
    return style
  end

  return shared.merge_style_tables(style, hover)
end

---@param surface string|nil
---@param value any
---@return any
local function resolve_bar_hover_value(surface, value)
  if type(value) ~= "table" then
    return value
  end

  local resolved = hollow.util.clone_value(value)
  if type(resolved.style) == "table" then
    resolved.style = resolve_bar_hover_style(surface, resolved.style)
  end

  if resolved._type == nil then
    for index, item in ipairs(resolved) do
      resolved[index] = resolve_bar_hover_value(surface, item)
    end
  elseif resolved._type == "group" and type(resolved.children) == "table" then
    for index, child in ipairs(resolved.children) do
      resolved.children[index] = resolve_bar_hover_value(surface, child)
    end
  end

  return resolved
end

---@param value any
---@param fallback integer
---@return integer
local function normalize_px(value, fallback)
  local number = tonumber(value)
  if number == nil then
    return fallback
  end

  number = math.floor(number)
  if number < 0 then
    return 0
  end
  return number
end

---@param value any
---@return {top:integer,right:integer,bottom:integer,left:integer}
local function normalize_box(value)
  if type(value) == "number" then
    local px = normalize_px(value, 0)
    return { top = px, right = px, bottom = px, left = px }
  end

  if type(value) ~= "table" then
    return { top = 0, right = 0, bottom = 0, left = 0 }
  end

  local y = value.y or value.vertical
  local x = value.x or value.horizontal
  local top = value.top or y or value[1] or 0
  local right = value.right or x or value[2] or top
  local bottom = value.bottom or y or value[3] or top
  local left = value.left or x or value[4] or right
  return {
    top = normalize_px(top, 0),
    right = normalize_px(right, 0),
    bottom = normalize_px(bottom, 0),
    left = normalize_px(left, 0),
  }
end

---@param style any
---@return table|nil
local function serialize_bar_style(style)
  style = type(style) == "table" and style or nil
  if style == nil then
    return nil
  end

  local bg = shared.normalize_hex_color(style.bg, nil)
  local fg = shared.normalize_hex_color(style.fg, nil)
  local border = shared.normalize_hex_color(style.border, nil)
  local close_bg = shared.normalize_hex_color(style.close_bg, nil)
  local close_fg = shared.normalize_hex_color(style.close_fg, nil)
  local close_hover_bg = shared.normalize_hex_color(style.close_hover_bg, nil)
  local close_hover_fg = shared.normalize_hex_color(style.close_hover_fg, nil)
  local radius = normalize_px(style.radius, 0)
  local close_radius = normalize_px(style.close_radius, 0)
  local padding = normalize_box(style.padding)
  local margin = normalize_box(style.margin)
  local serialized = {}

  if bg ~= nil then
    serialized.bg = bg
  end
  if fg ~= nil then
    serialized.fg = fg
  end
  if border ~= nil then
    serialized.border = border
  end
  if close_bg ~= nil then
    serialized.close_bg = close_bg
  end
  if close_fg ~= nil then
    serialized.close_fg = close_fg
  end
  if close_hover_bg ~= nil then
    serialized.close_hover_bg = close_hover_bg
  end
  if close_hover_fg ~= nil then
    serialized.close_hover_fg = close_hover_fg
  end
  if radius > 0 then
    serialized.radius = radius
  end
  if close_radius > 0 then
    serialized.close_radius = close_radius
  end
  if style.bold == true then
    serialized.bold = true
  end
  if type(style.id) == "string" and style.id ~= "" then
    serialized.id = style.id
  end
  if padding.top > 0 or padding.right > 0 or padding.bottom > 0 or padding.left > 0 then
    serialized.padding = padding
  end
  if margin.top > 0 or margin.right > 0 or margin.bottom > 0 or margin.left > 0 then
    serialized.margin = margin
  end

  return next(serialized) ~= nil and serialized or nil
end

---@param style any
---@return table|nil
local function serialize_bar_text_style(style)
  style = type(style) == "table" and style or nil
  if style == nil then
    return nil
  end

  local serialized = {}
  local fg = shared.normalize_hex_color(style.fg, nil)
  local bg = shared.normalize_hex_color(style.bg, nil)
  if fg ~= nil then
    serialized.fg = fg
  end
  if bg ~= nil then
    serialized.bg = bg
  end
  if style.bold == true then
    serialized.bold = true
  end
  if type(style.id) == "string" and style.id ~= "" then
    serialized.id = style.id
  end

  return next(serialized) ~= nil and serialized or nil
end

---@param surface string|nil
---@param value any
---@param fallback_text string
---@param style any
---@return HollowUiSegment
local function serialize_bar_value(surface, value, fallback_text, style)
  value = resolve_bar_hover_value(surface, value)
  local resolved_style = resolve_bar_hover_style(surface, style)
  local merged_style = resolved_style
  local text_style = serialize_bar_text_style(resolved_style)
  if type(value) == "table" and type(value.style) == "table" then
    merged_style = shared.merge_style_tables(resolved_style, resolve_bar_hover_style(surface, value.style))
  end

  local segments = shared.bar_value_to_segments(value, fallback_text, text_style)
  local segment = shared.style_to_segment(shared.segments_plain_text(segments), merged_style)
  segment.segments = segments
  segment.style = serialize_bar_style(merged_style)
  return segment
end

---@param widget HollowUiWidget
---@return table
local function serialize_bar_layout(widget)
  local layout = type(widget.layout) == "table" and widget.layout or {}
  return {
    padding = normalize_box(layout.padding),
    margin = normalize_box(layout.margin),
  }
end

---@param widget HollowUiWidget
---@return table|nil
local function serialize_bar_widget_style(widget)
  local style = serialize_bar_style(widget.style)
  if type(style) ~= "table" then
    return nil
  end

  style.padding = nil
  style.margin = nil
  return next(style) ~= nil and style or nil
end

---@param surface string|nil
---@param node HollowUiBarTabsNode
---@param ctx HollowWidgetCtx
---@param handlers table<string, table<string, function>>
---@return HollowUiTabsLayout
local function serialize_tabs(surface, node, ctx, handlers)
  local tabs_list = ctx.term.tabs or {}
  if #tabs_list <= 1 and hollow.config.get("top_bar_mode") ~= "always" then
    return nil
  end
  local tabs = {}

  for _, tab in ipairs(tabs_list) do
    local tab_state = {
      id = tab.id,
      title = tab.title ~= "" and tab.title or "shell",
      index = tab.index,
      is_active = tab.is_active == true,
      is_hovered = false,
      pane = tab.pane,
      panes = tab.panes or {},
    }

    local style = node.style
    if type(style) == "function" then
      local ok, result = pcall(style, tab_state, ctx)
      style = ok and result or nil
    end
    style = resolve_bar_hover_style(surface, style)

    local label = tab_state.title
    if type(node.format) == "function" then
      local ok, result = pcall(node.format, tab_state, ctx)
      if ok then
        label = result
      end
    end

    if type(label) == "table" then
      for _, formatted_node in ipairs(shared.flatten_span_nodes(shared.normalize_inline_nodes(label))) do
        local formatted_style = formatted_node.style
        if type(formatted_style) == "table" and type(formatted_style.id) == "string" and formatted_style.id ~= "" then
          local entry = handlers[formatted_style.id] or {}
          for _, field in ipairs(BAR_EVENT_FIELDS) do
            if type(formatted_style[field]) == "function" then
              entry[field] = formatted_style[field]
            end
          end
          handlers[formatted_style.id] = entry
        end
      end
    end

    local segment = serialize_bar_value(surface, label, tab_state.title, style)
    tabs[#tabs + 1] = segment
  end

  return {
    kind = "tabs",
    fit = node.fit == "content" and "content" or "fill",
    style = serialize_bar_style(resolve_bar_hover_style(surface, node.style)),
    tabs = tabs,
  }
end

---@param surface string|nil
---@param node HollowUiBarWorkspaceNode
---@param ctx HollowWidgetCtx
---@return HollowUiSegment
local function serialize_workspace(surface, node, ctx)
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
    if ok then
      text = result
    end
  end

  local style = node.style
  if type(style) == "function" then
    local ok, result = pcall(style, workspace_state, ctx)
    style = ok and result or nil
  end
  style = resolve_bar_hover_style(surface, style)

  local segment = serialize_bar_value(surface, text, workspace_state.name, style)
  segment.kind = "segment"
  return segment
end

---@param surface string|nil
---@param node HollowUiBarTimeNode
---@return HollowUiSegment
local function serialize_time(surface, node)
  local style = resolve_bar_hover_style(surface, node.style)
  local segment = shared.style_to_segment(os.date(node.format or "%H:%M"), style)
  segment.kind = "segment"
  segment.style = serialize_bar_style(style)
  return segment
end

---@param surface string|nil
---@param node HollowUiBarKeyLegendNode
---@return HollowUiSegment
local function serialize_key_legend(surface, node)
  ---@type HollowLeaderState|nil
  local leader_state = hollow.keymap.get_leader_state()
  local text = ""
  if leader_state and leader_state.active and leader_state.next_display and #leader_state.next_display > 0 then
    text = " " .. table.concat(leader_state.next_display, "  ") .. " "
  end

  local style = resolve_bar_hover_style(surface, node.style)
  local segment = shared.style_to_segment(text, style)
  segment.kind = "segment"
  segment.style = serialize_bar_style(style)
  return segment
end

---@param surface string|nil
---@param node HollowUiBarCustomNode
---@param ctx HollowWidgetCtx
---@return HollowUiSegment|nil
local function serialize_custom(surface, node, ctx)
  local ok, rendered = pcall(node.render, ctx)
  if not ok then
    return nil
  end

  local segment
  if type(rendered) == "string" or type(rendered) == "table" then
    segment = serialize_bar_value(surface, rendered, "", node.style)
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

---@param surface string|nil
---@param node HollowUiBarSerializableNode|nil
---@param ctx HollowWidgetCtx
---@param handlers table<string, table<string, function>>
---@return HollowUiSegment|HollowUiTabsLayout|{kind:"spacer"}|nil
local function serialize_bar_item(surface, node, ctx, handlers)
  if type(node) ~= "table" then
    return nil
  end

  if node._type == "bar_tabs" then
    return serialize_tabs(surface, node, ctx, handlers)
  end
  if node._type == "bar_workspace" then
    return serialize_workspace(surface, node, ctx)
  end
  if node._type == "bar_time" then
    return serialize_time(surface, node)
  end
  if node._type == "bar_key_legend" then
    return serialize_key_legend(surface, node)
  end
  if node._type == "bar_custom" then
    return serialize_custom(surface, node, ctx)
  end
  if node._type == "spacer" then
    return { kind = "spacer" }
  end
  if shared.is_span_node(node) then
    local segment = serialize_bar_value(surface, node, node.text or node.name or "", node.style)
    segment.kind = "segment"
    return segment
  end

  return nil
end

---@param widget HollowUiWidget|nil
---@param surface string|nil
---@return {items:(HollowUiSegment|HollowUiTabsLayout|{kind:"spacer"})[],layout:table,style:table|nil}|nil
local function serialize_bar_widget(widget, surface)
  if widget == nil then
    return nil
  end

  local ctx = shared.widget_ctx()
  local items = shared.normalize_bar_items(shared.render_widget(widget))
  local serialized = {}
  local handlers = {}

  for _, item in ipairs(items) do
    local ok, value = pcall(serialize_bar_item, surface, item, ctx, handlers)
    if ok and value ~= nil then
      serialized[#serialized + 1] = value
    end
  end

  if surface == "topbar" then
    state.ui.topbar_handlers = handlers
  elseif surface == "bottombar" then
    state.ui.bottombar_handlers = handlers
  end

  return {
    items = serialized,
    layout = serialize_bar_layout(widget),
    style = serialize_bar_widget_style(widget),
  }
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
---@param payload any
---@return string|nil
local function bar_payload_node_id(surface, payload)
  if type(payload) ~= "table" then
    return nil
  end

  if type(payload.id) == "string" and payload.id ~= "" then
    return payload.id
  end

  local key = surface == "topbar" and "topbar_node" or surface == "bottombar" and "bottombar_node" or nil
  local node = key ~= nil and payload[key] or nil
  if type(node) == "table" and type(node.id) == "string" and node.id ~= "" then
    return node.id
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
  local handler_map = surface == "topbar" and state.ui.topbar_handlers or state.ui.bottombar_handlers
  if type(handler_map) == "table" then
    local entry = handler_map[node_id]
    if type(entry) == "table" and type(entry[field]) == "function" then
      entry[field](payload)
      return true
    end
  end

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
  local surface = kind:match("^(%a+bar):")
  if surface ~= "topbar" and surface ~= "bottombar" then
    return
  end

  local hovered_key = hovered_bar_id_key(surface)
  if hovered_key == nil then
    return
  end

  if kind == surface .. ":leave" then
    if state.ui[hovered_key] ~= nil then
      call_bar_node_handler(surface, state.ui[hovered_key], "on_mouse_leave", { id = state.ui[hovered_key] })
      state.ui[hovered_key] = nil
    end
    return
  end

  local node_id = bar_payload_node_id(surface, payload)
  if node_id == nil then
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

  if kind == surface .. ":click" then
    call_bar_node_handler(surface, node_id, "on_click", payload)
  end
end

function ui._topbar_state()
  return serialize_bar_widget(state.ui.mounted_topbar, "topbar")
end

function ui._bottombar_state()
  return serialize_bar_widget(state.ui.mounted_bottombar, "bottombar")
end

function ui._bottombar_layout()
  if state.ui.mounted_bottombar == nil then
    return nil
  end

  local widget = state.ui.mounted_bottombar
  local height = tonumber(widget.height) or 0
  local layout = serialize_bar_layout(widget)
  return {
    height = math.max(0, math.floor(height)),
    padding = layout.padding,
    margin = layout.margin,
  }
end

function ui._topbar_layout()
  if state.ui.mounted_topbar == nil then
    return nil
  end

  local widget = state.ui.mounted_topbar
  local height = tonumber(widget.height) or 0
  local layout = serialize_bar_layout(widget)
  return {
    height = math.max(0, math.floor(height)),
    padding = layout.padding,
    margin = layout.margin,
  }
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
