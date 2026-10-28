local color = require("hollow.color")
local state = require("hollow.state").get()
local theme_api = require("hollow.theme")
local util = require("hollow.util")

local hollow = _G.hollow
local host_api = state.host_api

local M = {}
local palettes = {}
local cached_bar_palette

function M.invalidate_palettes()
  palettes = {}
  cached_bar_palette = nil
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

local function edit_distance(a, b)
  local prev = {}
  for j = 0, #b do
    prev[j] = j
  end
  for i = 1, #a do
    local row = { [0] = i }
    for j = 1, #b do
      row[j] =
        math.min(row[j - 1] + 1, prev[j] + 1, prev[j - 1] + (a:sub(i, i) == b:sub(j, j) and 0 or 1))
    end
    prev = row
  end
  return prev[#b]
end

local function closest_token(palette, token)
  local best, distance
  local function visit(tbl, prefix)
    for key, value in pairs(tbl) do
      if type(key) == "string" then
        local path = prefix .. key
        if type(value) == "table" then
          visit(value, path .. ".")
        elseif type(value) == "string" and value:sub(1, 1) == "#" then
          local d = edit_distance(token, path)
          if not distance or d < distance or (d == distance and path < best) then
            best, distance = path, d
          end
        end
      end
    end
  end
  visit(palette, "")
  return best
end

local function resolve_color(value, key, palette)
  if type(value) ~= "string" or value:sub(1, 1) == "#" then
    return value
  end
  local resolved = palette
  if value == "" or value:sub(1, 1) == "." or value:sub(-1) == "." or value:find("..", 1, true) then
    resolved = nil
  else
    for part in value:gmatch("[^.]+") do
      resolved = type(resolved) == "table" and resolved[part] or nil
    end
  end
  if type(resolved) ~= "string" or resolved:sub(1, 1) ~= "#" then
    local hint = closest_token(palette, value)
    error(
      string.format(
        "hollow.ui: unknown style token %q for %s%s",
        value,
        key,
        hint and string.format(" (did you mean %q?)", hint) or ""
      )
    )
  end
  return resolved
end

---@param style HollowUiNodeStyle|nil
---@param palette table
---@return HollowUiNodeStyle
function M.resolve_tokens(style, palette)
  local result = util.clone_value(style or {})
  local function resolve(current)
    for _, key in ipairs({ "fg", "bg", "border" }) do
      current[key] = resolve_color(current[key], key, palette)
    end
    if type(current.hover) == "table" then
      resolve(current.hover)
    end
  end
  resolve(result)
  return result
end

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

---@param value any
---@param default integer
---@return integer
local function normalize_px(value, default)
  local number = tonumber(value)
  if number == nil then
    return default
  end

  number = math.floor(number)
  if number < 0 then
    return 0
  end
  return number
end

---@param value any
---@return { top: integer, right: integer, bottom: integer, left: integer }
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

---@param box { top: integer, right: integer, bottom: integer, left: integer }
---@return boolean
local function has_box_spacing(box)
  return box.top > 0 or box.right > 0 or box.bottom > 0 or box.left > 0
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
local function normalize_widget_rows(rendered)
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
            M.merge_style_tables(type(node.style) == "table" and node.style or {}, match_style)
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

---@param value any
---@return { top: number, right: number, bottom: number, left: number }
function M.normalize_segment_padding(value)
  local box = type(value) == "table" and value or {}
  local all = type(value) == "number" and value or 0
  local top = box.top or box.y or box.vertical or box[1] or all
  local right = box.right or box.x or box.horizontal or box[2] or top
  local bottom = box.bottom or box.y or box.vertical or box[3] or top
  local left = box.left or box.x or box.horizontal or box[4] or right
  local padding = {}
  for edge, px in pairs({ top = top, right = right, bottom = bottom, left = left }) do
    padding[edge] = type(px) == "number" and px == px and px < math.huge and math.max(0, px) or 0
  end
  return padding
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
    local function segment_color(key)
      local value = style[key]
      if type(value) == "string" and value:sub(1, 1) ~= "#" then
        value = resolve_color(value, key, palette or M.palette("all"))
      end
      return color.is_hex_color(value) and value or nil
    end
    segment.bold = style.bold == true
    if type(style.id) == "string" and style.id ~= "" then
      segment.id = style.id
    end
    segment.fg = segment_color("fg")
    segment.bg = segment_color("bg")
    if style.radius ~= nil then
      segment.radius = style.radius
    end
    if style.background_extend ~= nil then
      segment.background_extend = style.background_extend
    end
    segment.border = segment_color("border")
    if style.border_size ~= nil then
      segment.border_size = style.border_size
    end
    if style.padding ~= nil then
      segment.padding = M.normalize_segment_padding(style.padding)
    end
  end

  return segment
end

-- Shared by the workspace selector and activity workspace pills.
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
          M.merge_style_tables(style, value.style),
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
      local merged_style = M.merge_style_tables(style, {
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

---@param value any
---@return any
local function partial_box(value)
  if type(value) == "number" then
    return { top = value, right = value, bottom = value, left = value }
  end
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  if value[1] ~= nil then
    local top = value[1]
    local right = value[2] or top
    out.top, out.right, out.bottom, out.left = top, right, value[3] or top, value[4] or right
  end
  local x, y = value.x or value.horizontal, value.y or value.vertical
  out.top, out.bottom = value.top or y or out.top, value.bottom or y or out.bottom
  out.left, out.right = value.left or x or out.left, value.right or x or out.right
  return out
end

local function merge_into(result, layer)
  for key, value in pairs(layer) do
    if key == "padding" or key == "margin" then
      local box = partial_box(value)
      if type(box) == "table" then
        result[key] = type(result[key]) == "table" and result[key] or {}
        for side, px in pairs(box) do
          result[key][side] = util.clone_value(px)
        end
      else
        result[key] = util.clone_value(value)
      end
    elseif key == "hover" and type(value) == "table" then
      if type(result[key]) ~= "table" then
        result[key] = {}
      end
      merge_into(result[key], value)
    elseif type(value) == "table" then
      if type(result[key]) ~= "table" then
        result[key] = {}
      end
      util.merge_tables(result[key], util.clone_value(value))
    else
      result[key] = util.clone_value(value)
    end
  end
end

---@vararg HollowUiNodeStyle|boolean|nil
---@return HollowUiNodeStyle
function M.merge_styles(...)
  local result = {}
  for i = 1, select("#", ...) do
    local layer = select(i, ...)
    if type(layer) == "table" then
      merge_into(result, layer)
    end
  end
  return result
end

local COMPUTED_STYLE_FIELDS = {
  fg = true,
  bg = true,
  bold = true,
  border = true,
  border_size = true,
  radius = true,
  background_extend = true,
  padding = true,
  margin = true,
  -- Legacy node metadata is accepted but never copied into the visual result.
  id = true,
  on_click = true,
  on_mouse_enter = true,
  on_mouse_leave = true,
  hover = true,
}

--- Private prototype: merge visual layers, resolve tokens, and separate paint
--- from spacing. No theme lookup, state inference, identity or callbacks.
--- Callers select state layers explicitly; the last layer wins. Missing boxes
--- stay absent so legacy adapters can retain their surface-specific defaults.
---@param palette table
---@vararg HollowUiNodeStyle|boolean|nil
---@return HollowUiComputedStyle
function M.compute_style(palette, ...)
  -- Read a single layer directly: only the output boxes are allocated. Multiple
  -- layers still use the established box-aware merge, never a second cascade.
  local style = select("#", ...) == 1 and (...) or nil
  if type(style) ~= "table" then
    style = M.merge_styles(...)
  end
  for key in pairs(style) do
    if not COMPUTED_STYLE_FIELDS[key] then
      error(string.format("hollow.ui: unsupported computed style field %q", tostring(key)))
    end
  end
  local function resolved_color(key)
    local value = resolve_color(style[key], key, palette)
    return color.is_hex_color(value) and value or nil
  end
  return {
    text = { fg = resolved_color("fg"), bold = style.bold == true },
    box = {
      bg = resolved_color("bg"),
      border = resolved_color("border"),
      border_size = style.border_size,
      radius = style.radius,
      background_extend = style.background_extend,
    },
    layout = {
      padding = style.padding ~= nil and M.normalize_segment_padding(style.padding) or nil,
      margin = style.margin ~= nil and M.normalize_segment_padding(style.margin) or nil,
    },
  }
end

--- Adapter prototype for the existing span protocol. Interaction identity is
--- supplied separately; never store handlers or IDs in a computed style.
---@param text string
---@param computed HollowUiComputedStyle
---@param id? string
---@return HollowUiSegment
function M.computed_style_to_segment(text, computed, id)
  local box = computed.box
  return {
    text = text,
    id = type(id) == "string" and id ~= "" and id or nil,
    fg = computed.text.fg,
    bold = computed.text.bold,
    bg = box.bg,
    border = box.border,
    border_size = box.border_size,
    radius = box.radius,
    background_extend = box.background_extend,
    padding = util.clone_value(computed.layout.padding),
  }
end

---@param base HollowUiNodeStyle|nil
---@param overlay_style HollowUiNodeStyle|nil
---@return HollowUiNodeStyle
function M.merge_style_tables(base, overlay_style)
  return M.merge_styles(base, overlay_style)
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
local function substring_score(haystack, needle)
  haystack = tostring(haystack or ""):lower()
  needle = tostring(needle or ""):lower()

  if needle == "" then
    return 0
  end

  local start_idx, end_idx = haystack:find(needle, 1, true)
  if start_idx == nil then
    return nil
  end

  return 2000 - (start_idx * 4) - (end_idx - start_idx + 1)
end

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

---@param value any
---@return HollowUiChrome|nil
function M.normalize_overlay_chrome(value)
  value = type(value) == "table" and value or {}

  local bg = color.normalize_hex_color(value.bg, nil)
  local border = color.normalize_hex_color(value.border, nil)
  local has_border_size = value.border_size ~= nil
  local border_size = has_border_size and normalize_px(value.border_size, 1) or 1
  local alpha = tonumber(value.alpha)
  local radius = normalize_px(value.radius, 0)
  local padding = normalize_box(value.padding)
  local margin = normalize_box(value.margin)
  if alpha ~= nil then
    alpha = math.max(0, math.min(255, math.floor(alpha)))
  end
  if
    bg == nil
    and border == nil
    and not has_border_size
    and alpha == nil
    and radius <= 0
    and not has_box_spacing(padding)
    and not has_box_spacing(margin)
  then
    return nil
  end

  local chrome = { bg = bg, border = border }
  if has_border_size or border ~= nil then
    chrome.border_size = border_size
  end
  if alpha ~= nil then
    chrome.alpha = alpha
  end
  if radius > 0 then
    chrome.radius = radius
  end
  if has_box_spacing(padding) then
    chrome.padding = padding
  end
  if has_box_spacing(margin) then
    chrome.margin = margin
  end
  return chrome
end

---@param theme HollowUiTheme
---@param border HollowColor|nil
---@param border_size integer|nil
---@return HollowUiChrome|nil
function M.theme_overlay_chrome(theme, border, border_size)
  return M.normalize_overlay_chrome({
    bg = theme.panel_bg,
    border = border or theme.panel_border,
    border_size = border_size,
    alpha = 255,
    radius = theme.radius,
    padding = theme.padding,
    margin = theme.margin,
  })
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

---@param rendered any
---@return HollowUiRows
function M.normalize_widget_rows(rendered)
  return normalize_widget_rows(rendered)
end

---@param widget HollowUiWidget|nil
---@return HollowUiRows
function M.render_widget_rows(widget)
  local rendered = M.render_widget(widget)
  if rendered == nil then
    return {}
  end

  return normalize_widget_rows(rendered)
end

---@param kind string
---@return HollowUiTheme
function M.resolve_widget_theme(kind)
  return theme_api.resolve_widget(kind)
end

return M
