local shared = require("hollow.ui.shared")
local util = require("hollow.util")

---@type Hollow
local hollow = _G.hollow
---@type HollowUi
local ui = hollow.ui

local bar = ui.bar or {}
ui.bar = bar

---@param value any
---@return HollowUiNodeStyle
local function clone_table(value)
  return util.clone_value(value or {})
end

---@param opts HollowUiBarNodeOptionsBase|nil
---@return HollowUiBarNodeOptionsBase
local function make_bar_node(opts)
  return opts or {}
end

---@param text any
---@param style HollowUiNodeStyle|HollowHexColor|nil
---@return HollowUiSpanNode
function ui.span(text, style)
  return { _type = "span", text = text, style = style }
end

---@param value any
---@param style HollowUiNodeStyle|HollowHexColor|nil
---@return HollowUiSpanNode|HollowUiRenderableNode
function ui.text(value, style)
  if style == nil and shared.is_text_shorthand(value) then
    return shared.normalize_text_shorthand(value)
  end

  if style == nil and shared.is_span_node(value) then
    return value
  end

  return ui.span(tostring(value or ""), style)
end

---@return HollowUiSpacerNode
function ui.spacer()
  return { _type = "spacer" }
end

---@param name any
---@param style HollowUiNodeStyle|HollowHexColor|nil
---@return HollowUiIconNode
function ui.icon(name, style)
  return { _type = "icon", name = tostring(name or ""), style = style }
end

---@param children HollowUiRenderableNode[]|nil
---@param style HollowUiNodeStyle|HollowHexColor|nil
---@return HollowUiGroupNode
function ui.group(children, style)
  local normalized = {}
  for _, child in ipairs(children or {}) do
    for _, node in ipairs(shared.normalize_inline_nodes(child)) do
      normalized[#normalized + 1] = node
    end
  end
  return { _type = "group", children = normalized, style = style }
end

---@param children HollowUiInlineNode[]
---@param opts HollowUiRowOptions|nil
---@return HollowUiRowNode
function ui.row(children, opts)
  if type(children) ~= "table" or shared.is_inline_node(children) then
    error("hollow.ui.row() expects a list of inline children")
  end

  opts = opts or {}
  local nodes = {}
  for _, value in ipairs(children) do
    for _, node in ipairs(shared.normalize_inline_nodes(value)) do
      nodes[#nodes + 1] = node
    end
  end

  local hoverable = opts.hoverable
  if hoverable == nil then
    hoverable = opts.id ~= nil
  end

  return {
    _type = "row",
    children = nodes,
    id = opts.id,
    hoverable = hoverable == true,
    fill_bg = opts.fill_bg,
    divider = opts.divider,
    scrollbar_track = opts.scrollbar_track == true,
    scrollbar_thumb = opts.scrollbar_thumb == true,
    scrollbar_id = opts.scrollbar_id,
    scrollbar_thumb_ratio = opts.scrollbar_thumb_ratio,
    scrollbar_thumb_size = opts.scrollbar_thumb_size,
    scrollbar_track_color = opts.scrollbar_track_color,
    scrollbar_thumb_color = opts.scrollbar_thumb_color,
  }
end

---@param children HollowUiRowNode[]
---@return HollowUiColumnNode
function ui.column(children)
  if type(children) ~= "table" then
    error("hollow.ui.column() expects a list of rows")
  end

  local rows = {}
  for _, child in ipairs(children) do
    if type(child) ~= "table" or child._type ~= "row" then
      error("hollow.ui.column() children must be ui.row() or ui.divider() nodes")
    end
    rows[#rows + 1] = child
  end
  return { _type = "column", children = rows }
end

---@param color HollowColor|nil
---@return HollowUiRowNode
function ui.divider(color)
  return ui.row({}, { divider = color, hoverable = false })
end

---@param opts HollowUiButtonOptions|nil
---@return HollowUiSpanNode
function ui.button(opts)
  opts = opts or {}
  if type(opts.on_click) == "function" and (type(opts.id) ~= "string" or opts.id == "") then
    error("hollow.ui.button() requires an id when on_click is set")
  end

  local style = opts.style
  if type(style) == "table" then
    style = clone_table(style)
    style.id = opts.id
    style.on_click = opts.on_click
    style.on_mouse_enter = opts.on_mouse_enter
    style.on_mouse_leave = opts.on_mouse_leave
  else
    style = {
      id = opts.id,
      on_click = opts.on_click,
      on_mouse_enter = opts.on_mouse_enter,
      on_mouse_leave = opts.on_mouse_leave,
    }
  end

  return ui.span(opts.text or "", style)
end

---@param opts HollowUiBarTabsOptions|nil
---@return HollowUiBarTabsNode
function bar.tabs(opts)
  opts = make_bar_node(opts)
  opts._type = "bar_tabs"
  return opts
end

---@param opts HollowUiBarWorkspaceOptions|nil
---@return HollowUiBarWorkspaceNode
function bar.workspace(opts)
  opts = make_bar_node(opts)
  opts._type = "bar_workspace"
  return opts
end

---@param fmt string|nil
---@param opts HollowUiBarTimeOptions|nil
---@return HollowUiBarTimeNode
function bar.time(fmt, opts)
  opts = make_bar_node(opts)
  opts._type = "bar_time"
  opts.format = fmt
  return opts
end

---@param opts HollowUiBarKeyLegendOptions|nil
---@return HollowUiBarKeyLegendNode
function bar.key_legend(opts)
  opts = make_bar_node(opts)
  opts._type = "bar_key_legend"
  return opts
end

---@param opts HollowUiBarCustomOptions|nil
---@return HollowUiBarCustomNode
function bar.custom(opts)
  opts = opts or {}
  if type(opts.render) ~= "function" then
    error("hollow.ui.bar.custom(opts) expects opts.render")
  end

  return {
    _type = "bar_custom",
    id = opts.id,
    render = opts.render,
    cache_ttl_ms = opts.cache_ttl_ms,
    on_click = opts.on_click,
    on_mouse_enter = opts.on_mouse_enter,
    on_mouse_leave = opts.on_mouse_leave,
  }
end
