local box = require("hollow.ui.style.box")
local color = require("hollow.color")
local list_row_styles = require("hollow.ui.styles.list_row")
local panel_styles = require("hollow.ui.styles.panel")
local sheet = require("hollow.ui.style.sheet")
local state = require("hollow.state").get()
local theme_api = require("hollow.theme")
local tokens = require("hollow.ui.style.tokens")
local util = require("hollow.util")

local hollow = _G.hollow
local host_api = state.host_api

local M = {}
local palettes = {}
local cached_bar_palette

-- Open widgets keep palette/chrome references. Refresh their contents on theme
-- changes, without retaining closed widgets or resolving a theme per span.
local live_palettes = setmetatable({}, { __mode = "k" })
local live_chrome = setmetatable({}, { __mode = "k" })
local function replace_contents(target, source)
  for key in pairs(target) do
    if source[key] == nil then
      target[key] = nil
    end
  end
  for key, value in pairs(source) do
    if type(value) == "table" and type(target[key]) == "table" then
      replace_contents(target[key], value)
    else
      target[key] = util.clone_value(value)
    end
  end
end

local function build_widget_palette(spec)
  local palette = theme_api.resolve_widget(spec.kind)
  if spec.decorate then
    spec.decorate(palette)
  end
  util.merge_tables(palette, util.clone_value(spec.overrides))
  if
    spec.overrides.button_emphasis_bg == nil
    and (spec.overrides.selected_bg ~= nil or spec.overrides.panel_bg ~= nil)
  then
    palette.button_emphasis_bg =
      color.brighten_hex_color(palette.selected_bg, 0.25, palette.panel_bg)
  end
  return palette
end

function M.widget_theme(kind, overrides, decorate)
  local spec = {
    kind = kind,
    overrides = type(overrides) == "table" and util.clone_value(overrides) or {},
    decorate = decorate,
  }
  local palette = build_widget_palette(spec)
  live_palettes[palette] = spec
  return palette
end

function M.invalidate_palettes()
  palettes = {}
  cached_bar_palette = nil
  for palette, spec in pairs(live_palettes) do
    replace_contents(palette, build_widget_palette(spec))
  end
  for chrome, build in pairs(live_chrome) do
    replace_contents(chrome, build() or {})
  end
end

---@param kind string|nil
---@return HollowUiTheme
function M.palette(kind)
  kind = kind or "all"
  if not palettes[kind] then
    palettes[kind] = theme_api.resolve_widget(kind)
  end
  return palettes[kind]
end

---@return HollowUiTheme
function M.bar_palette()
  if not cached_bar_palette then
    local ui = M.resolve_theme().ui
    local tabs = ui.tab_bar
    cached_bar_palette = util.clone_value(M.palette("all"))
    local bar = {
      bar_bg = ui.top_bar.background,
      bar_fg = ui.status.fg,
      status_bg = ui.status.bg,
      status_fg = ui.status.fg,
      tab_bar_bg = tabs.background,
      tab_active_fg = tabs.active_tab.fg,
      tab_active_bg = tabs.active_tab.bg,
      tab_inactive_fg = tabs.inactive_tab.fg,
      tab_inactive_bg = tabs.inactive_tab.bg,
      tab_hover_fg = tabs.hover_tab.fg,
      tab_hover_bg = tabs.hover_tab.bg,
      accent = ui.accent,
      warm = ui.warm,
    }
    for key, value in pairs(bar) do
      cached_bar_palette[key] = value
    end
  end
  return cached_bar_palette
end

local resolve_color = tokens.resolve_color
local resolve_owned_tokens = tokens.resolve_owned

---@generic T: table
---@overload fun(style: nil, palette: HollowUiTheme): HollowUiNodeStyle
---@param style T
---@param palette HollowUiTheme
---@return T
M.resolve_tokens = tokens.resolve

local SPAN_NODE_TYPES = {
  span = true,
  spacer = true,
  icon = true,
  group = true,
}

local DIGIT_SHIFT_MAP = {
  ["1"] = "!",
  ["2"] = "@",
  ["3"] = "#",
  ["4"] = "$",
  ["5"] = "%",
  ["6"] = "^",
  ["7"] = "&",
  ["8"] = "*",
  ["9"] = "(",
  ["0"] = ")",
}

local SPECIAL_PRINTABLE_KEYS = {
  space = function()
    return " "
  end,
  minus = function(shifted)
    return shifted and "_" or "-"
  end,
  equal = function(shifted)
    return shifted and "+" or "="
  end,
  bracket_left = function(shifted)
    return shifted and "{" or "["
  end,
  bracket_right = function(shifted)
    return shifted and "}" or "]"
  end,
  backslash = function(shifted)
    return shifted and "|" or "\\"
  end,
  semicolon = function(shifted)
    return shifted and ":" or ";"
  end,
  quote = function(shifted)
    return shifted and '"' or "'"
  end,
  backquote = function(shifted)
    return shifted and "~" or "`"
  end,
  comma = function(shifted)
    return shifted and "<" or ","
  end,
  period = function(shifted)
    return shifted and ">" or "."
  end,
  slash = function(shifted)
    return shifted and "?" or "/"
  end,
}

local OVERLAY_ALIGN_ALIASES = {
  right = "top_right",
  left = "top_left",
  bottom = "bottom_center",
  top = "top_center",
  centre = "center",
  middle = "center",
}

local ALLOWED_OVERLAY_ALIGN = {
  center = true,
  top_left = true,
  top_center = true,
  top_right = true,
  left_center = true,
  right_center = true,
  bottom_left = true,
  bottom_center = true,
  bottom_right = true,
}

local DEFAULT_BACKDROP = { color = "#000000", alpha = 170 }

---@param value any
---@return HollowUiNodeStyle|nil
local function optional_table(value)
  return type(value) == "table" and value or nil
end

---@param value any
---@return HollowUiNodeStyle
local function clone_table(value)
  return util.clone_value(value or {})
end

---@param base HollowUiNodeStyle|nil
---@param overlay HollowUiNodeStyle|nil
---@return HollowUiNodeStyle
local function merged_clone(base, overlay)
  local result = clone_table(base)
  if type(overlay) == "table" then
    util.merge_tables(result, overlay)
  end
  return result
end

---@return HollowResolvedTheme
function M.resolve_theme()
  local values = type(state.config.values) == "table" and state.config.values or {}
  local resolved = type(values.resolved_theme) == "table" and values.resolved_theme or nil
  if resolved ~= nil then
    return resolved
  end

  local theme_value = values.theme
  if type(theme_value) == "string" and theme_value ~= "" then
    local ok, loaded = pcall(theme_api.get, theme_value)
    if ok then
      return loaded
    end
    return theme_api.create()
  end

  if type(theme_value) == "table" then
    return theme_api.create({
      terminal = theme_value.terminal,
      ui = theme_value.ui,
      palette = theme_value.palette,
    })
  end

  return theme_api.create()
end

---@return { height: integer, background: string|nil }
function M.resolve_topbar_theme()
  local top_bar = M.resolve_theme().ui.top_bar or {}
  return {
    height = tonumber(top_bar.height) or 22,
    background = color.normalize_hex_color(top_bar.background, nil),
  }
end

---@param text string
---@param style HollowUiNodeStyle
---@param out HollowUiFlatNode[]
local function push_flat_text(text, style, out)
  out[#out + 1] = { text = text, style = style }
end

---@param node HollowUiRenderableNode
---@param inherited_style HollowUiNodeStyle
---@param out HollowUiFlatNode[]
local function flatten_node(node, inherited_style, out)
  local node_type = node._type

  if node_type == "group" then
    local merged_style = merged_clone(inherited_style, optional_table(node.style))
    M.flatten_span_nodes(node.children or {}, merged_style, out)
    return
  end

  if node_type == "spacer" then
    out[#out + 1] = { text = " ", spacer = true, style = clone_table(inherited_style) }
    return
  end

  if node_type == "icon" then
    push_flat_text(node.name or "", merged_clone(inherited_style, optional_table(node.style)), out)
    return
  end

  if node_type == "span" then
    push_flat_text(node.text or "", merged_clone(inherited_style, optional_table(node.style)), out)
  end
end

---@param value any
---@return HollowUiNodeStyle|HollowHexColor|nil
local function resolve_segment_style(value)
  if type(value) == "table" and type(value.style) == "table" then
    return value.style
  end

  return value
end

---@param rendered any
---@return HollowUiRows
function M.normalize_widget_rows(rendered)
  if rendered == nil then
    return {}
  end

  if type(rendered) ~= "table" then
    error("widget render() must return ui.row() or ui.column()")
  end

  if rendered._type == "row" then
    return { rendered }
  end

  if rendered._type == "column" then
    return rendered.children
  end

  error("widget render() must return ui.row() or ui.column()")
end

-- ---------------------------------------------------------------------------
-- Helpers: time, window size
-- ---------------------------------------------------------------------------

---@return integer
function M.epoch_now_ms()
  return math.floor(os.time() * 1000)
end

---@return HollowWindowSizeSnapshot
function M.window_size_snapshot()
  return {
    rows = 0,
    cols = 0,
    width = host_api.get_window_width and host_api.get_window_width() or 0,
    height = host_api.get_window_height and host_api.get_window_height() or 0,
  }
end

-- ---------------------------------------------------------------------------
-- Node type predicates
-- ---------------------------------------------------------------------------

---@param value any
---@return boolean
function M.is_span_node(value)
  return type(value) == "table" and SPAN_NODE_TYPES[value._type] == true
end

---@param value any
---@return boolean
function M.is_text_shorthand(value)
  if type(value) ~= "table" or value._type ~= nil then
    return false
  end

  return type(value[1]) == "string" and table.maxn(value) == 1
end

---@param value any
---@return HollowUiSpanNode
function M.normalize_text_shorthand(value)
  if type(value) ~= "table" then
    return { _type = "span", text = tostring(value or "") }
  end

  local style = optional_table(value.style) and clone_table(value.style) or nil
  for key, entry in pairs(value) do
    if type(key) ~= "number" and key ~= "_type" and key ~= "text" and key ~= "style" then
      style = style or {}
      style[key] = entry
    end
  end

  return { _type = "span", text = value[1] or value.text or "", style = style }
end

---@param value any
---@return boolean
function M.is_inline_node(value)
  return M.is_span_node(value) or M.is_text_shorthand(value)
end

local function unexpected(child, label, index)
  local kind = type(child) == "table" and child._type or type(child)
  error(string.format("%s: unexpected %q node at child %d", label, tostring(kind), index))
end

local function collect(list, accept, label, out, strict)
  for i = 1, table.maxn(list) do
    local child = list[i]
    local kind = type(child)
    if child == nil or kind == "boolean" then
      -- Skip conditional children.
    elseif kind == "table" and child._type == nil and not M.is_text_shorthand(child) then
      collect(child, accept, label, out, strict)
    else
      accept(child, out, label, i, strict)
    end
  end
  return out
end

local function accept_inline(child, out, label, index, strict)
  local kind = type(child)
  if kind == "string" or kind == "number" then
    out[#out + 1] = { _type = "span", text = tostring(child) }
  elseif M.is_span_node(child) then
    out[#out + 1] = child
  elseif M.is_text_shorthand(child) then
    out[#out + 1] = M.normalize_text_shorthand(child)
  elseif strict then
    unexpected(child, label, index)
  else
    out[#out + 1] = { _type = "span", text = tostring(child) }
  end
end

local function accept_row(child, out, label, index)
  if type(child) == "table" and child._type == "row" then
    out[#out + 1] = child
  elseif type(child) == "table" and child._type == "column" then
    collect(child.children or {}, accept_row, label, out, true)
  else
    unexpected(child, label, index)
  end
end

---@param list table
---@param label string
---@param strict boolean|nil
---@return HollowUiRenderableNode[]
function M.collect_inline(list, label, strict)
  return collect(list, accept_inline, label, {}, strict)
end

---@param list table
---@param label string
---@return HollowUiRowNode[]
function M.collect_rows(list, label)
  return collect(list, accept_row, label, {}, true)
end

---@param value any
---@return HollowUiRenderableNode[]
function M.normalize_inline_nodes(value)
  return M.collect_inline({ value }, "hollow.ui", false)
end

---@param nodes HollowUiRenderableNode[]|nil
---@param inherited_style HollowUiNodeStyle|nil
---@param out HollowUiFlatNode[]|nil
---@return HollowUiFlatNode[]
function M.flatten_span_nodes(nodes, inherited_style, out)
  out = out or {}
  inherited_style = inherited_style or {}

  for _, node in ipairs(nodes or {}) do
    if type(node) == "table" then
      flatten_node(node, inherited_style, out)
    end
  end

  return out
end

---@param nodes any
---@return string
function M.nodes_plain_text(nodes)
  local flattened = M.flatten_span_nodes(M.normalize_inline_nodes(nodes))
  local parts = {}

  for _, node in ipairs(flattened) do
    if not node.spacer and node.text and node.text ~= "" then
      parts[#parts + 1] = node.text
    end
  end

  return table.concat(parts)
end

---@param nodes HollowUiRenderableNode[]|nil
---@param query any
---@param match_style HollowUiNodeStyle
---@return HollowUiRenderableNode[]
function M.highlight_inline_nodes(nodes, query, match_style)
  query = tostring(query or ""):lower()
  if query == "" then
    return nodes or {}
  end

  local normalized = M.normalize_inline_nodes(nodes or {})
  local text = M.nodes_plain_text(normalized)
  local lower_text = text:lower()
  local matched_positions = {}
  local start_idx, end_idx = lower_text:find(query, 1, true)

  if start_idx ~= nil then
    for index = start_idx, end_idx do
      matched_positions[index] = true
    end
  else
    local offset = 1
    for index = 1, #query do
      local found = lower_text:find(query:sub(index, index), offset, true)
      if found == nil then
        return normalized
      end
      matched_positions[found] = true
      offset = found + 1
    end
  end

  local highlighted = {}
  local text_offset = 0
  for _, node in ipairs(normalized) do
    if node._type == "spacer" then
      -- Layout nodes have no searchable text and must survive highlighting.
      highlighted[#highlighted + 1] = node
    else
      local node_text = node.text or ""
      local chunk_start = 1
      local chunk_highlighted = matched_positions[text_offset + 1] == true

      local function append_chunk(end_index)
        if end_index < chunk_start then
          return
        end

        local chunk_style = node.style
        if chunk_highlighted then
          chunk_style =
            M.merge_styles(type(node.style) == "table" and node.style or {}, match_style)
        end
        highlighted[#highlighted + 1] = {
          _type = "span",
          text = node_text:sub(chunk_start, end_index),
          style = chunk_style,
        }
      end

      for index = 1, #node_text do
        local is_highlighted = matched_positions[text_offset + index] == true
        if is_highlighted ~= chunk_highlighted then
          append_chunk(index - 1)
          chunk_start = index
          chunk_highlighted = is_highlighted
        end
      end
      append_chunk(#node_text)
      text_offset = text_offset + #node_text
    end
  end

  return highlighted
end

-- ---------------------------------------------------------------------------
-- Segment serialization
-- ---------------------------------------------------------------------------

-- Span padding keeps fractional pixels; surfaces floor (see normalize_surface_style).
---@param value any
---@return { top: number, right: number, bottom: number, left: number }
function M.normalize_segment_padding(value)
  return box.normalize(value)
end

-- One flat visual normalization path. The caller owns `target`; writing into
-- the final segment avoids allocating a second computed object per span.
local function write_computed_style(style, palette, target)
  local function segment_color(key)
    local value = style[key]
    if type(value) == "string" and value:sub(1, 1) ~= "#" then
      value = resolve_color(value, key, palette or M.palette("all"))
    end
    return color.is_hex_color(value) and value or nil
  end
  target.bold = style.bold == true
  target.fg = segment_color("fg")
  target.bg = segment_color("bg")
  target.border = segment_color("border")
  target.radius = style.radius
  target.background_extend = style.background_extend
  target.border_size = style.border_size
  if style.padding ~= nil then
    target.padding = M.normalize_segment_padding(style.padding)
  end
  return target
end

---@param text string
---@param style HollowUiNodeStyle|HollowUiStyleWrapper|HollowHexColor|nil
---@param palette table|nil
---@return HollowUiSegment
function M.style_to_segment(text, style, palette)
  local segment = { text = text }
  if color.is_hex_color(style) then
    segment.fg = style
    return segment
  end
  style = resolve_segment_style(style)
  if type(style) == "table" then
    write_computed_style(style, palette, segment)
    if type(style.id) == "string" and style.id ~= "" then
      segment.id = style.id
    end
  end
  return segment
end

-- Shared by the workspace selector and activity workspace pills.
---@param name string
---@param custom_fn? fun(name: string): HollowUiColorPair
---@return HollowUiColorPair
function M.workspace_colors(name, custom_fn)
  if custom_fn then
    return custom_fn(name)
  end
  local theme = M.resolve_theme()
  local hash = 0
  for index = 1, #name do
    hash = (hash * 31 + name:byte(index)) % 2147483647
  end
  -- Golden angle (~222.5deg) for maximal hue distance between workspaces.
  local hue = ((hash / 2147483647) * 360 + 222.5) % 360
  local lightness = color.hex_luminance(theme.palette.background) < 128 and 0.22 or 0.68
  local bg = color.hex_from_hsl(hue, 0.3, lightness)
  return { bg = bg, fg = color.contrast_hex_color(bg, 0.45, theme.palette.foreground) }
end

---@param segments HollowUiSegment[]
---@return string
function M.segments_plain_text(segments)
  return table.concat(hollow
    .tbl(segments or {})
    :filter_map(function(segment)
      if type(segment.text) == "string" and segment.text ~= "" then
        return segment.text
      end
    end)
    :get())
end

---@param value any
---@param fallback_text string
---@param style HollowUiNodeStyle|nil
---@param palette table|nil
---@return HollowUiSegment[]
function M.bar_value_to_segments(value, fallback_text, style, palette)
  if type(value) == "string" then
    return { M.style_to_segment(value, style, palette) }
  end

  if type(value) == "table" then
    if value._type == "span" then
      return {
        M.style_to_segment(
          value.text or fallback_text,
          M.merge_styles(style, value.style),
          palette
        ),
      }
    end

    if M.is_span_node(value) or value[1] ~= nil then
      local flattened = M.flatten_span_nodes(M.normalize_inline_nodes(value), style)
      local segments = hollow
        .tbl(flattened)
        :filter_map(function(node)
          if type(node.text) == "string" and node.text ~= "" then
            return M.style_to_segment(node.text, node.style, palette)
          end
        end)
        :get()

      if #segments > 0 then
        return segments
      end
    end

    if value.text ~= nil or value.fg ~= nil or value.bg ~= nil or value.bold ~= nil then
      local merged_style = M.merge_styles(style, {
        fg = value.fg,
        bg = value.bg,
        bold = value.bold,
      })
      local text = type(value.text) == "string" and value.text or fallback_text
      return { M.style_to_segment(text, merged_style, palette) }
    end
  end

  return { M.style_to_segment(fallback_text, style, palette) }
end

local merge_into = sheet.merge_into

---@vararg HollowStyleLayer
---@return HollowUiNodeStyle
M.merge_styles = sheet.merge

--- Private recipe inputs. These describe existing paint resolution, not a
--- public state/recipe registration API.
---@class (exact) HollowUiVisualState
---@field hovered? boolean
---@field selected? boolean
---@field pressed? boolean
---@field focus_visible? boolean
---@field disabled? boolean

---@class (exact) HollowUiNodeState
---@field hovered boolean
---@field selected boolean

--- Normalize row paint while retaining legacy aliases as final overrides.
--- Rows have their own boxes; only text properties are inherited by children.
local ROW_STYLE_FIELDS = { fg = true, bg = true, bold = true, radius = true, hover = true }

local function validate_row_style(style)
  for key, value in pairs(style or {}) do
    if not ROW_STYLE_FIELDS[key] then
      error("hollow.ui: unsupported row style field " .. tostring(key))
    elseif key == "hover" and type(value) == "table" then
      validate_row_style(value)
    end
  end
end

---@param row HollowUiRow
---@param palette HollowUiTheme
---@param hovered_id? string
---@return HollowUiNodeStyle|nil
function M.resolve_row_style(row, palette, hovered_id)
  if row.style == nil and row.variant == nil then
    return nil
  end
  validate_row_style(row.style)
  palette = row.theme or palette
  local visual_state = M.node_state({ hovered_id = hovered_id }, row.id, row.selected)
  visual_state.hovered = row.hoverable ~= false and visual_state.hovered
  local style = row.variant
      and list_row_styles(palette, {
        variant = row.variant,
        hovered = visual_state.hovered,
        selected = visual_state.selected,
      }).root
    or {}
  style = M.merge_styles(style, row.style)
  if visual_state.hovered and type(row.style) == "table" and type(row.style.hover) == "table" then
    merge_into(style, row.style.hover)
  end
  if row.fill_bg ~= nil then
    style.bg = row.fill_bg
  end
  if row.fill_radius ~= nil then
    style.radius = row.fill_radius
  end
  return M.resolve_tokens(style, palette)
end

--- Existing event owners supply selection; hover is looked up in one place.
---@param hover_state? {hovered_id?: string}
---@param id? string
---@param selected? boolean
---@return HollowUiNodeState
function M.node_state(hover_state, id, selected)
  return {
    selected = selected == true,
    hovered = type(id) == "string"
      and id ~= ""
      and hover_state ~= nil
      and hover_state.hovered_id == id,
  }
end

---@param style any
---@param hovered_id any
---@return any
function M.apply_hover(style, hovered_id)
  if type(style) ~= "table" or type(style.id) ~= "string" or style.id == "" then
    return style
  end
  if style.id ~= hovered_id or type(style.hover) ~= "table" then
    return style
  end
  return M.merge_styles(style, style.hover)
end

---@param rendered any
---@return any[]
function M.normalize_bar_items(rendered)
  if type(rendered) ~= "table" then
    return {}
  end

  if rendered._type ~= nil then
    return { rendered }
  end

  return rendered
end

---@param value any
---@param fallback_text string
---@param style HollowUiNodeStyle|nil
---@return HollowUiSegment
function M.bar_value_to_segment(value, fallback_text, style)
  local segments = M.bar_value_to_segments(value, fallback_text, style)
  if #segments == 1 then
    return segments[1]
  end

  return M.style_to_segment(M.segments_plain_text(segments), style)
end

-- ---------------------------------------------------------------------------
-- Fuzzy search
-- ---------------------------------------------------------------------------

---@param text any
---@return string[]
function M.filter_ascii_words(text)
  local words = {}
  for part in tostring(text or ""):lower():gmatch("[a-z0-9]+") do
    words[#words + 1] = part
  end
  return words
end

---@param haystack any
---@param needle any
---@return number|nil
--- Substring score for already-lowercased inputs.
---@param haystack string
---@param needle string
---@return number|nil
function M.plain_match_score_lower(haystack, needle)
  if needle == "" then
    return 0
  end

  local start_idx, end_idx = haystack:find(needle, 1, true)
  if start_idx == nil then
    return nil
  end

  return 2000 - (start_idx * 4) - (end_idx - start_idx + 1)
end

local function substring_score(haystack, needle)
  return M.plain_match_score_lower(tostring(haystack or ""):lower(), tostring(needle or ""):lower())
end

---@param haystack any
---@param needle any
---@return number|nil
local function subsequence_score(haystack, needle)
  haystack = tostring(haystack or ""):lower()
  needle = tostring(needle or ""):lower()

  if needle == "" then
    return 0
  end

  local pos = 1
  local start_idx = nil
  local last_idx = nil
  local gaps = 0
  local streak_bonus = 0

  for i = 1, #needle do
    local found = haystack:find(needle:sub(i, i), pos, true)
    if found == nil then
      return nil
    end

    if start_idx == nil then
      start_idx = found
    elseif last_idx ~= nil then
      local gap = found - last_idx - 1
      gaps = gaps + gap
      if gap == 0 then
        streak_bonus = streak_bonus + 8
      end
    end

    last_idx = found
    pos = found + 1
  end

  return 1000 - (start_idx or 1) * 3 - gaps * 5 + streak_bonus
end

---@param text any
---@param query any
---@return number|nil
function M.fuzzy_match_score(text, query)
  text = tostring(text or "")
  query = tostring(query or "")

  if query == "" then
    return 0
  end

  local best = substring_score(text, query)
  local subseq = subsequence_score(text, query)
  if subseq ~= nil and (best == nil or subseq > best) then
    best = subseq
  end

  for _, word in ipairs(M.filter_ascii_words(text)) do
    local word_score = substring_score(word, query)
    if word_score ~= nil then
      word_score = word_score + 120
      if best == nil or word_score > best then
        best = word_score
      end
    end

    local word_subsequence_score = subsequence_score(word, query)
    if word_subsequence_score ~= nil then
      word_subsequence_score = word_subsequence_score + 60
      if best == nil or word_subsequence_score > best then
        best = word_subsequence_score
      end
    end
  end

  if text:lower():sub(1, #query) == query:lower() then
    best = math.max(best or 0, substring_score(text, query) + 1000)
  end

  return best
end

---@param text any
---@param query any
---@return number|nil
function M.plain_match_score(text, query)
  return substring_score(text, query)
end

---@param query string
---@param searchable string
---@param fuzzy boolean
---@return boolean, number|nil
function M.select_item_matches(query, searchable, fuzzy)
  if query == "" then
    return true, 0
  end

  local score = fuzzy and M.fuzzy_match_score(searchable, query)
    or M.plain_match_score(searchable, query)
  if score == nil then
    return false, nil
  end

  return true, score
end

-- ---------------------------------------------------------------------------
-- Key input
-- ---------------------------------------------------------------------------

---@param key any
---@param mods string|nil
---@return string|nil
function M.printable_char_for_key(key, mods)
  local shifted = mods == "<S>"
  if mods ~= nil and mods ~= "" and not shifted then
    return nil
  end

  if type(key) ~= "string" or key == "" then
    return nil
  end

  if #key == 1 then
    return shifted and key:upper() or key
  end

  if key:match("^digit_[0-9]$") then
    local digit = key:sub(-1)
    if not shifted then
      return digit
    end
    return DIGIT_SHIFT_MAP[digit]
  end

  local resolver = SPECIAL_PRINTABLE_KEYS[key]
  return resolver and resolver(shifted) or nil
end

-- ---------------------------------------------------------------------------
-- Overlay geometry normalizers
-- ---------------------------------------------------------------------------

---@param value any
---@return string
function M.normalize_overlay_align(value)
  if type(value) ~= "string" then
    return "center"
  end

  local normalized = value:lower():gsub("[%s%-]", "_")
  normalized = OVERLAY_ALIGN_ALIASES[normalized] or normalized
  return ALLOWED_OVERLAY_ALIGN[normalized] and normalized or "center"
end

---@param value any
---@return HollowUiThemeBackdrop|nil
function M.normalize_overlay_backdrop(value)
  if value == nil or value == false then
    return nil
  end

  if value == true then
    return { color = DEFAULT_BACKDROP.color, alpha = DEFAULT_BACKDROP.alpha }
  end

  if color.is_hex_color(value) then
    return { color = value, alpha = DEFAULT_BACKDROP.alpha }
  end

  if type(value) == "table" then
    local c = color.normalize_hex_color(value.color or value.bg, "#000000")
    local alpha = tonumber(value.alpha)
    if alpha == nil then
      alpha = DEFAULT_BACKDROP.alpha
    end
    alpha = math.max(0, math.min(255, math.floor(alpha)))
    return { color = c, alpha = alpha }
  end

  return nil
end

---@param value any
---@return integer|nil
function M.normalize_overlay_size(value)
  local number_value = tonumber(value)
  if number_value == nil then
    return nil
  end

  number_value = math.floor(number_value)
  return number_value >= 1 and number_value or nil
end

M.normalize_hex_color = color.normalize_hex_color

--- Common flat surface boundary. Surface pixels retain integer semantics;
--- span padding still uses normalize_segment_padding. Identity is copied only
--- for adapters that support it; callbacks never cross the paint boundary.
---@class HollowUiSurfacePaint: HollowStyle
---@field alpha? number

---@param value HollowUiSurfacePaint|HollowUiNodeStyle|nil
---@param palette? HollowUiTheme
---@return HollowUiSurfacePaint|nil
function M.normalize_surface_style(value, palette)
  if type(value) ~= "table" then
    return nil
  end
  local source = palette and M.resolve_tokens(value, palette) or value
  local result = {}
  for _, key in ipairs(tokens.COLOR_FIELDS) do
    result[key] = color.normalize_hex_color(source[key], nil)
  end
  for _, key in ipairs({ "radius", "close_radius" }) do
    local px = box.px(source[key], 0, true)
    if px > 0 then
      result[key] = px
    end
  end
  for _, key in ipairs({ "padding", "margin" }) do
    local value = box.normalize(source[key], true)
    if not box.is_empty(value) then
      result[key] = value
    end
  end
  if source.border_size ~= nil then
    result.border_size = box.px(source.border_size, 1, true)
  end
  local alpha = tonumber(source.alpha)
  if alpha and alpha == alpha and alpha ~= math.huge and alpha ~= -math.huge then
    result.alpha = math.max(0, math.min(255, math.floor(alpha)))
  end
  if source.bold == true then
    result.bold = true
  end
  if type(source.id) == "string" and source.id ~= "" then
    result.id = source.id
  end
  return next(result) and result or nil
end

---@param value any
---@return HollowUiChrome|nil
function M.normalize_overlay_chrome(value, palette)
  local surface = M.normalize_surface_style(value, palette)
  if not surface then
    return nil
  end
  local chrome = {
    bg = surface.bg,
    border = surface.border,
    alpha = surface.alpha,
    radius = surface.radius,
    padding = surface.padding,
    margin = surface.margin,
  }
  if surface.border_size ~= nil or surface.border ~= nil then
    chrome.border_size = surface.border_size or 1
  end
  return next(chrome) and chrome or nil
end

--- Compatibility chrome fields replace whole boxes, unlike style layers.
---@param style? HollowUiSurfacePaint
---@param chrome? HollowUiChrome|boolean
---@param palette HollowUiTheme
---@return HollowUiChrome|nil
function M.overlay_surface_style(style, chrome, palette)
  if type(style) ~= "table" then
    return M.normalize_overlay_chrome(chrome, palette)
  end
  local source = util.clone_value(style)
  for key, value in pairs(type(chrome) == "table" and chrome or {}) do
    source[key] = util.clone_value(value)
  end
  return M.normalize_overlay_chrome(source, palette)
end

--- The same row paint contract is consumed by overlay and sidebar adapters.
function M.serialize_row_paint(row, palette, hovered_id)
  palette = row.theme or palette
  local paint = M.resolve_row_style(row, palette, hovered_id)
  local result = {
    fill_bg = paint and paint.bg or row.fill_bg,
    fill_radius = paint and paint.radius or row.fill_radius,
    divider = row.divider,
    hover_bg = palette.hover_bg,
    scrollbar_track = row.scrollbar_track == true,
    scrollbar_thumb = row.scrollbar_thumb == true,
    scrollbar_id = row.scrollbar_id,
    scrollbar_thumb_ratio = row.scrollbar_thumb_ratio,
    scrollbar_thumb_size = row.scrollbar_thumb_size,
    scrollbar_track_color = row.scrollbar_track_color,
    scrollbar_thumb_color = row.scrollbar_thumb_color,
  }
  local defaults = list_row_styles(palette, {
    variant = row.variant,
    selected = row.selected,
  }).raw_paint
  if row.accent_bar ~= nil then
    result.accent_bar = row.accent_bar
  else
    result.accent_bar = defaults.accent_bar
  end
  if result.scrollbar_track and result.scrollbar_track_color == nil then
    result.scrollbar_track_color = defaults.scrollbar_track_color
  end
  if result.scrollbar_track and result.scrollbar_thumb_color == nil then
    result.scrollbar_thumb_color =
      tokens.resolve_color("parts.scrollbar.thumb", "scrollbar.thumb", palette, true)
  end
  -- Legacy color aliases remain literal-or-token inputs at this boundary.
  for _, key in ipairs({
    "fill_bg",
    "accent_bar",
    "divider",
    "scrollbar_track_color",
    "scrollbar_thumb_color",
  }) do
    local value = result[key]
    if type(value) == "string" then
      result[key] = resolve_color(value, key, palette)
    end
  end
  return result, paint
end

function M.sidebar_surface_style(style, palette)
  for key in pairs(style or {}) do
    if key ~= "fg" and key ~= "bg" and key ~= "border" and key ~= "alpha" then
      error("hollow.ui: unsupported sidebar surface field " .. tostring(key))
    end
  end
  local base = palette.parts and palette.parts.sidebar or {}
  return M.normalize_surface_style(M.merge_styles(base, style), palette)
end

function M.tab_fallback_style(active, palette)
  local part = palette.parts and palette.parts.tab or {}
  local style = M.merge_styles(active and part.active or part.inactive)
  style.selection_accent = part.selection_accent
  return M.normalize_surface_style(style, palette)
end

---@param theme HollowUiTheme
---@param border HollowColor|nil
---@param border_size integer|nil
---@return HollowUiChrome|nil
function M.theme_overlay_chrome(theme, border, border_size)
  local function build()
    local style = M.merge_styles(panel_styles(theme).root, {
      radius = theme.radius,
      padding = theme.padding,
      margin = theme.margin,
    })
    style.border = border or style.border
    style.border_size = border_size
    style.alpha = 255
    return M.normalize_overlay_chrome(style, theme)
  end
  local chrome = build()
  if chrome then
    live_chrome[chrome] = build
  end
  return chrome
end

-- ---------------------------------------------------------------------------
-- Widget rendering helpers
-- ---------------------------------------------------------------------------

---@return HollowWidgetCtx
function M.widget_ctx()
  local current_tab = util.safe_call(hollow.term.current_tab, nil)
  local current_pane = util.safe_call(hollow.term.current_pane, nil)

  return {
    term = {
      tab = current_tab,
      pane = current_pane,
      tabs = util.safe_call(hollow.term.tabs, {}),
      workspace = util.safe_call(hollow.term.current_workspace, nil),
      workspaces = util.safe_call(hollow.term.workspaces, {}),
    },
    size = M.window_size_snapshot(),
    time = {
      epoch_ms = M.epoch_now_ms(),
      iso = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    },
  }
end

---@param widget HollowUiWidget|nil
---@return any
function M.render_widget(widget)
  if widget == nil or type(widget.render) ~= "function" then
    return nil
  end

  local ok_ctx, ctx = pcall(M.widget_ctx)
  if not ok_ctx then
    hollow.log("[hollow.ui] render_widget: widget_ctx error: " .. tostring(ctx))
    return nil
  end

  local ok, rendered = pcall(widget.render, ctx)
  if not ok then
    hollow.log("[hollow.ui] render_widget: render error: " .. tostring(rendered))
    return nil
  end

  return rendered
end

---@param widget HollowUiWidget|nil
---@return HollowUiRows
function M.render_widget_rows(widget)
  local rendered = M.render_widget(widget)
  if rendered == nil then
    return {}
  end

  return M.normalize_widget_rows(rendered)
end

return M
