local state = require("hollow.state").get()
local theme_api = require("hollow.theme")
local util = require("hollow.util")

local hollow = _G.hollow
local host_api = state.host_api

local M = {}

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

---@param fn function|nil
---@param default any
---@return any
local function safe_call(fn, default)
  if type(fn) ~= "function" then
    return default
  end

  local ok, value = pcall(fn)
  if ok and value ~= nil then
    return value
  end

  return default
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

---@param value any
---@param fallback HollowHexColor|nil
---@return HollowHexColor|nil
local function normalize_hex_color(value, fallback)
  return util.normalize_hex_color(value, fallback)
end

---@param rendered any
---@return HollowUiRows
local function normalize_widget_rows(rendered)
  if type(rendered) ~= "table" then
    return { {} }
  end

  local first = rendered[1]
  if first == nil or M.is_span_node(first) then
    return { rendered }
  end

  local rows = {}
  for _, row in ipairs(rendered) do
    if type(row) == "table" then
      rows[#rows + 1] = row
    end
  end

  return rows
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
  return type(value) == "table" and value._type == nil and type(value[1]) == "string"
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

---@param value any
---@return HollowUiRenderableNode[]
function M.normalize_inline_nodes(value)
  if type(value) == "string" then
    return { { _type = "span", text = value } }
  end

  if M.is_span_node(value) then
    return { value }
  end

  if M.is_text_shorthand(value) then
    return { M.normalize_text_shorthand(value) }
  end

  if type(value) == "table" then
    local nodes = {}
    for _, node in ipairs(value) do
      if type(node) == "string" then
        nodes[#nodes + 1] = { _type = "span", text = node }
      elseif M.is_span_node(node) then
        nodes[#nodes + 1] = node
      elseif M.is_text_shorthand(node) then
        nodes[#nodes + 1] = M.normalize_text_shorthand(node)
      end
    end

    if #nodes > 0 then
      return nodes
    end
  end

  return { { _type = "span", text = tostring(value or "") } }
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

-- ---------------------------------------------------------------------------
-- Segment serialization
-- ---------------------------------------------------------------------------

---@param text string
---@param style HollowUiNodeStyle|HollowUiStyleWrapper|HollowHexColor|nil
---@return HollowUiSegment
function M.style_to_segment(text, style)
  local segment = { text = text }

  if util.is_hex_color(style) then
    segment.fg = style
    return segment
  end

  style = resolve_segment_style(style)
  if type(style) == "table" then
    segment.bold = style.bold == true
    if type(style.id) == "string" and style.id ~= "" then
      segment.id = style.id
    end
    if util.is_hex_color(style.fg) then
      segment.fg = style.fg
    end
    if util.is_hex_color(style.bg) then
      segment.bg = style.bg
    end
    if style.radius ~= nil then
      segment.radius = style.radius
    end
    if util.is_hex_color(style.border) then
      segment.border = style.border
    end
    if style.border_size ~= nil then
      segment.border_size = style.border_size
    end
  end

  return segment
end

---@param segments HollowUiSegment[]
---@return string
function M.segments_plain_text(segments)
  local parts = {}

  for _, segment in ipairs(segments or {}) do
    if type(segment.text) == "string" and segment.text ~= "" then
      parts[#parts + 1] = segment.text
    end
  end

  return table.concat(parts)
end

---@param value any
---@param fallback_text string
---@param style HollowUiNodeStyle|nil
---@return HollowUiSegment[]
function M.bar_value_to_segments(value, fallback_text, style)
  if type(value) == "string" then
    return { M.style_to_segment(value, style) }
  end

  if type(value) == "table" then
    if value._type == "span" then
      return {
        M.style_to_segment(value.text or fallback_text, M.merge_style_tables(style, value.style)),
      }
    end

    if M.is_span_node(value) or value[1] ~= nil then
      local flattened = M.flatten_span_nodes(M.normalize_inline_nodes(value), style)
      local segments = {}

      for _, node in ipairs(flattened) do
        if type(node.text) == "string" and node.text ~= "" then
          segments[#segments + 1] = M.style_to_segment(node.text, node.style)
        end
      end

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
      return { M.style_to_segment(text, merged_style) }
    end
  end

  return { M.style_to_segment(fallback_text, style) }
end

---@param base HollowUiNodeStyle|nil
---@param overlay_style HollowUiNodeStyle|nil
---@return HollowUiNodeStyle
function M.merge_style_tables(base, overlay_style)
  local merged = {}
  if type(base) == "table" then
    util.merge_tables(merged, base)
  end
  if type(overlay_style) == "table" then
    util.merge_tables(merged, overlay_style)
  end
  return merged
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

  if util.is_hex_color(value) then
    return { color = value, alpha = DEFAULT_BACKDROP.alpha }
  end

  if type(value) == "table" then
    local color = normalize_hex_color(value.color or value.bg, "#000000")
    local alpha = tonumber(value.alpha)
    if alpha == nil then
      alpha = DEFAULT_BACKDROP.alpha
    end
    alpha = math.max(0, math.min(255, math.floor(alpha)))
    return { color = color, alpha = alpha }
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

M.normalize_hex_color = normalize_hex_color

---@param value any
---@return HollowUiChrome|nil
function M.normalize_overlay_chrome(value)
  value = type(value) == "table" and value or {}

  local bg = normalize_hex_color(value.bg, nil)
  local border = normalize_hex_color(value.border, nil)
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
  local current_tab = safe_call(hollow.term.current_tab, nil)
  local current_pane = safe_call(hollow.term.current_pane, nil)

  return {
    term = {
      tab = current_tab,
      pane = current_pane,
      tabs = safe_call(hollow.term.tabs, {}),
      workspace = safe_call(hollow.term.current_workspace, nil),
      workspaces = safe_call(hollow.term.workspaces, {}),
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
    return { {} }
  end

  return normalize_widget_rows(rendered)
end

---@param kind string
---@return HollowUiTheme
function M.resolve_widget_theme(kind)
  return theme_api.resolve_widget(kind)
end

return M
