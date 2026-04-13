local util = require("hollow.util")
local shared = require("hollow.ui.shared")

---@type Hollow
local hollow = _G.hollow
---@type HollowUi
local ui = hollow.ui
local table_unpack = table.unpack or unpack

local overlay_row = ui.overlay_row or {}
ui.overlay_row = overlay_row

local bar = ui.bar or {}
ui.bar = bar

---@param value any
---@return HollowUiNodeStyle
local function clone_table(value)
  return util.clone_value(value or {})
end

---@param props any
---@param args any[]
---@return HollowUiTagProps, any[]
local function normalize_tag_call(props, args)
  if props == nil then
    return {}, args
  end

  if type(props) ~= "table" or shared.is_inline_node(props) then
    return {}, { props, table_unpack(args) }
  end

  return props, args
end

---@param children any[]
---@return boolean
local function is_single_text_child(children)
  if #children > 1 then
    return false
  end

  local child = children[1]
  return type(child) == "string"
    or type(child) == "number"
    or child == nil
    or shared.is_text_shorthand(child)
    or shared.is_span_node(child)
end

---@param children any[]
---@param style HollowUiNodeStyle|HollowHexColor|nil
---@return HollowUiGroupNode
local function group_from_children(children, style)
  return ui.group(ui.row(table_unpack(children)), style)
end

---@param name string
---@param props HollowUiTagProps
---@param children any[]
---@return any
local function build_tag_node(name, props, children)
  if name == "spacer" then
    return ui.spacer()
  end

  if name == "icon" then
    return ui.icon(props.name or children[1] or "", props.style or props)
  end

  if name == "row" then
    return ui.row(table_unpack(children))
  end

  if name == "rows" then
    return ui.rows(table_unpack(children))
  end

  if name == "group" then
    return group_from_children(children, props.style or props)
  end

  if name == "button" then
    local button_opts = clone_table(props)
    if button_opts.text == nil then
      button_opts.text = shared.nodes_plain_text(children)
    end
    return ui.button(button_opts)
  end

  if name == "span" or name == "text" then
    if is_single_text_child(children) then
      return ui.text(children[1] or "", props.style or props)
    end
    return group_from_children(children, props.style or props)
  end

  return group_from_children(children, props.style or props)
end

---@param props HollowUiTagProps
---@return HollowUiOverlayRowOptions
local function overlay_row_options(props)
  return {
    fill_bg = props.fill_bg,
    divider = props.divider,
    scrollbar_track = props.scrollbar_track,
    scrollbar_thumb = props.scrollbar_thumb,
    scrollbar_track_color = props.scrollbar_track_color,
    scrollbar_thumb_color = props.scrollbar_thumb_color,
  }
end

---@param props HollowUiTagProps
---@return HollowUiOverlayRow
local function build_overlay_row(props)
  -- Preserve the leading padding segment used by existing overlays.
  return overlay_row.make(ui.row(" ", table_unpack(props.children or {})), overlay_row_options(props))
end

---@param props HollowUiTagProps
---@return HollowUiOverlayRow
local function build_overlay_divider(props)
  return overlay_row.make({}, { divider = props.color or props.divider })
end

---@param opts HollowUiBarNodeOptionsBase|nil
---@return HollowUiBarNodeOptionsBase
local function make_bar_node(opts)
  return opts or {}
end

---@param nodes HollowUiRenderableNode[]|nil
---@param opts HollowUiOverlayRowOptions|nil
---@return HollowUiOverlayRow
function overlay_row.make(nodes, opts)
  opts = opts or {}
  return {
    _overlay_row = true,
    nodes = nodes or {},
    fill_bg = opts.fill_bg,
    divider = opts.divider,
    scrollbar_track = opts.scrollbar_track == true,
    scrollbar_thumb = opts.scrollbar_thumb == true,
    scrollbar_track_color = opts.scrollbar_track_color,
    scrollbar_thumb_color = opts.scrollbar_thumb_color,
  }
end

---@param row any
---@return HollowUiRenderableNode[]
function overlay_row.nodes(row)
  if type(row) == "table" and row._overlay_row == true then
    return row.nodes or {}
  end

  return row or {}
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
  return { _type = "group", children = children or {}, style = style }
end

---@param ... any
---@return HollowUiRenderableNode[]
function ui.row(...)
  local row = {}

  for _, value in ipairs({ ... }) do
    for _, node in ipairs(shared.normalize_inline_nodes(value)) do
      row[#row + 1] = node
    end
  end

  return row
end

---@param value any
---@param rows HollowUiRows
local function append_rows(value, rows)
  if value == nil or value == false or type(value) ~= "table" then
    return
  end

  if value._overlay_row == true then
    rows[#rows + 1] = value
    return
  end

  local first = value[1]
  if type(first) == "string" or shared.is_inline_node(first) then
    rows[#rows + 1] = value
    return
  end

  for _, item in ipairs(value) do
    append_rows(item, rows)
  end
end

---@param ... any
---@return HollowUiRows
function ui.rows(...)
  local rows = {}

  for _, value in ipairs({ ... }) do
    append_rows(value, rows)
  end

  return rows
end

---@param opts HollowUiButtonOptions|nil
---@return HollowUiSpanNode
function ui.button(opts)
  opts = opts or {}

  local style = clone_table(opts.style)
  style.id = opts.id
  style.on_click = opts.on_click
  style.on_mouse_enter = opts.on_mouse_enter
  style.on_mouse_leave = opts.on_mouse_leave

  return ui.span(opts.text or "", style)
end

---@type HollowUiTags
ui.tags = setmetatable({}, {
  __index = function(_, name)
    return function(props, ...)
      local normalized_props, children = normalize_tag_call(props, { ... })
      return build_tag_node(name, normalized_props, children)
    end
  end,
})

ui.tags.overlay_row = function(props, ...)
  local normalized_props = type(props) == "table" and props or {}
  normalized_props.children = { ... }
  return build_overlay_row(normalized_props)
end

ui.tags.divider = function(props)
  return build_overlay_divider(type(props) == "table" and props or {})
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
    on_click = opts.on_click,
    on_mouse_enter = opts.on_mouse_enter,
    on_mouse_leave = opts.on_mouse_leave,
  }
end
