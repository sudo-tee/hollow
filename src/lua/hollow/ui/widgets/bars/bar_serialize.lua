local color = require("hollow.color")
local shared = require("hollow.ui.shared")
local hollow = _G.hollow
local state = require("hollow.state").get()
local tbl = hollow.tbl
local util = hollow.util
local cache = require("hollow.ui.widgets.bars.bar_cache")
local events = require("hollow.ui.widgets.bars.bar_events")
local modes = require("hollow.ui.widgets.bars.bottombar")
local M = {}
local resolve_bar_hover_value = events.resolve_value
local resolve_bar_hover_style = events.resolve_style
local register_bar_events = events.register
local current_time_ms = cache.current_time
local min_expiry = cache.min_expiry
local cache_is_valid = cache.is_valid
local bar_cache_payload = cache.payload
local set_bar_cache = cache.set
local copy_mode_state = modes.copy_mode_state
local quick_select_state = modes.quick_select_state
local leader_state = modes.leader_state
local visible_bar_item_count = modes.visible_item_count
local bar_auto_id_counter = 0

local function next_bar_auto_id()
  bar_auto_id_counter = bar_auto_id_counter + 1
  return "bar:auto:" .. bar_auto_id_counter
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

  local bg = color.normalize_hex_color(style.bg, nil)
  local fg = color.normalize_hex_color(style.fg, nil)
  local border = color.normalize_hex_color(style.border, nil)
  local close_bg = color.normalize_hex_color(style.close_bg, nil)
  local close_fg = color.normalize_hex_color(style.close_fg, nil)
  local close_hover_bg = color.normalize_hex_color(style.close_hover_bg, nil)
  local close_hover_fg = color.normalize_hex_color(style.close_hover_fg, nil)
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
  local fg = color.normalize_hex_color(style.fg, nil)
  local bg = color.normalize_hex_color(style.bg, nil)
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
    merged_style =
      shared.merge_style_tables(resolved_style, resolve_bar_hover_style(surface, value.style))
  end

  local segments = shared.bar_value_to_segments(value, fallback_text, text_style)
  local segment = shared.style_to_segment(shared.segments_plain_text(segments), merged_style)
  segment.segments = segments
  segment.style = serialize_bar_style(merged_style)
  return segment
end

---@param widget HollowUiWidget
---@return table
function M.layout(widget)
  local layout = type(widget.layout) == "table" and widget.layout or {}
  return {
    padding = normalize_box(layout.padding),
    margin = normalize_box(layout.margin),
  }
end

---@param widget HollowUiWidget
---@return {height:integer,padding:{top:integer,right:integer,bottom:integer,left:integer},margin:{top:integer,right:integer,bottom:integer,left:integer}}
function M.surface_layout(widget)
  local layout = M.layout(widget)
  return {
    height = math.max(0, math.floor(tonumber(widget.height) or 0)),
    padding = layout.padding,
    margin = layout.margin,
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

---@param text string
---@param width integer
---@return string
local function truncate_text_end(text, width)
  text = tostring(text or "")
  if width <= 0 then
    return ""
  end
  if util.utf8_len(text) <= width then
    return text
  end

  if utf8 and type(utf8.offset) == "function" then
    if width <= 3 then
      local byte_end = utf8.offset(text, width + 1)
      return byte_end and text:sub(1, byte_end - 1) or text
    end

    local byte_end = utf8.offset(text, width - 3 + 1)
    local prefix = byte_end and text:sub(1, byte_end - 1) or text
    return prefix .. "..."
  end

  return util.truncate_end(text, width)
end

---@param segments HollowUiSegment[]|nil
---@param width integer
---@return HollowUiSegment[]|nil
local function truncate_segments_end(segments, width)
  if type(segments) ~= "table" or width <= 0 then
    return nil
  end

  local out = {}
  local remaining = width
  for _, segment in ipairs(segments) do
    if remaining <= 0 then
      break
    end

    local text = tostring(segment.text or "")
    local seg_len = util.utf8_len(text)
    if seg_len == 0 then
      goto continue
    end

    local clipped = truncate_text_end(text, remaining)
    if clipped ~= "" then
      local copy = util.clone_value(segment)
      copy.text = clipped
      out[#out + 1] = copy
      remaining = remaining - util.utf8_len(clipped)
    end

    if util.utf8_len(clipped) < seg_len then
      break
    end

    ::continue::
  end

  return #out > 0 and out or nil
end

---@param segment HollowUiSegment
---@param width integer
---@return HollowUiSegment
local function clamp_tab_segment_width(segment, width)
  if width <= 0 then
    return segment
  end

  local text = truncate_text_end(segment.text or "", width)
  if text == segment.text then
    return segment
  end

  local clamped = util.clone_value(segment)
  clamped.text = text
  clamped.segments = truncate_segments_end(segment.segments, width)
  return clamped
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
  local tabs = tbl(tabs_list)
    :map(function(tab)
      local tab_state = {
        id = tab.id,
        title = tab.title ~= "" and tab.title,
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
        register_bar_events(label, handlers, next_bar_auto_id)
      end

      local segment = serialize_bar_value(surface, label, tab_state.title, style)
      if type(node.max_width) == "number" and node.max_width > 0 then
        segment = clamp_tab_segment_width(segment, math.floor(node.max_width))
      end
      return segment
    end)
    :get()

  return {
    kind = "tabs",
    fit = node.fit == "content" and "content" or "fill",
    max_width = type(node.max_width) == "number" and node.max_width or nil,
    style = serialize_bar_style(resolve_bar_hover_style(surface, node.style)),
    tabs = tabs,
  }
end

local function serialize_workspace(surface, node, ctx, handlers)
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

  local format_style = {}
  if type(text) == "table" then
    register_bar_events(text, handlers, next_bar_auto_id)
    tbl(shared.flatten_span_nodes(shared.normalize_inline_nodes(text))):each(function(n)
      local fs = n.style
      if type(fs) == "table" then
        if format_style.bg == nil and type(fs.bg) == "string" then
          format_style.bg = fs.bg
        end
        if format_style.fg == nil and type(fs.fg) == "string" then
          format_style.fg = fs.fg
        end
      end
    end)
  end

  local style = node.style
  if type(style) == "function" then
    local ok, result = pcall(style, workspace_state, ctx)
    style = ok and result or nil
  end
  style = resolve_bar_hover_style(surface, style)
  if format_style.bg ~= nil or format_style.fg ~= nil then
    style = shared.merge_style_tables(style, format_style)
  end

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
  local next_tick_ms = (math.floor(current_time_ms() / 1000) + 1) * 1000
  return segment, next_tick_ms
end

---@param surface string|nil
---@param node HollowUiBarKeyLegendNode
---@return HollowUiSegment
local function serialize_key_legend(surface, node)
  local copy_mode = copy_mode_state()
  if copy_mode ~= nil or quick_select_state() ~= nil then
    return nil, nil
  end

  ---@type HollowLeaderState|nil
  local leader_state = leader_state()
  local text = ""
  if
    leader_state
    and leader_state.active
    and leader_state.next_display
    and #leader_state.next_display > 0
  then
    text = " " .. table.concat(leader_state.next_display, "  ") .. " "
  end

  local style = resolve_bar_hover_style(surface, node.style)
  local segment = shared.style_to_segment(text, style)
  segment.kind = "segment"
  segment.style = serialize_bar_style(style)
  local expires_at = leader_state
      and leader_state.active
      and (current_time_ms() + math.max(1, tonumber(leader_state.remaining_ms) or 0))
    or nil
  return segment, expires_at
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

  local expires_at = type(node.cache_ttl_ms) == "number"
      and current_time_ms() + math.max(1, math.floor(node.cache_ttl_ms))
    or nil
  return segment, expires_at
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
    return serialize_tabs(surface, node, ctx, handlers), nil
  end
  if node._type == "bar_workspace" then
    return serialize_workspace(surface, node, ctx, handlers), nil
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
    return { kind = "spacer" }, nil
  end
  if shared.is_span_node(node) then
    local segment = serialize_bar_value(surface, node, node.text or node.name or "", node.style)
    segment.kind = "segment"
    return segment, nil
  end

  return nil, nil
end

---@param widget HollowUiWidget|nil
---@param surface string|nil
---@return {items:(HollowUiSegment|HollowUiTabsLayout|{kind:"spacer"})[],layout:table,style:table|nil}|nil
function M.serialize(widget, surface)
  if cache_is_valid(surface) then
    return bar_cache_payload(surface)
  end

  bar_auto_id_counter = 0
  local ctx = shared.widget_ctx()
  local items = shared.normalize_bar_items(shared.render_widget(widget))
  local handlers = {}
  local expires_at = nil
  local layout = M.layout(widget)
  local surface_layout = M.surface_layout(widget)

  local serialized = tbl(items)
    :filter_map(function(item)
      local ok, value, item_expires_at = pcall(serialize_bar_item, surface, item, ctx, handlers)
      if ok and value ~= nil then
        expires_at = min_expiry(expires_at, item_expires_at)
        return value
      end
    end)
    :get()

  local visible_items = visible_bar_item_count(serialized)

  -- Handler maps are state.ui mailbox shared with bar_events.
  if surface == "topbar" then
    state.ui.topbar_handlers = handlers
  elseif surface == "bottombar" then
    state.ui.bottombar_handlers = handlers
  end

  if visible_items == 0 then
    return set_bar_cache(surface, nil, nil, expires_at)
  end

  return set_bar_cache(surface, {
    items = serialized,
    layout = layout,
    style = serialize_bar_widget_style(widget),
  }, surface_layout, expires_at)
end
return M
