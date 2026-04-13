local util   = require("hollow.util")
local shared = require("hollow.ui.shared")

local hollow = _G.hollow
local table_unpack = table.unpack or unpack

-- ---------------------------------------------------------------------------
-- overlay_row: internal row container for overlay widgets
-- ---------------------------------------------------------------------------

local overlay_row = hollow.ui.overlay_row or {}
hollow.ui.overlay_row = overlay_row

function overlay_row.make(nodes, opts)
  opts = opts or {}
  return {
    _overlay_row        = true,
    nodes               = nodes or {},
    fill_bg             = opts.fill_bg,
    divider             = opts.divider,
    scrollbar_track     = opts.scrollbar_track == true,
    scrollbar_thumb     = opts.scrollbar_thumb == true,
    scrollbar_track_color = opts.scrollbar_track_color,
    scrollbar_thumb_color = opts.scrollbar_thumb_color,
  }
end

function overlay_row.nodes(row)
  if type(row) == "table" and row._overlay_row == true then return row.nodes or {} end
  return row or {}
end

-- ---------------------------------------------------------------------------
-- Primitive node constructors
-- ---------------------------------------------------------------------------

function hollow.ui.span(text, style)
  return { _type = "span", text = text, style = style }
end

function hollow.ui.text(value, style)
  if style == nil and shared.is_text_shorthand(value) then return shared.normalize_text_shorthand(value) end
  if style == nil and shared.is_span_node(value)       then return value end
  return hollow.ui.span(tostring(value or ""), style)
end

function hollow.ui.spacer() return { _type = "spacer" } end

function hollow.ui.icon(name, style)
  return { _type = "icon", name = tostring(name or ""), style = style }
end

function hollow.ui.group(children, style)
  return { _type = "group", children = children or {}, style = style }
end

function hollow.ui.row(...)
  local row = {}
  for _, value in ipairs({ ... }) do
    for _, node in ipairs(shared.normalize_inline_nodes(value)) do
      row[#row + 1] = node
    end
  end
  return row
end

function hollow.ui.rows(...)
  local rows = {}
  local function push(value)
    if value == nil or value == false then return end
    if type(value) ~= "table" then return end
    if value._overlay_row == true then rows[#rows + 1] = value; return end
    local first = value[1]
    if type(first) == "string" or shared.is_inline_node(first) then rows[#rows + 1] = value; return end
    for _, item in ipairs(value) do push(item) end
  end
  for _, value in ipairs({ ... }) do push(value) end
  return rows
end

function hollow.ui.button(opts)
  opts = opts or {}
  local style = util.clone_value(opts.style or {})
  style.id            = opts.id
  style.on_click      = opts.on_click
  style.on_mouse_enter = opts.on_mouse_enter
  style.on_mouse_leave = opts.on_mouse_leave
  return hollow.ui.span(opts.text or "", style)
end

-- ---------------------------------------------------------------------------
-- tags: JSX-style shorthand  t.overlay_row(props, ...) / t.text({fg=...}, "hi")
-- ---------------------------------------------------------------------------

local function OverlayRow(props)
  local opts = {
    fill_bg              = props.fill_bg,
    divider              = props.divider,
    scrollbar_track      = props.scrollbar_track,
    scrollbar_thumb      = props.scrollbar_thumb,
    scrollbar_track_color = props.scrollbar_track_color,
    scrollbar_thumb_color = props.scrollbar_thumb_color,
  }
  return overlay_row.make(hollow.ui.row(" ", table_unpack(props.children or {})), opts)
end

local function OverlayDivider(props)
  return overlay_row.make({}, { divider = props.color or props.divider })
end

hollow.ui.tags = setmetatable({}, {
  __index = function(_, name)
    return function(props, ...)
      local args = { ... }
      local children
      if props == nil then
        children = args
        props    = {}
      elseif type(props) ~= "table" or shared.is_inline_node(props) then
        children = { props, table_unpack(args) }
        props    = {}
      else
        children = args
      end

      if name == "spacer" then
        return hollow.ui.spacer()
      elseif name == "icon" then
        return hollow.ui.icon(props.name or children[1] or "", props.style or props)
      elseif name == "row" then
        return hollow.ui.row(table_unpack(children))
      elseif name == "rows" then
        return hollow.ui.rows(table_unpack(children))
      elseif name == "group" then
        return hollow.ui.group(hollow.ui.row(table_unpack(children)), props.style or props)
      elseif name == "button" then
        local button_opts = util.clone_value(props)
        if button_opts.text == nil then button_opts.text = shared.nodes_plain_text(children) end
        return hollow.ui.button(button_opts)
      elseif name == "span" or name == "text" then
        if #children <= 1 and (
          type(children[1]) == "string" or type(children[1]) == "number"
          or children[1] == nil or shared.is_text_shorthand(children[1])
          or shared.is_span_node(children[1])
        ) then
          return hollow.ui.text(children[1] or "", props.style or props)
        end
        return hollow.ui.group(hollow.ui.row(table_unpack(children)), props.style or props)
      end

      return hollow.ui.group(hollow.ui.row(table_unpack(children)), props.style or props)
    end
  end,
})

hollow.ui.tags.overlay_row = function(props, ...)
  props = type(props) == "table" and props or {}
  props.children = { ... }
  return OverlayRow(props)
end

hollow.ui.tags.divider = function(props)
  props = type(props) == "table" and props or {}
  return OverlayDivider(props)
end

-- ---------------------------------------------------------------------------
-- Bar node constructors
-- ---------------------------------------------------------------------------

hollow.ui.bar = hollow.ui.bar or {}

function hollow.ui.bar.tabs(opts)
  opts = opts or {}; opts._type = "bar_tabs"; return opts
end

function hollow.ui.bar.workspace(opts)
  opts = opts or {}; opts._type = "bar_workspace"; return opts
end

function hollow.ui.bar.time(fmt, opts)
  opts = opts or {}; opts._type = "bar_time"; opts.format = fmt; return opts
end

function hollow.ui.bar.key_legend(opts)
  opts = opts or {}; opts._type = "bar_key_legend"; return opts
end

function hollow.ui.bar.custom(opts)
  opts = opts or {}
  if type(opts.render) ~= "function" then error("hollow.ui.bar.custom(opts) expects opts.render") end
  return {
    _type          = "bar_custom",
    id             = opts.id,
    render         = opts.render,
    on_click       = opts.on_click,
    on_mouse_enter = opts.on_mouse_enter,
    on_mouse_leave = opts.on_mouse_leave,
  }
end
