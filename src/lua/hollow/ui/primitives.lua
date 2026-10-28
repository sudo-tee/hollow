local shared = require("hollow.ui.shared")
local util = require("hollow.util")

---@type Hollow
local hollow = _G.hollow
---@type HollowUi
local ui = hollow.ui
ui.style = shared.merge_styles

---@type HollowUiStylePresets
ui.styles = {
  muted = { fg = "muted" },
  title = { fg = "title", bold = true },
  pill = { radius = 4, padding = { x = 4 } },
  badge = { fg = "panel_bg", bold = true, radius = 4, padding = { x = 5, y = 1 } },
  kbd = { fg = "fg", bg = "input_bg", radius = 3, padding = { x = 4 } },
}

local bar = ui.bar or {}
ui.bar = bar

--- Whether the Hollow window, not merely its active pane, has OS focus.
function ui.is_focused()
  local state = require("hollow.state").get()
  if state.host_api.window_is_focused then
    local focused = state.host_api.window_is_focused()
    if focused ~= nil then
      return focused
    end
  end
  return state.ui.window_focused ~= false
end

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

---@param children HollowUiChild[]|nil
---@param style HollowUiNodeStyle|HollowHexColor|nil
---@return HollowUiGroupNode
function ui.group(children, style)
  local normalized = shared.collect_inline(children or {}, "hollow.ui.group()", true)
  return { _type = "group", children = normalized, style = style }
end

--- Select a branch, evaluating it only if it is a function.
---@param cond any
---@param then_ any
---@param else_ any
---@return any
function ui.when(cond, then_, else_)
  local value = cond and then_ or else_
  if type(value) == "function" then
    value = value()
  end
  return value or false
end

--- Map a list into a fragment, preserving indices for falsy results.
---@generic T
---@param list T[]|HollowTbl|nil
---@param fn fun(item: T, i: integer): any
---@return any[]
function ui.each(list, fn)
  local out = {}
  if list == nil then
    return out
  end
  if type(list.get) == "function" then
    list = list:get()
  end
  for i, item in ipairs(list) do
    out[i] = fn(item, i) or false
  end
  return out
end

--- Join truthy items into a fragment. Function separators receive their 1-based separator index.
---@param items any[]
---@param sep any|fun(i: integer): any
---@return any[]
function ui.join(items, sep)
  local out = {}
  local count = 0
  for i = 1, table.maxn(items) do
    local item = items[i]
    if item then
      if count > 0 then
        local separator = sep
        if type(sep) == "function" then
          separator = sep(count)
        end
        out[#out + 1] = separator
      end
      out[#out + 1] = item
      count = count + 1
    end
  end
  return out
end

---@param children HollowUiChild[]
---@param opts HollowUiRowOptions|nil
---@return HollowUiRowNode
function ui.row(children, opts)
  if type(children) ~= "table" or shared.is_inline_node(children) then
    error("hollow.ui.row() expects a list of inline children")
  end

  opts = opts or {}
  local nodes = shared.collect_inline(children, "hollow.ui.row()", true)

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
    fill_radius = opts.fill_radius,
    accent_bar = opts.accent_bar,
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

---@param children HollowUiRowChild[]
---@return HollowUiColumnNode
function ui.column(children)
  if type(children) ~= "table" then
    error("hollow.ui.column() expects a list of rows")
  end

  local rows = shared.collect_rows(children, "hollow.ui.column()")
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

  local style = type(opts.style) == "table" and clone_table(opts.style) or {}
  style.id = opts.id
  style.on_click = opts.on_click
  style.on_mouse_enter = opts.on_mouse_enter
  style.on_mouse_leave = opts.on_mouse_leave

  return ui.span(opts.text or "", style)
end

local function select_theme(opts)
  return opts.theme or shared.palette("select")
end

--- Merge style layers like `ui.style`, then resolve tokens against `theme`.
--- Without a theme, tokens stay unresolved for serialization.
---@param theme table|nil
---@vararg HollowUiNodeStyle|false|nil
---@return HollowUiNodeStyle
function ui.themed_style(theme, ...)
  local style = ui.style(...)
  return theme and shared.resolve_tokens(style, theme) or style
end

--- Compatibility alias for the original helper name.
ui.styled = ui.themed_style

local TAB = { fg = "muted", bold = false, radius = 4, padding = { x = 8, y = 3 } }
local TAB_ACTIVE = { fg = "selection_fg", bg = "selection_bg", bold = true }
local TAB_BADGED = { padding = { right = 0 } }
local TAB_ACTIVE_BADGED = { background_extend = 2 }
local ACTION = {
  fg = "fg",
  radius = 4,
  padding = { left = 4, right = 4 },
  hover = { fg = "hover_fg", bg = "hover_bg" },
}

--- A padded overlay action with theme-aware hover styling.
---@param opts HollowUiActionButtonOptions
---@return HollowUiSpanNode
function ui.action_button(opts)
  opts = opts or {}
  local theme = select_theme(opts)
  local style = ui.style(ACTION)
  local hover = style.hover
  for key, value in pairs(opts.style or {}) do
    if key ~= "hover" then
      style[key] = util.clone_value(value)
    elseif type(value) == "table" then
      hover = shared.merge_styles(hover, value)
    else
      hover = value
    end
  end
  if type(opts.hover_style) == "table" then
    hover = shared.merge_styles(hover, opts.hover_style)
    if opts.hover_style.padding ~= nil then
      -- Legacy hover overrides replace the whole box, rather than inherit its sides.
      hover.padding = shared.normalize_segment_padding(opts.hover_style.padding)
    end
  end
  style.hover = hover
  style = shared.resolve_tokens(style, theme)
  return ui.button({
    id = opts.id,
    text = opts.text,
    style = style,
    on_click = opts.on_click,
    on_mouse_enter = opts.on_mouse_enter,
    on_mouse_leave = opts.on_mouse_leave,
  })
end

--- A selectable tab with an optional count badge.
---@param opts HollowUiTabOptions
---@return HollowUiGroupNode
function ui.tab(opts)
  local theme = select_theme(opts)
  local active = opts.active == true
  local badge = opts.badge
  return ui.group({
    ui.button({
      id = opts.id,
      text = badge and (opts.label .. " ") or opts.label,
      style = ui.themed_style(
        theme,
        TAB,
        active and TAB_ACTIVE,
        badge and TAB_BADGED,
        active and badge and TAB_ACTIVE_BADGED
      ),
      on_click = opts.on_click,
    }),
    ui.when(badge, function()
      return {
        ui.button({
          id = opts.id .. ":badge",
          text = tostring(badge.text),
          style = ui.themed_style(theme, ui.styles.badge, { bg = badge.color }),
          on_click = opts.on_click,
        }),
        " ",
      }
    end),
  })
end

--- Compose tabs with consistent spacing.
---@param opts HollowUiTabBarOptions
---@return HollowUiGroupNode
function ui.tab_bar(opts)
  return ui.group(ui.join(
    ui.each(opts.tabs or {}, function(tab)
      local tab_opts = util.clone_value(tab)
      tab_opts.theme = tab_opts.theme or opts.theme
      return ui.tab(tab_opts)
    end),
    "  "
  ))
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
    style = opts.style,
    render = opts.render,
    cache_ttl_ms = opts.cache_ttl_ms,
    on_click = opts.on_click,
    on_mouse_enter = opts.on_mouse_enter,
    on_mouse_leave = opts.on_mouse_leave,
  }
end
