local state = require("hollow.state").get()
local util = require("hollow.util")

local hollow = _G.hollow
local host_api = state.host_api

local M = {}

local HEX_COLOR_PATTERN = "^#%x%x%x%x%x%x$"
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

-- ---------------------------------------------------------------------------
-- Default theme values
-- All fallback colors and the backdrop alpha live here and only here.
-- resolve_widget_theme() merges user config on top of these.
-- ---------------------------------------------------------------------------

local DEFAULT_THEME = {
  panel_bg = "#1f2430",
  panel_border = "#88c0d0",
  divider = "#2b3240",
  title = "#88c0d0",
  fg = "#d8dee9",
  muted = "#9aa5b1",
  input_bg = "#20242f",
  input_fg = "#d8dee9",
  cursor_bg = "#d8dee9",
  cursor_fg = "#1f2430",
  selected_bg = "#3b4252",
  selected_detail_bg = "#313745",
  selected_fg = "#eceff4",
  selected_muted = "#cfd8e3",
  detail = "#8b95a1",
  notify_fg = "#d8dee9",
  counter = "#667084",
  empty = "#9aa5b1",
  scrollbar_track = "#5a6375",
  scrollbar_thumb = "#88c0d0",
  backdrop = { color = "#000000", alpha = 170 },
  notify_levels = {
    info = "#88c0d0",
    warn = "#ebcb8b",
    error = "#ffb4a9",
    success = "#a3be8c",
  },
}

---@param value any
---@return boolean
local function is_hex_color(value)
  return type(value) == "string" and value:match(HEX_COLOR_PATTERN) ~= nil
end

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

---@param field any
---@param key any
---@return table
local function table_field(field, key)
  if type(field) ~= "table" then
    return {}
  end

  local value = field[key]
  return type(value) == "table" and value or {}
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
  if is_hex_color(value) then
    return value
  end

  return fallback
end

---@param value any
---@param amount number
---@param fallback HollowHexColor|nil
---@return HollowHexColor|nil
local function brighten_hex_color(value, amount, fallback)
  local color = normalize_hex_color(value, nil)
  if color == nil then
    return fallback
  end

  local red = tonumber(color:sub(2, 3), 16)
  local green = tonumber(color:sub(4, 5), 16)
  local blue = tonumber(color:sub(6, 7), 16)
  if red == nil or green == nil or blue == nil then
    return fallback
  end

  local function brighten(channel)
    return math.floor(channel + (255 - channel) * amount + 0.5)
  end

  return string.format("#%02x%02x%02x", brighten(red), brighten(green), brighten(blue))
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
function M.monotonic_now_ms()
  if type(host_api.now_ms) == "function" then
    local ok, value = pcall(host_api.now_ms)
    if ok and type(value) == "number" then
      return math.floor(value)
    end
  end

  return math.floor(os.time() * 1000)
end

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

  if is_hex_color(style) then
    segment.fg = style
    return segment
  end

  style = resolve_segment_style(style)
  if type(style) == "table" then
    segment.bold = style.bold == true
    if type(style.id) == "string" and style.id ~= "" then
      segment.id = style.id
    end
    if is_hex_color(style.fg) then
      segment.fg = style.fg
    end
    if is_hex_color(style.bg) then
      segment.bg = style.bg
    end
  end

  return segment
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
  if type(value) == "string" then
    return M.style_to_segment(value, style)
  end

  if type(value) == "table" then
    if value._type == "span" then
      return M.style_to_segment(
        value.text or fallback_text,
        M.merge_style_tables(style, value.style)
      )
    end

    if value.text ~= nil or value.fg ~= nil or value.bg ~= nil or value.bold ~= nil then
      local merged_style = M.merge_style_tables(style, {
        fg = value.fg,
        bg = value.bg,
        bold = value.bold,
      })
      local text = type(value.text) == "string" and value.text or fallback_text
      return M.style_to_segment(text, merged_style)
    end
  end

  return M.style_to_segment(fallback_text, style)
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
    return { color = "#000000", alpha = DEFAULT_THEME.backdrop.alpha }
  end

  if is_hex_color(value) then
    return { color = value, alpha = DEFAULT_THEME.backdrop.alpha }
  end

  if type(value) == "table" then
    local color = normalize_hex_color(value.color or value.bg, "#000000")
    local alpha = tonumber(value.alpha)
    if alpha == nil then
      alpha = DEFAULT_THEME.backdrop.alpha
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
  if bg == nil and border == nil then
    return nil
  end

  return { bg = bg, border = border }
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
    if type(host_api.log) == "function" then
      host_api.log("[hollow.ui] render_widget: widget_ctx error: " .. tostring(ctx))
    end
    return nil
  end

  local ok, rendered = pcall(widget.render, ctx)
  if not ok then
    if type(host_api.log) == "function" then
      host_api.log("[hollow.ui] render_widget: render error: " .. tostring(rendered))
    end
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

-- ---------------------------------------------------------------------------
-- Theme resolution
-- All defaults come from DEFAULT_THEME above.
-- ---------------------------------------------------------------------------

---@param kind string
---@return HollowUiTheme
function M.resolve_widget_theme(kind)
  local values = type(state.config.values) == "table" and state.config.values or {}
  local legacy = type(values.theme) == "table" and values.theme or {}
  local ui_theme = type(values.ui_theme) == "table" and values.ui_theme or legacy
  local terminal_theme = type(values.terminal_theme) == "table" and values.terminal_theme or legacy

  local ansi = table_field(terminal_theme, "ansi")
  local brights = table_field(terminal_theme, "brights")
  local status = table_field(ui_theme, "status")
  local tab_bar = table_field(ui_theme, "tab_bar")
  local workspace = table_field(ui_theme, "workspace")
  local workspace_active = table_field(workspace, "active")

  local accent = ui_theme.accent or ansi[5]
  local warm = ui_theme.warm or brights[4]
  local split = ui_theme.split or status.fg

  local resolved = {
    panel_bg = brighten_hex_color(terminal_theme.background, 0.2, nil),
    panel_border = normalize_hex_color(accent, nil),
    divider = normalize_hex_color(split, nil),
    title = normalize_hex_color(accent, nil),
    fg = normalize_hex_color(terminal_theme.foreground, nil),
    muted = normalize_hex_color(status.fg or brights[1], nil),
    input_bg = normalize_hex_color(tab_bar.background or terminal_theme.background, nil),
    input_fg = normalize_hex_color(terminal_theme.foreground, nil),
    cursor_bg = normalize_hex_color(terminal_theme.foreground, nil),
    cursor_fg = normalize_hex_color(terminal_theme.background, nil),
    selected_bg = normalize_hex_color(status.bg or tab_bar.background, nil),
    selected_detail_bg = normalize_hex_color(status.bg or tab_bar.background, nil),
    selected_fg = normalize_hex_color(terminal_theme.foreground, nil),
    selected_muted = normalize_hex_color(workspace_active.fg or terminal_theme.foreground, nil),
    detail = normalize_hex_color(status.fg, nil),
    notify_fg = normalize_hex_color(terminal_theme.foreground, nil),
    counter = normalize_hex_color(status.fg, nil),
    empty = normalize_hex_color(status.fg, nil),
    scrollbar_track = normalize_hex_color(split, nil),
    scrollbar_thumb = normalize_hex_color(accent, nil),
    notify_levels = {
      info = normalize_hex_color(accent, nil),
      warn = normalize_hex_color(warm, nil),
      error = normalize_hex_color(brights[2] or ansi[2], nil),
      success = normalize_hex_color(brights[3], nil),
    },
  }

  local widgets = table_field(ui_theme, "widgets")
  local all_widgets = table_field(widgets, "all")
  local widget_theme = table_field(widgets, kind)
  util.merge_tables(resolved, clone_table(all_widgets))
  util.merge_tables(resolved, clone_table(widget_theme))

  local result = clone_table(DEFAULT_THEME)
  for key, value in pairs(resolved) do
    if value ~= nil then
      if type(value) == "table" and type(result[key]) == "table" then
        util.merge_tables(result[key], value)
      else
        result[key] = value
      end
    end
  end

  -- `false` is a deliberate user override that disables the backdrop entirely.
  if resolved.backdrop == false then
    result.backdrop = nil
  elseif resolved.backdrop ~= nil then
    result.backdrop = M.normalize_overlay_backdrop(resolved.backdrop)
      or { color = DEFAULT_THEME.backdrop.color, alpha = DEFAULT_THEME.backdrop.alpha }
  end

  return result
end

return M
