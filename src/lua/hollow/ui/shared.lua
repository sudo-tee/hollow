local util  = require("hollow.util")
local state = require("hollow.state").get()

local hollow  = _G.hollow
local host_api = state.host_api

local M = {}

-- ---------------------------------------------------------------------------
-- Default theme values
-- All fallback colors and the backdrop alpha live here and only here.
-- resolve_widget_theme() merges user config on top of these.
-- ---------------------------------------------------------------------------

local DEFAULT_THEME = {
  panel_bg          = "#1f2430",
  panel_border      = "#88c0d0",
  divider           = "#2b3240",
  title             = "#88c0d0",
  fg                = "#d8dee9",
  muted             = "#9aa5b1",
  input_bg          = "#20242f",
  input_fg          = "#d8dee9",
  cursor_bg         = "#d8dee9",
  cursor_fg         = "#1f2430",
  selected_bg       = "#3b4252",
  selected_detail_bg = "#313745",
  selected_fg       = "#eceff4",
  selected_muted    = "#cfd8e3",
  detail            = "#8b95a1",
  notify_fg         = "#d8dee9",
  counter           = "#667084",
  empty             = "#9aa5b1",
  scrollbar_track   = "#5a6375",
  scrollbar_thumb   = "#88c0d0",
  backdrop          = { color = "#000000", alpha = 170 },
  notify_levels = {
    info    = "#88c0d0",
    warn    = "#ebcb8b",
    error   = "#ffb4a9",
    success = "#a3be8c",
  },
}

-- ---------------------------------------------------------------------------
-- Helpers: time, window size
-- ---------------------------------------------------------------------------

function M.monotonic_now_ms()
  if type(host_api.now_ms) == "function" then
    local ok, value = pcall(host_api.now_ms)
    if ok and type(value) == "number" then return math.floor(value) end
  end
  return math.floor(os.time() * 1000)
end

function M.epoch_now_ms()
  return math.floor(os.time() * 1000)
end

function M.window_size_snapshot()
  return {
    rows   = 0,
    cols   = 0,
    width  = host_api.get_window_width  and host_api.get_window_width()  or 0,
    height = host_api.get_window_height and host_api.get_window_height() or 0,
  }
end

-- ---------------------------------------------------------------------------
-- Node type predicates
-- ---------------------------------------------------------------------------

function M.is_span_node(value)
  return type(value) == "table"
    and (
      value._type == "span"
      or value._type == "spacer"
      or value._type == "icon"
      or value._type == "group"
    )
end

function M.is_text_shorthand(value)
  return type(value) == "table" and value._type == nil and type(value[1]) == "string"
end

function M.normalize_text_shorthand(value)
  if type(value) ~= "table" then
    return { _type = "span", text = tostring(value or "") }
  end
  local style = nil
  if type(value.style) == "table" then
    style = {}
    for k, v in pairs(value.style) do style[k] = v end
  end
  for k, v in pairs(value) do
    if type(k) ~= "number" and k ~= "_type" and k ~= "text" and k ~= "style" then
      style = style or {}
      style[k] = v
    end
  end
  return { _type = "span", text = value[1] or value.text or "", style = style }
end

function M.is_inline_node(value)
  return M.is_span_node(value) or M.is_text_shorthand(value)
end

function M.normalize_inline_nodes(value)
  if type(value) == "string" then return { { _type = "span", text = value } } end
  if M.is_span_node(value) then return { value } end
  if M.is_text_shorthand(value) then return { M.normalize_text_shorthand(value) } end
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
    if #nodes > 0 then return nodes end
  end
  return { { _type = "span", text = tostring(value or "") } }
end

function M.flatten_span_nodes(nodes, inherited_style, out)
  out = out or {}
  inherited_style = inherited_style or {}
  for _, node in ipairs(nodes or {}) do
    if type(node) == "table" then
      if node._type == "group" then
        local merged_style = util.clone_value(inherited_style)
        if type(node.style) == "table" then util.merge_tables(merged_style, node.style) end
        M.flatten_span_nodes(node.children or {}, merged_style, out)
      elseif node._type == "spacer" then
        out[#out + 1] = { text = " ", spacer = true, style = util.clone_value(inherited_style) }
      elseif node._type == "icon" then
        local style = util.clone_value(inherited_style)
        if type(node.style) == "table" then util.merge_tables(style, node.style) end
        out[#out + 1] = { text = node.name or "", style = style }
      elseif node._type == "span" then
        local style = util.clone_value(inherited_style)
        if type(node.style) == "table" then util.merge_tables(style, node.style) end
        out[#out + 1] = { text = node.text or "", style = style }
      end
    end
  end
  return out
end

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

function M.style_to_segment(text, style)
  local segment = { text = text }
  if type(style) == "string" and style:match("^#%x%x%x%x%x%x$") then
    segment.fg = style
    return segment
  end
  if type(style) == "table" and type(style.style) == "table" then style = style.style end
  if type(style) == "table" then
    segment.bold = style.bold == true
    if type(style.id)  == "string" and style.id  ~= "" then segment.id  = style.id  end
    if type(style.fg)  == "string" and style.fg:match("^#%x%x%x%x%x%x$") then segment.fg = style.fg end
    if type(style.bg)  == "string" and style.bg:match("^#%x%x%x%x%x%x$") then segment.bg = style.bg end
  end
  return segment
end

function M.merge_style_tables(base, overlay_style)
  local merged = {}
  if type(base)          == "table" then util.merge_tables(merged, base) end
  if type(overlay_style) == "table" then util.merge_tables(merged, overlay_style) end
  return merged
end

function M.normalize_bar_items(rendered)
  if type(rendered) ~= "table" then return {} end
  if rendered._type ~= nil then return { rendered } end
  return rendered
end

function M.bar_value_to_segment(value, fallback_text, style)
  if type(value) == "string" then return M.style_to_segment(value, style) end
  if type(value) == "table" then
    if value._type == "span" then
      return M.style_to_segment(value.text or fallback_text, M.merge_style_tables(style, value.style))
    end
    if value.text ~= nil or value.fg ~= nil or value.bg ~= nil or value.bold ~= nil then
      local merged_style = M.merge_style_tables(style, { fg = value.fg, bg = value.bg, bold = value.bold })
      return M.style_to_segment(type(value.text) == "string" and value.text or fallback_text, merged_style)
    end
  end
  return M.style_to_segment(fallback_text, style)
end

-- ---------------------------------------------------------------------------
-- Fuzzy search
-- ---------------------------------------------------------------------------

function M.filter_ascii_words(text)
  local words = {}
  for part in tostring(text or ""):lower():gmatch("[a-z0-9]+") do words[#words + 1] = part end
  return words
end

local function substring_score(haystack, needle)
  haystack = tostring(haystack or ""):lower()
  needle   = tostring(needle   or ""):lower()
  if needle == "" then return 0 end
  local start_idx, end_idx = haystack:find(needle, 1, true)
  if start_idx == nil then return nil end
  return 2000 - (start_idx * 4) - (end_idx - start_idx + 1)
end

local function subsequence_score(haystack, needle)
  haystack = tostring(haystack or ""):lower()
  needle   = tostring(needle   or ""):lower()
  if needle == "" then return 0 end
  local pos, start_idx, last_idx, gaps, streak_bonus = 1, nil, nil, 0, 0
  for i = 1, #needle do
    local found = haystack:find(needle:sub(i, i), pos, true)
    if found == nil then return nil end
    if start_idx == nil then
      start_idx = found
    elseif last_idx ~= nil then
      local gap = found - last_idx - 1
      gaps = gaps + gap
      if gap == 0 then streak_bonus = streak_bonus + 8 end
    end
    last_idx = found
    pos = found + 1
  end
  return 1000 - (start_idx or 1) * 3 - gaps * 5 + streak_bonus
end

function M.fuzzy_match_score(text, query)
  text  = tostring(text  or "")
  query = tostring(query or "")
  if query == "" then return 0 end
  local best = substring_score(text, query)
  local subseq = subsequence_score(text, query)
  if subseq ~= nil and (best == nil or subseq > best) then best = subseq end
  for _, word in ipairs(M.filter_ascii_words(text)) do
    local ws = substring_score(word, query)
    if ws ~= nil then
      ws = ws + 120
      if best == nil or ws > best then best = ws end
    end
    local wss = subsequence_score(word, query)
    if wss ~= nil then
      wss = wss + 60
      if best == nil or wss > best then best = wss end
    end
  end
  return best
end

function M.plain_match_score(text, query) return substring_score(text, query) end

function M.select_item_matches(query, searchable, fuzzy)
  if query == "" then return true, 0 end
  local score = fuzzy and M.fuzzy_match_score(searchable, query) or M.plain_match_score(searchable, query)
  if score == nil then return false, nil end
  return true, score
end

-- ---------------------------------------------------------------------------
-- Key input
-- ---------------------------------------------------------------------------

function M.printable_char_for_key(key, mods)
  local shifted = mods == "<S>"
  if mods ~= nil and mods ~= "" and not shifted then return nil end
  if type(key) ~= "string" or key == "" then return nil end
  if #key == 1 then return shifted and key:upper() or key end
  if key:match("^digit_[0-9]$") then
    local digit = key:sub(-1)
    if not shifted then return digit end
    local map = { ["1"]="!", ["2"]="@", ["3"]="#", ["4"]="$", ["5"]="%",
                  ["6"]="^", ["7"]="&", ["8"]="*", ["9"]="(", ["0"]=")" }
    return map[digit]
  end
  local printable = {
    space         = " ",
    minus         = shifted and "_"  or "-",
    equal         = shifted and "+"  or "=",
    bracket_left  = shifted and "{"  or "[",
    bracket_right = shifted and "}"  or "]",
    backslash     = shifted and "|"  or "\\",
    semicolon     = shifted and ":"  or ";",
    quote         = shifted and '"'  or "'",
    backquote     = shifted and "~"  or "`",
    comma         = shifted and "<"  or ",",
    period        = shifted and ">"  or ".",
    slash         = shifted and "?"  or "/",
  }
  return printable[key]
end

-- ---------------------------------------------------------------------------
-- Overlay geometry normalizers
-- ---------------------------------------------------------------------------

function M.normalize_overlay_align(value)
  if type(value) ~= "string" then return "center" end
  local n = value:lower():gsub("[%s%-]", "_")
  local aliases = { right="top_right", left="top_left", bottom="bottom_center", top="top_center",
                    centre="center", middle="center" }
  n = aliases[n] or n
  local allowed = { center=true, top_left=true, top_center=true, top_right=true,
                    left_center=true, right_center=true, bottom_left=true,
                    bottom_center=true, bottom_right=true }
  return allowed[n] and n or "center"
end

function M.normalize_overlay_backdrop(value)
  if value == nil or value == false then return nil end
  if value == true then return { color = "#000000", alpha = DEFAULT_THEME.backdrop.alpha } end
  if type(value) == "string" and value:match("^#%x%x%x%x%x%x$") then
    return { color = value, alpha = DEFAULT_THEME.backdrop.alpha }
  end
  if type(value) == "table" then
    local color = value.color or value.bg or "#000000"
    if type(color) ~= "string" or not color:match("^#%x%x%x%x%x%x$") then color = "#000000" end
    local alpha = tonumber(value.alpha)
    if alpha == nil then alpha = DEFAULT_THEME.backdrop.alpha end
    alpha = math.max(0, math.min(255, math.floor(alpha)))
    return { color = color, alpha = alpha }
  end
  return nil
end

function M.normalize_overlay_size(value)
  local n = tonumber(value)
  if n == nil then return nil end
  n = math.floor(n)
  return n >= 1 and n or nil
end

function M.normalize_hex_color(value, fallback)
  if type(value) == "string" and value:match("^#%x%x%x%x%x%x$") then return value end
  return fallback
end

function M.normalize_overlay_chrome(value)
  value = type(value) == "table" and value or {}
  local bg     = M.normalize_hex_color(value.bg, nil)
  local border = M.normalize_hex_color(value.border, nil)
  if bg == nil and border == nil then return nil end
  return { bg = bg, border = border }
end

-- ---------------------------------------------------------------------------
-- Widget rendering helpers
-- ---------------------------------------------------------------------------

local function safe_call(fn, default)
  if type(fn) ~= "function" then return default end
  local ok, value = pcall(fn)
  return (ok and value ~= nil) and value or default
end

function M.widget_ctx()
  local current_tab  = safe_call(hollow.term.current_tab,  nil)
  local current_pane = safe_call(hollow.term.current_pane, nil)
  return {
    term = {
      tab        = current_tab,
      pane       = current_pane,
      tabs       = safe_call(hollow.term.tabs, {}),
      workspace  = safe_call(hollow.term.current_workspace, nil),
      workspaces = safe_call(hollow.term.workspaces, {}),
    },
    size = M.window_size_snapshot(),
    time = {
      epoch_ms = M.epoch_now_ms(),
      iso      = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    },
  }
end

function M.render_widget(widget)
  if widget == nil or type(widget.render) ~= "function" then return nil end
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

function M.normalize_widget_rows(rendered)
  if type(rendered) ~= "table" then return { {} } end
  local first = rendered[1]
  if first == nil or M.is_span_node(first) then return { rendered } end
  local rows = {}
  for _, row in ipairs(rendered) do
    if type(row) == "table" then rows[#rows + 1] = row end
  end
  return rows
end

function M.render_widget_rows(widget)
  local rendered = M.render_widget(widget)
  if rendered == nil then return { {} } end
  local rows = M.normalize_widget_rows(rendered)
  return rows
end

-- ---------------------------------------------------------------------------
-- Theme resolution
-- All defaults come from DEFAULT_THEME above.
-- ---------------------------------------------------------------------------

local function table_field(value, key)
  if type(value) ~= "table" then return {} end
  local field = value[key]
  return type(field) == "table" and field or {}
end

function M.resolve_widget_theme(kind)
  local values   = type(state.config.values) == "table" and state.config.values or {}
  local legacy   = type(values.theme) == "table"          and values.theme          or {}
  local ui_theme = type(values.ui_theme) == "table"       and values.ui_theme       or legacy
  local t_theme  = type(values.terminal_theme) == "table" and values.terminal_theme or legacy

  local ansi    = table_field(t_theme, "ansi")
  local brights = table_field(t_theme, "brights")
  local status  = table_field(ui_theme, "status")
  local tab_bar = table_field(ui_theme, "tab_bar")
  local ws      = table_field(ui_theme, "workspace")
  local ws_act  = table_field(ws, "active")

  local accent = ui_theme.accent or ansi[5]
  local warm   = ui_theme.warm   or brights[4]
  local split  = ui_theme.split  or status.fg

  -- Build resolved table from config values (may be nil for most keys).
  local resolved = {
    panel_bg          = M.normalize_hex_color(t_theme.background,                nil),
    panel_border      = M.normalize_hex_color(accent,                            nil),
    divider           = M.normalize_hex_color(split,                             nil),
    title             = M.normalize_hex_color(accent,                            nil),
    fg                = M.normalize_hex_color(t_theme.foreground,                nil),
    muted             = M.normalize_hex_color(status.fg or brights[1],          nil),
    input_bg          = M.normalize_hex_color(tab_bar.background or t_theme.background, nil),
    input_fg          = M.normalize_hex_color(t_theme.foreground,                nil),
    cursor_bg         = M.normalize_hex_color(t_theme.foreground,                nil),
    cursor_fg         = M.normalize_hex_color(t_theme.background,                nil),
    selected_bg       = M.normalize_hex_color(status.bg or tab_bar.background,  nil),
    selected_detail_bg = M.normalize_hex_color(status.bg or tab_bar.background, nil),
    selected_fg       = M.normalize_hex_color(t_theme.foreground,                nil),
    selected_muted    = M.normalize_hex_color(ws_act.fg or t_theme.foreground,   nil),
    detail            = M.normalize_hex_color(status.fg,                         nil),
    notify_fg         = M.normalize_hex_color(t_theme.foreground,                nil),
    counter           = M.normalize_hex_color(status.fg,                         nil),
    empty             = M.normalize_hex_color(status.fg,                         nil),
    scrollbar_track   = M.normalize_hex_color(split,                             nil),
    scrollbar_thumb   = M.normalize_hex_color(accent,                            nil),
    notify_levels = {
      info    = M.normalize_hex_color(accent,         nil),
      warn    = M.normalize_hex_color(warm,           nil),
      error   = M.normalize_hex_color(brights[2] or ansi[2], nil),
      success = M.normalize_hex_color(brights[3],     nil),
    },
  }

  -- Merge per-widget and all-widget overrides from config.
  local widgets    = table_field(ui_theme, "widgets")
  local all_widgets = table_field(widgets, "all")
  local widget_theme = table_field(widgets, kind)
  util.merge_tables(resolved, util.clone_value(all_widgets))
  util.merge_tables(resolved, util.clone_value(widget_theme))

  -- Apply defaults from DEFAULT_THEME for any nil fields.
  local result = util.clone_value(DEFAULT_THEME)
  for k, v in pairs(resolved) do
    if v ~= nil then
      if type(v) == "table" and type(result[k]) == "table" then
        util.merge_tables(result[k], v)
      else
        result[k] = v
      end
    end
  end

  -- backdrop: handle override from config (false disables it).
  if resolved.backdrop == false then
    result.backdrop = nil
  elseif resolved.backdrop ~= nil then
    result.backdrop = M.normalize_overlay_backdrop(resolved.backdrop)
      or { color = DEFAULT_THEME.backdrop.color, alpha = DEFAULT_THEME.backdrop.alpha }
  end
  -- backdrop from DEFAULT_THEME is already a plain table; keep it as-is.

  return result
end

return M
