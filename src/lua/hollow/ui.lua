local M = {}

local table_unpack = table.unpack or unpack

local function window_size_snapshot(host_api)
  return {
    rows = 0,
    cols = 0,
    width = host_api.get_window_width and host_api.get_window_width() or 0,
    height = host_api.get_window_height and host_api.get_window_height() or 0,
  }
end

local function is_span_node(value)
  return type(value) == "table"
    and (
      value._type == "span"
      or value._type == "spacer"
      or value._type == "icon"
      or value._type == "group"
    )
end

local function is_text_shorthand(value)
  return type(value) == "table" and value._type == nil and type(value[1]) == "string"
end

local function normalize_text_shorthand(value)
  local style = nil
  if type(value) ~= "table" then
    return { _type = "span", text = tostring(value or "") }
  end

  if type(value.style) == "table" then
    style = {}
    for k, v in pairs(value.style) do
      style[k] = v
    end
  end

  for k, v in pairs(value) do
    if type(k) ~= "number" and k ~= "_type" and k ~= "text" and k ~= "style" then
      style = style or {}
      style[k] = v
    end
  end

  return {
    _type = "span",
    text = value[1] or value.text or "",
    style = style,
  }
end

local function is_inline_node(value)
  return is_span_node(value) or is_text_shorthand(value)
end

local function normalize_inline_nodes(value)
  if type(value) == "string" then
    return { { _type = "span", text = value } }
  end
  if is_span_node(value) then
    return { value }
  end
  if is_text_shorthand(value) then
    return { normalize_text_shorthand(value) }
  end
  if type(value) == "table" then
    local nodes = {}
    for _, node in ipairs(value) do
      if type(node) == "string" then
        nodes[#nodes + 1] = { _type = "span", text = node }
      elseif is_span_node(node) then
        nodes[#nodes + 1] = node
      elseif is_text_shorthand(node) then
        nodes[#nodes + 1] = normalize_text_shorthand(node)
      end
    end
    if #nodes > 0 then
      return nodes
    end
  end
  return { { _type = "span", text = tostring(value or "") } }
end

function M.setup(hollow, host_api, state, util)
  local function monotonic_now_ms()
    if type(host_api.now_ms) == "function" then
      local ok, value = pcall(host_api.now_ms)
      if ok and type(value) == "number" then
        return math.floor(value)
      end
    end
    return math.floor(os.time() * 1000)
  end

  local function epoch_now_ms()
    return math.floor(os.time() * 1000)
  end

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

  local mounted_topbar = function()
    return state.ui.mounted_topbar
  end

  local mounted_bottombar = function()
    return state.ui.mounted_bottombar
  end

  local mounted_sidebar = function()
    return state.ui.mounted_sidebar
  end

  local overlay_stack = state.ui.overlay_stack

  local function widget_ctx()
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
      size = window_size_snapshot(host_api),
      time = {
        epoch_ms = epoch_now_ms(),
        iso = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      },
    }
  end

  local function render_widget(widget)
    if widget == nil or type(widget.render) ~= "function" then
      return nil
    end
    local ok_ctx, ctx = pcall(widget_ctx)
    if not ok_ctx then
      return nil
    end
    local ok, rendered = pcall(widget.render, ctx)
    if not ok then
      return nil
    end
    return rendered
  end

  local function normalize_widget_rows(rendered)
    if type(rendered) ~= "table" then
      return { {} }
    end

    local first = rendered[1]
    if first == nil or is_span_node(first) then
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

  local function render_widget_rows(widget)
    local rendered = render_widget(widget)
    if rendered == nil then
      return { {} }
    end
    return normalize_widget_rows(rendered)
  end

  local function flatten_span_nodes(nodes, inherited_style, out)
    out = out or {}
    inherited_style = inherited_style or {}
    for _, node in ipairs(nodes or {}) do
      if type(node) == "table" then
        if node._type == "group" then
          local merged_style = util.clone_value(inherited_style)
          if type(node.style) == "table" then
            util.merge_tables(merged_style, node.style)
          end
          flatten_span_nodes(node.children or {}, merged_style, out)
        elseif node._type == "spacer" then
          out[#out + 1] = { text = " ", spacer = true, style = util.clone_value(inherited_style) }
        elseif node._type == "icon" then
          local style = util.clone_value(inherited_style)
          if type(node.style) == "table" then
            util.merge_tables(style, node.style)
          end
          out[#out + 1] = { text = node.name or "", style = style }
        elseif node._type == "span" then
          local style = util.clone_value(inherited_style)
          if type(node.style) == "table" then
            util.merge_tables(style, node.style)
          end
          out[#out + 1] = { text = node.text or "", style = style }
        end
      end
    end
    return out
  end

  local function nodes_plain_text(nodes)
    local flattened = flatten_span_nodes(normalize_inline_nodes(nodes))
    local parts = {}
    for _, node in ipairs(flattened) do
      if not node.spacer and node.text and node.text ~= "" then
        parts[#parts + 1] = node.text
      end
    end
    return table.concat(parts)
  end

  local function style_to_segment(text, style)
    local segment = { text = text }
    if type(style) == "string" and style:match("^#%x%x%x%x%x%x$") then
      segment.fg = style
      return segment
    end
    if type(style) == "table" and type(style.style) == "table" then
      style = style.style
    end
    if type(style) == "table" then
      segment.bold = style.bold == true
      if type(style.id) == "string" and style.id ~= "" then
        segment.id = style.id
      end
      if type(style.fg) == "string" and style.fg:match("^#%x%x%x%x%x%x$") then
        segment.fg = style.fg
      end
      if type(style.bg) == "string" and style.bg:match("^#%x%x%x%x%x%x$") then
        segment.bg = style.bg
      end
    end
    return segment
  end

  local function merge_style_tables(base, overlay)
    local merged = {}
    if type(base) == "table" then
      util.merge_tables(merged, base)
    end
    if type(overlay) == "table" then
      util.merge_tables(merged, overlay)
    end
    return merged
  end

  local function normalize_bar_items(rendered)
    if type(rendered) ~= "table" then
      return {}
    end
    if rendered._type ~= nil then
      return { rendered }
    end
    return rendered
  end

  local function bar_value_to_segment(value, fallback_text, style)
    if type(value) == "string" then
      return style_to_segment(value, style)
    end

    if type(value) == "table" then
      if value._type == "span" then
        return style_to_segment(value.text or fallback_text, merge_style_tables(style, value.style))
      end

      if value.text ~= nil or value.fg ~= nil or value.bg ~= nil or value.bold ~= nil then
        local merged_style = merge_style_tables(style, {
          fg = value.fg,
          bg = value.bg,
          bold = value.bold,
        })
        return style_to_segment(
          type(value.text) == "string" and value.text or fallback_text,
          merged_style
        )
      end
    end

    return style_to_segment(fallback_text, style)
  end

  local function dispatch_widget_event(name, e)
    local widgets = {}
    if mounted_topbar() ~= nil then
      widgets[#widgets + 1] = mounted_topbar()
    end
    if mounted_bottombar() ~= nil then
      widgets[#widgets + 1] = mounted_bottombar()
    end
    if mounted_sidebar() ~= nil then
      widgets[#widgets + 1] = mounted_sidebar()
    end
    for _, widget in ipairs(overlay_stack) do
      widgets[#widgets + 1] = widget
    end
    for _, widget in ipairs(widgets) do
      if type(widget.on_event) == "function" then
        widget.on_event(name, e)
      end
    end
  end

  local function dispatch_overlay_key(key, mods)
    local canonical_mods = hollow.keymap._format_mods(mods)
    for i = #overlay_stack, 1, -1 do
      local widget = overlay_stack[i]
      if type(widget.on_key) == "function" then
        local ok, consumed = pcall(widget.on_key, key, canonical_mods)
        if ok and consumed then
          return true
        end
      end
    end
    return false
  end

  local overlay_row = {}

  local function widget_fill_segments(row)
    local flattened = flatten_span_nodes(overlay_row.nodes(row))
    local segments = {}
    for _, node in ipairs(flattened) do
      if not node.spacer then
        segments[#segments + 1] = style_to_segment(node.text or "", node.style)
      end
    end
    return segments
  end

  local function trim_row_for_width(row, max_chars)
    local flattened = flatten_span_nodes(overlay_row.nodes(row))
    local segments = {}
    local remaining = math.max(0, math.floor(max_chars or 0))
    for _, node in ipairs(flattened) do
      if remaining <= 0 then
        break
      end
      if not node.spacer then
        local text = node.text or ""
        if #text > remaining then
          text = text:sub(1, remaining)
        end
        if #text > 0 then
          segments[#segments + 1] = style_to_segment(text, node.style)
          remaining = remaining - #text
        end
      end
    end
    return segments
  end

  local function validate_widget_opts(opts)
    if type(opts) ~= "table" then
      error("widget opts must be a table")
    end
    if type(opts.render) ~= "function" then
      error("widget opts.render must be a function")
    end
    return opts
  end

  local function make_widget(kind, opts)
    opts = validate_widget_opts(opts)
    return {
      _kind = kind,
      render = opts.render,
      on_event = opts.on_event,
      on_key = opts.on_key,
      on_mount = opts.on_mount,
      on_unmount = opts.on_unmount,
      height = opts.height,
      max_height = opts.max_height,
      width = opts.width,
      side = opts.side,
      align = opts.align,
      backdrop = opts.backdrop,
      chrome = opts.chrome,
      hidden = opts.hidden,
      reserve = opts.reserve,
    }
  end

  local function normalize_overlay_align(value)
    if type(value) ~= "string" then
      return "center"
    end

    local normalized = value:lower():gsub("[%s%-]", "_")
    if normalized == "right" then
      return "top_right"
    elseif normalized == "left" then
      return "top_left"
    elseif normalized == "bottom" then
      return "bottom_center"
    elseif normalized == "top" then
      return "top_center"
    elseif normalized == "centre" then
      return "center"
    elseif normalized == "middle" then
      return "center"
    end

    local allowed = {
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
    return allowed[normalized] and normalized or "center"
  end

  local function close_overlay_widget(widget)
    for i = #overlay_stack, 1, -1 do
      if overlay_stack[i] == widget then
        table.remove(overlay_stack, i)
        if widget.on_unmount then
          widget.on_unmount()
        end
        return widget
      end
    end
    return nil
  end

  local function accepts_text_input_mods(mods)
    return mods == nil or mods == "" or mods == "<S>"
  end

  local function printable_char_for_key(key, mods)
    if not accepts_text_input_mods(mods) then
      return nil
    end

    local shifted = mods == "<S>"
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
      local shifted_digits = {
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
      return shifted_digits[digit]
    end

    local printable = {
      space = shifted and " " or " ",
      minus = shifted and "_" or "-",
      equal = shifted and "+" or "=",
      bracket_left = shifted and "{" or "[",
      bracket_right = shifted and "}" or "]",
      backslash = shifted and "|" or "\\",
      semicolon = shifted and ":" or ";",
      quote = shifted and '"' or "'",
      backquote = shifted and "~" or "`",
      comma = shifted and "<" or ",",
      period = shifted and ">" or ".",
      slash = shifted and "?" or "/",
    }
    return printable[key]
  end

  local function normalize_overlay_backdrop(value)
    if value == nil or value == false then
      return nil
    end

    if value == true then
      return { color = "#000000", alpha = 72 }
    end

    if type(value) == "string" and value:match("^#%x%x%x%x%x%x$") then
      return { color = value, alpha = 72 }
    end

    if type(value) == "table" then
      local color = value.color or value.bg or "#000000"
      if type(color) ~= "string" or not color:match("^#%x%x%x%x%x%x$") then
        color = "#000000"
      end
      local alpha = tonumber(value.alpha)
      if alpha == nil then
        alpha = 72
      end
      alpha = math.max(0, math.min(255, math.floor(alpha)))
      return {
        color = color,
        alpha = alpha,
      }
    end

    return nil
  end

  local function normalize_overlay_size(value)
    local n = tonumber(value)
    if n == nil then
      return nil
    end
    n = math.floor(n)
    if n < 1 then
      return nil
    end
    return n
  end

  local function normalize_hex_color(value, fallback)
    if type(value) == "string" and value:match("^#%x%x%x%x%x%x$") then
      return value
    end
    return fallback
  end

  local function table_field(value, key)
    if type(value) ~= "table" then
      return {}
    end
    local field = value[key]
    if type(field) ~= "table" then
      return {}
    end
    return field
  end

  local function normalize_overlay_chrome(value)
    value = type(value) == "table" and value or {}
    local bg = normalize_hex_color(value.bg, nil)
    local border = normalize_hex_color(value.border, nil)
    if bg == nil and border == nil then
      return nil
    end
    return {
      bg = bg,
      border = border,
    }
  end

  local function resolve_widget_theme(kind)
    local theme = type(state.config.values.theme) == "table" and state.config.values.theme or {}
    local widgets = table_field(theme, "widgets")
    local tab_bar = table_field(theme, "tab_bar")
    local status = table_field(theme, "status")
    local workspace = table_field(theme, "workspace")
    local workspace_active = table_field(workspace, "active")

    local resolved = {
      panel_bg = normalize_hex_color(theme.background, "#1f2430"),
      panel_border = normalize_hex_color(theme.accent, "#88c0d0"),
      divider = normalize_hex_color(theme.split or status.fg, "#2b3240"),
      title = normalize_hex_color(theme.accent, "#88c0d0"),
      fg = normalize_hex_color(theme.foreground, "#d8dee9"),
      muted = normalize_hex_color(status.fg, "#9aa5b1"),
      input_bg = normalize_hex_color(tab_bar.background or theme.background, "#20242f"),
      input_fg = normalize_hex_color(theme.foreground, "#d8dee9"),
      cursor_bg = normalize_hex_color(theme.foreground, "#d8dee9"),
      cursor_fg = normalize_hex_color(theme.background, "#1f2430"),
      selected_bg = normalize_hex_color(status.bg or tab_bar.background, "#3b4252"),
      selected_detail_bg = normalize_hex_color(status.bg or tab_bar.background, "#313745"),
      selected_fg = normalize_hex_color(theme.foreground, "#eceff4"),
      selected_muted = normalize_hex_color(workspace_active.fg or theme.foreground, "#cfd8e3"),
      detail = normalize_hex_color(status.fg, "#8b95a1"),
      notify_fg = normalize_hex_color(theme.foreground, "#d8dee9"),
      counter = normalize_hex_color(status.fg, "#667084"),
      empty = normalize_hex_color(status.fg, "#9aa5b1"),
      scrollbar_track = normalize_hex_color(theme.split or status.fg, "#5a6375"),
      scrollbar_thumb = normalize_hex_color(theme.accent, "#88c0d0"),
      backdrop = normalize_overlay_backdrop({
        color = normalize_hex_color(theme.background, "#000000"),
        alpha = 72,
      }),
      notify_levels = {
        info = normalize_hex_color(theme.accent, "#88c0d0"),
        warn = normalize_hex_color(theme.warm, "#ebcb8b"),
        error = normalize_hex_color(table_field(theme, "brights")[2], "#ffb4a9"),
        success = normalize_hex_color(table_field(theme, "brights")[3], "#a3be8c"),
      },
    }

    util.merge_tables(resolved, util.clone_value(table_field(widgets, "all")))
    util.merge_tables(resolved, util.clone_value(table_field(widgets, kind)))

    resolved.panel_bg = normalize_hex_color(resolved.panel_bg, "#1f2430")
    resolved.panel_border = normalize_hex_color(resolved.panel_border, "#88c0d0")
    resolved.divider = normalize_hex_color(resolved.divider, "#2b3240")
    resolved.title = normalize_hex_color(resolved.title, "#88c0d0")
    resolved.fg = normalize_hex_color(resolved.fg, "#d8dee9")
    resolved.muted = normalize_hex_color(resolved.muted, "#9aa5b1")
    resolved.input_bg = normalize_hex_color(resolved.input_bg, "#20242f")
    resolved.input_fg = normalize_hex_color(resolved.input_fg, "#d8dee9")
    resolved.cursor_bg = normalize_hex_color(resolved.cursor_bg, "#d8dee9")
    resolved.cursor_fg = normalize_hex_color(resolved.cursor_fg, "#1f2430")
    resolved.selected_bg = normalize_hex_color(resolved.selected_bg, "#3b4252")
    resolved.selected_detail_bg = normalize_hex_color(resolved.selected_detail_bg, "#313745")
    resolved.selected_fg = normalize_hex_color(resolved.selected_fg, "#eceff4")
    resolved.selected_muted = normalize_hex_color(resolved.selected_muted, "#cfd8e3")
    resolved.detail = normalize_hex_color(resolved.detail, "#8b95a1")
    resolved.notify_fg = normalize_hex_color(resolved.notify_fg, "#d8dee9")
    resolved.counter = normalize_hex_color(resolved.counter, "#667084")
    resolved.empty = normalize_hex_color(resolved.empty, "#9aa5b1")
    resolved.scrollbar_track = normalize_hex_color(resolved.scrollbar_track, "#5a6375")
    resolved.scrollbar_thumb = normalize_hex_color(resolved.scrollbar_thumb, "#88c0d0")
    if resolved.backdrop == false then
      resolved.backdrop = nil
    else
      resolved.backdrop = normalize_overlay_backdrop(resolved.backdrop)
        or {
          color = "#000000",
          alpha = 72,
        }
    end

    local levels = type(resolved.notify_levels) == "table" and resolved.notify_levels or {}
    resolved.notify_levels = {
      info = normalize_hex_color(levels.info, "#88c0d0"),
      warn = normalize_hex_color(levels.warn, "#ebcb8b"),
      error = normalize_hex_color(levels.error, "#ffb4a9"),
      success = normalize_hex_color(levels.success, "#a3be8c"),
    }

    return resolved
  end

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

  function overlay_row.nodes(row)
    if type(row) == "table" and row._overlay_row == true then
      return row.nodes or {}
    end
    return row or {}
  end

  local function overlay_row_opts(props)
    return {
      fill_bg = props.fill_bg,
      divider = props.divider,
      scrollbar_track = props.scrollbar_track,
      scrollbar_thumb = props.scrollbar_thumb,
      scrollbar_track_color = props.scrollbar_track_color,
      scrollbar_thumb_color = props.scrollbar_thumb_color,
    }
  end

  local function OverlayRow(props)
    return overlay_row.make(hollow.ui.row(" ", table_unpack(props.children or {})), overlay_row_opts(props))
  end

  local function OverlayDivider(props)
    return overlay_row.make({}, {
      divider = props.color or props.divider,
    })
  end

  local function filter_ascii_words(text)
    local words = {}
    for part in tostring(text or ""):lower():gmatch("[a-z0-9]+") do
      words[#words + 1] = part
    end
    return words
  end

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

    local span = end_idx - start_idx + 1
    return 2000 - (start_idx * 4) - span
  end

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
      local ch = needle:sub(i, i)
      local found = haystack:find(ch, pos, true)
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

  local function fuzzy_match_score(text, query)
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

    for _, word in ipairs(filter_ascii_words(text)) do
      local word_score = substring_score(word, query)
      if word_score ~= nil then
        word_score = word_score + 120
        if best == nil or word_score > best then
          best = word_score
        end
      end

      local word_subseq = subsequence_score(word, query)
      if word_subseq ~= nil then
        word_subseq = word_subseq + 60
        if best == nil or word_subseq > best then
          best = word_subseq
        end
      end
    end

    return best
  end

  local function plain_match_score(text, query)
    return substring_score(text, query)
  end

  local function select_item_matches(query, searchable, fuzzy)
    if query == "" then
      return true, 0
    end
    local score
    if fuzzy then
      score = fuzzy_match_score(searchable, query)
    else
      score = plain_match_score(searchable, query)
    end
    if score == nil then
      return false, nil
    end
    return true, score
  end

  function hollow.ui.span(text, style)
    return { _type = "span", text = text, style = style }
  end

  function hollow.ui.text(value, style)
    if style == nil and is_text_shorthand(value) then
      return normalize_text_shorthand(value)
    end
    if style == nil and is_span_node(value) then
      return value
    end
    return hollow.ui.span(tostring(value or ""), style)
  end

  function hollow.ui.spacer()
    return { _type = "spacer" }
  end

  function hollow.ui.icon(name, style)
    return { _type = "icon", name = tostring(name or ""), style = style }
  end

  function hollow.ui.group(children, style)
    return { _type = "group", children = children or {}, style = style }
  end

  function hollow.ui.row(...)
    local args = { ... }
    local row = {}
    for _, value in ipairs(args) do
      local nodes = normalize_inline_nodes(value)
      for _, node in ipairs(nodes) do
        row[#row + 1] = node
      end
    end
    return row
  end

  function hollow.ui.rows(...)
    local args = { ... }
    local rows = {}

    local function push(value)
      if value == nil or value == false then
        return
      end
      if type(value) ~= "table" then
        return
      end
      if value._overlay_row == true then
        rows[#rows + 1] = value
        return
      end

      local first = value[1]
      if type(first) == "string" or is_inline_node(first) then
        rows[#rows + 1] = value
        return
      end

      for _, item in ipairs(value) do
        push(item)
      end
    end

    for _, value in ipairs(args) do
      push(value)
    end

    return rows
  end

  hollow.ui.tags = setmetatable({}, {
    __index = function(_, name)
      return function(props, ...)
        local args = { ... }
        -- overlay_row and divider are registered explicitly below; this branch
        -- handles the standard inline-node tag names.
        local children
        if props == nil then
          children = args
          props = {}
        elseif type(props) ~= "table" or is_inline_node(props) then
          children = { props, table_unpack(args) }
          props = {}
        else
          children = args
        end

        if name == "spacer" then
          return hollow.ui.spacer()
        elseif name == "icon" then
          local icon_name = props.name or children[1] or ""
          return hollow.ui.icon(icon_name, props.style or props)
        elseif name == "row" then
          return hollow.ui.row(table_unpack(children))
        elseif name == "rows" then
          return hollow.ui.rows(table_unpack(children))
        elseif name == "group" then
          return hollow.ui.group(hollow.ui.row(table_unpack(children)), props.style or props)
        elseif name == "button" then
          local button_opts = util.clone_value(props)
          if button_opts.text == nil then
            button_opts.text = nodes_plain_text(children)
          end
          return hollow.ui.button(button_opts)
        elseif name == "span" or name == "text" then
          if #children <= 1 and (
            type(children[1]) == "string"
            or type(children[1]) == "number"
            or children[1] == nil
            or is_text_shorthand(children[1])
            or is_span_node(children[1])
          ) then
            return hollow.ui.text(children[1] or "", props.style or props)
          end
          return hollow.ui.group(hollow.ui.row(table_unpack(children)), props.style or props)
        end

        return hollow.ui.group(hollow.ui.row(table_unpack(children)), props.style or props)
      end
    end,
  })

  -- Expose overlay_row and divider as first-class tags so render functions
  -- can use t.overlay_row(props, ...) / t.divider(props) instead of h().
  hollow.ui.tags.overlay_row = function(props, ...)
    props = type(props) == "table" and props or {}
    local children = { ... }
    props.children = children
    return OverlayRow(props)
  end

  hollow.ui.tags.divider = function(props)
    props = type(props) == "table" and props or {}
    return OverlayDivider(props)
  end

  function hollow.ui.button(opts)
    opts = opts or {}
    local style = util.clone_value(opts.style or {})
    style.id = opts.id
    style.on_click = opts.on_click
    style.on_mouse_enter = opts.on_mouse_enter
    style.on_mouse_leave = opts.on_mouse_leave
    return hollow.ui.span(opts.text or "", style)
  end

  hollow.ui.bar = hollow.ui.bar or {}

  -- Bar item constructors are shared across bar surfaces.
  function hollow.ui.bar.tabs(opts)
    opts = opts or {}
    opts._type = "bar_tabs"
    return opts
  end

  function hollow.ui.bar.workspace(opts)
    opts = opts or {}
    opts._type = "bar_workspace"
    return opts
  end

  function hollow.ui.bar.time(fmt, opts)
    opts = opts or {}
    opts._type = "bar_time"
    opts.format = fmt
    return opts
  end

  function hollow.ui.bar.key_legend(opts)
    opts = opts or {}
    opts._type = "bar_key_legend"
    return opts
  end

  function hollow.ui.bar.custom(opts)
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

  hollow.ui.topbar = hollow.ui.topbar or {}

  function hollow.ui.topbar.new(opts)
    return make_widget("topbar", opts)
  end

  function hollow.ui.topbar.mount(widget)
    if state.ui.mounted_topbar ~= nil and state.ui.mounted_topbar.on_unmount then
      state.ui.mounted_topbar.on_unmount()
    end
    state.ui.mounted_topbar = widget
    if widget.on_mount then
      widget.on_mount()
    end
  end

  function hollow.ui.topbar.unmount()
    local widget = state.ui.mounted_topbar
    if widget and widget.on_unmount then
      widget.on_unmount()
    end
    state.ui.mounted_topbar = nil
  end

  function hollow.ui.topbar.invalidate()
    return state.ui.mounted_topbar ~= nil
  end

  hollow.ui.bottombar = hollow.ui.bottombar or {}

  function hollow.ui.bottombar.new(opts)
    return make_widget("bottombar", opts)
  end

  function hollow.ui.bottombar.mount(widget)
    if state.ui.mounted_bottombar ~= nil and state.ui.mounted_bottombar.on_unmount then
      state.ui.mounted_bottombar.on_unmount()
    end
    state.ui.mounted_bottombar = widget
    if widget.on_mount then
      widget.on_mount()
    end
  end

  function hollow.ui.bottombar.unmount()
    local widget = state.ui.mounted_bottombar
    if widget and widget.on_unmount then
      widget.on_unmount()
    end
    state.ui.mounted_bottombar = nil
  end

  function hollow.ui.bottombar.invalidate()
    return state.ui.mounted_bottombar ~= nil
  end

  hollow.ui.sidebar = hollow.ui.sidebar or {}

  function hollow.ui.sidebar.new(opts)
    return make_widget("sidebar", opts)
  end

  function hollow.ui.sidebar.mount(widget)
    if state.ui.mounted_sidebar ~= nil and state.ui.mounted_sidebar.on_unmount then
      state.ui.mounted_sidebar.on_unmount()
    end
    state.ui.mounted_sidebar = widget
    state.ui.sidebar_visible = widget.hidden ~= true
    if widget.on_mount then
      widget.on_mount()
    end
  end

  function hollow.ui.sidebar.unmount()
    if state.ui.mounted_sidebar and state.ui.mounted_sidebar.on_unmount then
      state.ui.mounted_sidebar.on_unmount()
    end
    state.ui.mounted_sidebar = nil
    state.ui.sidebar_visible = false
  end

  function hollow.ui.sidebar.toggle()
    if state.ui.mounted_sidebar == nil then
      return false
    end
    state.ui.sidebar_visible = not state.ui.sidebar_visible
    return state.ui.sidebar_visible
  end

  function hollow.ui.sidebar.invalidate()
    return state.ui.mounted_sidebar ~= nil
  end

  hollow.ui.overlay = hollow.ui.overlay or {}

  function hollow.ui.overlay.new(opts)
    return make_widget("overlay", opts)
  end

  function hollow.ui.overlay.push(widget)
    table.insert(overlay_stack, widget)
    if widget.on_mount then
      widget.on_mount()
    end
  end

  function hollow.ui.overlay.pop()
    local widget = table.remove(overlay_stack)
    if widget and widget.on_unmount then
      widget.on_unmount()
    end
    return widget
  end

  function hollow.ui.overlay.clear()
    while #overlay_stack > 0 do
      hollow.ui.overlay.pop()
    end
  end

  function hollow.ui.overlay.depth()
    return #overlay_stack
  end

  function hollow.ui.overlay.remove(widget)
    return close_overlay_widget(widget)
  end

  function hollow.ui.resolve_theme(kind)
    return resolve_widget_theme(kind)
  end

  local function mounted_bar_widget(surface)
    if surface == "topbar" then
      return state.ui.mounted_topbar
    end
    if surface == "bottombar" then
      return state.ui.mounted_bottombar
    end
    return nil
  end

  local function hovered_bar_id_key(surface)
    if surface == "topbar" then
      return "topbar_hovered_id"
    end
    if surface == "bottombar" then
      return "bottombar_hovered_id"
    end
    return nil
  end

  local function call_bar_node_handler(surface, node_id, field, payload)
    local widget = mounted_bar_widget(surface)
    if widget == nil or type(node_id) ~= "string" or node_id == "" then
      return false
    end

    local rendered = normalize_bar_items(render_widget(widget))

    local function visit(nodes)
      for _, node in ipairs(nodes) do
        if type(node) == "table" then
          if node._type == "group" then
            if visit(node.children or {}) then
              return true
            end
          elseif
            node._type == "bar_custom"
            and type(node.id) == "string"
            and node.id == node_id
          then
            if type(node[field]) == "function" then
              node[field](payload)
              return true
            end
          else
            local style = node.style
            if
              type(style) == "table"
              and style.id == node_id
              and type(style[field]) == "function"
            then
              style[field](payload)
              return true
            end
          end
        end
      end
      return false
    end

    return visit(rendered)
  end

  local function handle_bar_node_event(kind, payload)
    if type(payload) ~= "table" then
      return
    end
    local node_id = payload.id
    if type(node_id) ~= "string" or node_id == "" then
      return
    end

    local surface = kind:match("^(%a+bar):")
    if surface ~= "topbar" and surface ~= "bottombar" then
      return
    end
    local hovered_key = hovered_bar_id_key(surface)
    if hovered_key == nil then
      return
    end

    if kind == surface .. ":hover" then
      if state.ui[hovered_key] ~= node_id then
        if state.ui[hovered_key] ~= nil then
          call_bar_node_handler(
            surface,
            state.ui[hovered_key],
            "on_mouse_leave",
            { id = state.ui[hovered_key] }
          )
        end
        state.ui[hovered_key] = node_id
        call_bar_node_handler(surface, node_id, "on_mouse_enter", payload)
      end
      return
    end

    if kind == surface .. ":leave" then
      if state.ui[hovered_key] ~= nil then
        call_bar_node_handler(
          surface,
          state.ui[hovered_key],
          "on_mouse_leave",
          { id = state.ui[hovered_key] }
        )
        state.ui[hovered_key] = nil
      end
      return
    end

    if kind == surface .. ":click" then
      call_bar_node_handler(surface, node_id, "on_click", payload)
    end
  end

  local serialize_bar_item = function(node, ctx)
    if type(node) ~= "table" then
      return nil
    end

    if node._type == "bar_tabs" then
      local tabs = {}
      for _, tab in ipairs(ctx.term.tabs or {}) do
        local tab_state = {
          id = tab.id,
          title = tab.title ~= "" and tab.title or "shell",
          index = tab.index,
          is_active = tab.is_active == true,
          is_hovered = false,
          is_hover_close = false,
          pane = tab.pane,
          panes = tab.panes or {},
        }
        local style = node.style
        if type(style) == "function" then
          local ok, resolved = pcall(style, tab_state, ctx)
          style = ok and resolved or nil
        end
        local label = tab_state.title
        if type(node.format) == "function" then
          local ok, resolved = pcall(node.format, tab_state, ctx)
          if ok then
            label = resolved
          end
        end
        local seg = bar_value_to_segment(label, tab_state.title, style)
        tabs[#tabs + 1] = seg
      end
      return {
        kind = "tabs",
        fit = node.fit == "content" and "content" or "fill",
        tabs = tabs,
      }
    end

    if node._type == "bar_workspace" then
      local ws = ctx.term.workspace
      local workspace_state = {
        index = ws and ws.index or 1,
        name = ws and ws.name or "ws",
        is_active = true,
        active_index = ws and ws.index or 1,
        count = #ctx.term.workspaces,
      }
      local text = workspace_state.name
      if type(node.format) == "function" then
        local ok, resolved = pcall(node.format, workspace_state, ctx)
        if ok and type(resolved) == "string" then
          text = resolved
        end
      end
      local style = node.style
      if type(style) == "function" then
        local ok, resolved = pcall(style, workspace_state, ctx)
        style = ok and resolved or nil
      end
      local seg = bar_value_to_segment(text, workspace_state.name, style)
      seg.kind = "segment"
      return seg
    end

    if node._type == "bar_time" then
      local seg = style_to_segment(os.date(node.format or "%H:%M"), node.style)
      seg.kind = "segment"
      return seg
    end

    if node._type == "bar_key_legend" then
      local leader_state = hollow.keymap.get_leader_state()
      local text = ""
      if
        leader_state
        and leader_state.active
        and leader_state.next_display
        and #leader_state.next_display > 0
      then
        text = " " .. table.concat(leader_state.next_display, "  ") .. " "
      end
      local seg = style_to_segment(text, node.style)
      seg.kind = "segment"
      return seg
    end

    if node._type == "bar_custom" then
      local ok, rendered = pcall(node.render, ctx)
      if not ok then
        return nil
      end
      local seg = nil
      if type(rendered) == "string" then
        seg = { kind = "segment", text = rendered, id = node.id }
      elseif type(rendered) == "table" then
        seg = style_to_segment(rendered.text or "", rendered.style or rendered)
        seg.kind = "segment"
        seg.id = seg.id or node.id
      end
      return seg
    end

    if node._type == "spacer" then
      return { kind = "spacer" }
    end

    if is_span_node(node) then
      local seg = style_to_segment(node.text or node.name or "", node.style)
      seg.kind = "segment"
      return seg
    end

    return nil
  end

  local function serialize_bar_widget(widget)
    if widget == nil then
      return nil
    end
    local ctx = widget_ctx()
    local items = normalize_bar_items(render_widget(widget))
    local out = {}
    for _, item in ipairs(items) do
      local ok, serialized = pcall(serialize_bar_item, item, ctx)
      if serialized ~= nil then
        out[#out + 1] = serialized
      end
    end
    return out
  end

  function hollow.ui._topbar_state()
    return serialize_bar_widget(state.ui.mounted_topbar)
  end

  function hollow.ui._bottombar_state()
    return serialize_bar_widget(state.ui.mounted_bottombar)
  end

  function hollow.ui._bottombar_layout()
    if state.ui.mounted_bottombar == nil then
      return nil
    end
    local height = tonumber(state.ui.mounted_bottombar.height) or 0
    return {
      height = math.max(0, math.floor(height)),
    }
  end

  function hollow.ui._sidebar_state()
    if state.ui.mounted_sidebar == nil or not state.ui.sidebar_visible then
      return nil
    end
    local rows = render_widget_rows(state.ui.mounted_sidebar)
    local side = state.ui.mounted_sidebar.side == "right" and "right" or "left"
    local width = tonumber(state.ui.mounted_sidebar.width) or 24
    local segments = {}
    for i, row in ipairs(rows) do
      segments[i] = trim_row_for_width(row, width)
    end
    return {
      side = side,
      width = math.max(1, math.floor(width)),
      reserve = state.ui.mounted_sidebar.reserve == true,
      rows = segments,
    }
  end

  function hollow.ui._overlay_state()
    if #overlay_stack == 0 then
      return nil
    end
    local rows = {}
    local now = monotonic_now_ms()
    for i = #overlay_stack, 1, -1 do
      local widget = overlay_stack[i]
      local expires_at = widget and widget._expires_at
      if type(expires_at) == "number" and expires_at <= now then
        close_overlay_widget(widget)
      end
    end
    if #overlay_stack == 0 then
      return nil
    end
    for _, widget in ipairs(overlay_stack) do
      local widget_rows = render_widget_rows(widget)
      local seg_rows = {}
      for i, row in ipairs(widget_rows) do
        local serialized_row = {
          segments = widget_fill_segments(row),
        }
        if type(row) == "table" and row._overlay_row == true then
          serialized_row.fill_bg = row.fill_bg
          serialized_row.divider = row.divider
          serialized_row.scrollbar_track = row.scrollbar_track == true
          serialized_row.scrollbar_thumb = row.scrollbar_thumb == true
          serialized_row.scrollbar_track_color = row.scrollbar_track_color
          serialized_row.scrollbar_thumb_color = row.scrollbar_thumb_color
        end
        seg_rows[i] = serialized_row
      end
      rows[#rows + 1] = {
        align = normalize_overlay_align(widget.align),
        backdrop = normalize_overlay_backdrop(widget.backdrop),
        chrome = normalize_overlay_chrome(widget.chrome),
        width = normalize_overlay_size(widget.width),
        height = normalize_overlay_size(widget.height),
        max_height = normalize_overlay_size(widget.max_height),
        rows = seg_rows,
      }
    end
    return rows
  end

  hollow.ui.notify = hollow.ui.notify or {}

  function hollow.ui.notify.show(message, opts)
    opts = opts or {}
    local theme = resolve_widget_theme("notify")
    if type(opts.theme) == "table" then
      util.merge_tables(theme, util.clone_value(opts.theme))
    end
    local title = opts.title and (opts.title .. ": ") or ""
    local ttl = opts.ttl
    local action = opts.action
    local level_color = theme.notify_levels[opts.level or "info"] or theme.title
    local widget
    widget = hollow.ui.overlay.new({
      render = function()
        local t = hollow.ui.tags
        local prefix = "[" .. string.upper(opts.level or "info") .. "] "
        local action_text = action and ("  [" .. action.label .. "]") or ""
        return {
          t.overlay_row(nil,
            t.group({ bg = theme.panel_bg },
              t.text({
                fg = theme.notify_fg,
                bg = theme.panel_bg,
                bold = true,
              }, prefix .. title .. message .. action_text)
            )
          ),
        }
      end,
      align = opts.align,
      chrome = opts.chrome or {
        bg = theme.panel_bg,
        border = level_color,
      },
      backdrop = opts.backdrop,
      on_key = function(key, mods)
        if key == "escape" or key == "enter" then
          close_overlay_widget(widget)
          if action and key == "enter" and type(action.fn) == "function" then
            action.fn()
          end
          return true
        end
        return false
      end,
    })
    widget._notify = true
    hollow.ui.overlay.push(widget)
    if type(ttl) == "number" and ttl > 0 then
      widget._expires_at = monotonic_now_ms() + ttl
    end
    return widget
  end

  function hollow.ui.notify.clear()
    for i = #overlay_stack, 1, -1 do
      local widget = overlay_stack[i]
      if widget and widget._kind == "overlay" and widget._notify == true then
        close_overlay_widget(widget)
      end
    end
    state.ui.notifications = {}
  end

  function hollow.ui.notify.info(message, opts)
    opts = opts or {}
    if opts.level == nil then
      opts.level = "info"
    end
    return hollow.ui.notify.show(message, opts)
  end

  function hollow.ui.notify.warn(message, opts)
    opts = opts or {}
    if opts.level == nil then
      opts.level = "warn"
    end
    return hollow.ui.notify.show(message, opts)
  end

  function hollow.ui.notify.error(message, opts)
    opts = opts or {}
    if opts.level == nil then
      opts.level = "error"
    end
    return hollow.ui.notify.show(message, opts)
  end

  hollow.ui.input = hollow.ui.input or {}

  function hollow.ui.input.open(opts)
    opts = opts or {}
    local theme = resolve_widget_theme("input")
    if type(opts.theme) == "table" then
      util.merge_tables(theme, util.clone_value(opts.theme))
    end
    local backdrop = opts.backdrop
    if backdrop == nil then
      backdrop = theme.backdrop
    end
    local state_local = {
      prompt = opts.prompt or "",
      value = opts.default or "",
    }
    local widget
    widget = hollow.ui.overlay.new({
      render = function()
        local t = hollow.ui.tags
        local caret = (math.floor(monotonic_now_ms() / 530) % 2 == 0) and "|" or " "
        return hollow.ui.rows(
          state_local.prompt ~= "" and hollow.ui.rows(
            t.overlay_row(nil,
              t.text({ fg = theme.title, bold = true }, state_local.prompt)
            ),
            t.divider({ color = theme.divider })
          ),
          t.overlay_row(nil,
            t.text({ fg = theme.input_fg, bg = theme.input_bg }, state_local.value),
            t.text({ fg = theme.cursor_fg, bg = theme.cursor_bg, bold = true }, caret)
          )
        )
      end,
      width = opts.width,
      height = opts.height,
      chrome = opts.chrome or {
        bg = theme.panel_bg,
        border = theme.panel_border,
      },
      backdrop = backdrop,
      on_key = function(key, mods)
        if key == "escape" then
          hollow.ui.overlay.pop()
          if type(opts.on_cancel) == "function" then
            opts.on_cancel()
          end
          return true
        end
        if key == "enter" then
          hollow.ui.overlay.pop()
          if type(opts.on_confirm) == "function" then
            opts.on_confirm(state_local.value)
          end
          return true
        end
        if key == "backspace" then
          state_local.value = state_local.value:sub(1, math.max(0, #state_local.value - 1))
          return true
        end
        local printable = printable_char_for_key(key, mods)
        if printable ~= nil then
          state_local.value = state_local.value .. printable
          return true
        end
        return false
      end,
    })
    hollow.ui.overlay.push(widget)
  end

  function hollow.ui.input.close()
    hollow.ui.overlay.pop()
  end

  hollow.ui.select = hollow.ui.select or {}

  function hollow.ui.select.open(opts)
    opts = opts or {}
    local theme = resolve_widget_theme("select")
    if type(opts.theme) == "table" then
      util.merge_tables(theme, util.clone_value(opts.theme))
    end
    local backdrop = opts.backdrop
    if backdrop == nil then
      backdrop = theme.backdrop
    end
    local fuzzy = opts.fuzzy ~= false
    local default_total_rows = 14
    local state_local = {
      index = 1,
      query = opts.query or "",
      scroll_top = 1,
    }
    local items = opts.items or {}
    local label = opts.label or tostring
    local detail = type(opts.detail) == "function" and opts.detail or nil

    local function filtered_entries()
      local entries = {}
      for source_index, item in ipairs(items) do
        local item_label_value = label(item)
        local item_label_nodes = normalize_inline_nodes(item_label_value)
        local item_label_text = nodes_plain_text(item_label_nodes)
        local item_detail_nodes = nil
        local item_detail_text = nil
        if detail then
          local detail_value = detail(item)
          item_detail_nodes = normalize_inline_nodes(detail_value)
          item_detail_text = nodes_plain_text(item_detail_nodes)
          if item_detail_text == "" then
            item_detail_nodes = nil
            item_detail_text = nil
          end
        end
        local searchable = item_label_text
        if item_detail_text and item_detail_text ~= "" then
          searchable = searchable .. "\n" .. item_detail_text
        end
        local matches, score = select_item_matches(state_local.query, searchable, fuzzy)
        if matches then
          entries[#entries + 1] = {
            item = item,
            label_nodes = item_label_nodes,
            label_text = item_label_text,
            detail_nodes = item_detail_nodes,
            detail_text = item_detail_text,
            source_index = source_index,
            score = score or 0,
          }
        end
      end

      if fuzzy and state_local.query ~= "" then
        table.sort(entries, function(a, b)
          if a.score ~= b.score then
            return a.score > b.score
          end
          if a.label_text ~= b.label_text then
            return a.label_text < b.label_text
          end
          return a.source_index < b.source_index
        end)
      end

      return entries
    end

    local function clamp_index(entries)
      if #entries == 0 then
        state_local.index = 0
      elseif state_local.index < 1 then
        state_local.index = 1
      elseif state_local.index > #entries then
        state_local.index = #entries
      end
    end

    local function entry_row_count(entry)
      if entry.detail_text and entry.detail_text ~= "" then
        return 2
      end
      return 1
    end

    local function list_row_budget()
      local total_rows = normalize_overlay_size(opts.height)
        or normalize_overlay_size(opts.max_height)
        or default_total_rows
      local reserved_rows = 4
      if #(opts.actions or {}) > 0 then
        reserved_rows = reserved_rows + 2
      end
      return math.max(1, total_rows - reserved_rows)
    end

    local function rows_between(entries, first_index, last_index)
      local used = 0
      if first_index == nil or last_index == nil then
        return used
      end
      for i = first_index, last_index do
        local entry = entries[i]
        if entry ~= nil then
          used = used + entry_row_count(entry)
        end
      end
      return used
    end

    local function visible_entries(entries)
      local budget = list_row_budget()
      if #entries == 0 then
        state_local.scroll_top = 1
        return {}
      end

      clamp_index(entries)
      local scroll_top = math.max(1, math.min(state_local.scroll_top or 1, #entries))
      if state_local.index < scroll_top then
        scroll_top = state_local.index
      end
      while
        scroll_top < state_local.index
        and rows_between(entries, scroll_top, state_local.index) > budget
      do
        scroll_top = scroll_top + 1
      end

      local visible = {}
      local used = 0
      local i = scroll_top
      while i <= #entries do
        local entry = entries[i]
        local rows_needed = entry_row_count(entry)
        if #visible > 0 and used + rows_needed > budget then
          break
        end
        visible[#visible + 1] = entry
        used = used + rows_needed
        if used >= budget then
          break
        end
        i = i + 1
      end

      state_local.scroll_top = scroll_top
      return visible
    end

    local function selected_entry(entries)
      local selected = entries[state_local.index]
      if selected ~= nil then
        return selected
      end
      return nil
    end

    local function invoke_action(action_index)
      local entries = filtered_entries()
      clamp_index(entries)
      local action = opts.actions and opts.actions[action_index]
      if action == nil then
        return false
      end
      local entry = entries[state_local.index]
      if entry and type(action.fn) == "function" then
        action.fn(entry.item)
      end
      return true
    end

    local function match_action_for_key(key, mods)
      local actions = opts.actions or {}
      for i, action in ipairs(actions) do
        local hint = action.key
        if type(hint) == "string" and hint ~= "" then
          local normalized = hint:lower():gsub("<cr>", "<enter>")
          if normalized == "<enter>" and key == "enter" and mods == "" then
            return i
          end

          local expected_mods, expected_key = normalized:match("^<([csa%-d]+)%-(.+)>$")
          if expected_mods and expected_key then
            local canonical_parts = {}
            if expected_mods:find("c", 1, true) then
              canonical_parts[#canonical_parts + 1] = "C"
            end
            if expected_mods:find("s", 1, true) then
              canonical_parts[#canonical_parts + 1] = "S"
            end
            if expected_mods:find("a", 1, true) then
              canonical_parts[#canonical_parts + 1] = "A"
            end
            if expected_mods:find("d", 1, true) then
              canonical_parts[#canonical_parts + 1] = "D"
            end
            local canonical_mods = #canonical_parts > 0
                and ("<" .. table.concat(canonical_parts, "-") .. ">")
              or ""
            if canonical_mods == mods and expected_key == key then
              return i
            end
          elseif normalized == key and mods == "" then
            return i
          end
        end
      end
      return nil
    end

    local function render_empty_row()
      local t = hollow.ui.tags
      return t.overlay_row(nil,
        t.text({ fg = theme.empty }, " No matches")
      )
    end

    local function render_entry_rows(entry, is_selected, show_scrollbar, visible_index, thumb_visible_index)
      local t = hollow.ui.tags

      local label_nodes = {
        hollow.ui.span(is_selected and "> " or "  ", {
          fg = is_selected and theme.selected_fg or theme.fg,
          bold = is_selected,
        }),
      }
      for _, node in ipairs(entry.label_nodes or {}) do
        table.insert(label_nodes, node)
      end

      local detail_row = nil
      if entry.detail_text and entry.detail_text ~= "" then
        local detail_nodes = {
          hollow.ui.span("   ", {
            fg = is_selected and theme.selected_muted or theme.detail,
          }),
        }
        for _, node in ipairs(entry.detail_nodes or {}) do
          table.insert(detail_nodes, node)
        end
        detail_row = t.overlay_row({
          fill_bg = is_selected and theme.selected_detail_bg or nil,
        },
          hollow.ui.group(detail_nodes, {
            fg = is_selected and theme.selected_muted or theme.detail,
          })
        )
      end

      return hollow.ui.rows(
        t.overlay_row({
          fill_bg = is_selected and theme.selected_bg or nil,
          scrollbar_track = show_scrollbar,
          scrollbar_thumb = show_scrollbar and visible_index == thumb_visible_index,
          scrollbar_track_color = theme.scrollbar_track,
          scrollbar_thumb_color = theme.scrollbar_thumb,
        },
          hollow.ui.group(label_nodes, {
            fg = is_selected and theme.selected_fg or theme.fg,
            bold = is_selected,
          })
        ),
        detail_row
      )
    end

    local function normalize_hint_chord(raw)
      local parse = hollow.keymap._parse_chord
      local fmt = hollow.keymap._format_chord
      if type(parse) ~= "function" or type(fmt) ~= "function" then
        return raw
      end
      local ok, key, mods = pcall(parse, raw)
      if ok then
        return fmt(key, mods)
      end
      return raw
    end

    local function render_hint_rows()
      local t = hollow.ui.tags
      local hint_nodes = {}
      for _, action in ipairs(opts.actions or {}) do
        local key_hint = action.key
          or (action.name == (opts.actions[1] and opts.actions[1].name) and "<CR>" or nil)
        if key_hint then
          local chord_text = normalize_hint_chord(key_hint)
          local desc_text = action.desc or action.name or "action"
          if #hint_nodes > 0 then
            table.insert(hint_nodes, t.text({ fg = theme.divider }, "  "))
          end
          table.insert(hint_nodes, t.text({ fg = theme.panel_border, bold = true }, chord_text))
          table.insert(hint_nodes, t.text({ fg = theme.muted }, " " .. desc_text))
        end
      end
      if #hint_nodes == 0 then
        return nil
      end

      return hollow.ui.rows(
        t.divider({ color = theme.divider }),
        t.overlay_row(nil, table_unpack(hint_nodes))
      )
    end

    local function append_rows(dst, value)
      if value == nil then
        return dst
      end
      for _, row in ipairs(hollow.ui.rows(value)) do
        table.insert(dst, row)
      end
      return dst
    end

    local widget
    widget = hollow.ui.overlay.new({
      render = function()
        local t = hollow.ui.tags
        local entries = filtered_entries()
        clamp_index(entries)
        local visible = visible_entries(entries)
        local selected = selected_entry(entries)
        local divider_color = theme.divider
        local counter = (#entries > 0) and string.format(" %d/%d", state_local.index, #entries)
          or nil
        local show_scrollbar = #entries > #visible and #visible > 1
        local thumb_visible_index = 1
        if show_scrollbar then
          thumb_visible_index = 1
            + math.floor(((state_local.index - 1) * (#visible - 1)) / math.max(1, #entries - 1))
        end
        local caret = (math.floor(monotonic_now_ms() / 530) % 2 == 0) and "|" or " "
        local rows = hollow.ui.rows(
          t.overlay_row(nil,
            t.text({ fg = theme.title, bold = true }, (opts.prompt or "Select") .. ":"),
            t.text({ fg = theme.counter }, counter and ("  " .. counter) or "")
          ),
          t.divider({ color = divider_color }),
          t.overlay_row(nil,
            t.text({ fg = theme.title, bold = true }, "Filter: "),
            t.text({
              fg = theme.input_fg,
              bg = theme.input_bg,
            }, state_local.query),
            t.text({
              fg = theme.cursor_fg,
              bg = theme.cursor_bg,
              bold = true,
            }, caret)
          ),
          t.divider({ color = divider_color })
        )

        if #entries == 0 then
          table.insert(rows, render_empty_row())
        end

        for visible_index, entry in ipairs(visible) do
          local is_selected = selected ~= nil and entry.source_index == selected.source_index
          append_rows(rows, render_entry_rows(entry, is_selected, show_scrollbar, visible_index, thumb_visible_index))
        end

        append_rows(rows, render_hint_rows())
        return rows
      end,
      on_key = function(key, mods)
        local entries = filtered_entries()
        clamp_index(entries)
        if key == "escape" then
          close_overlay_widget(widget)
          if type(opts.on_cancel) == "function" then
            opts.on_cancel()
          end
          return true
        end
        if key == "arrow_down" then
          if #entries > 0 then
            if state_local.index >= #entries then
              state_local.index = 1
              state_local.scroll_top = 1
            else
              state_local.index = math.max(1, state_local.index) + 1
            end
          end
          return true
        end
        if key == "arrow_up" then
          if #entries > 0 then
            if state_local.index <= 1 then
              state_local.index = #entries
            else
              state_local.index = math.max(1, state_local.index - 1)
            end
          end
          return true
        end
        if key == "backspace" and mods == "" then
          state_local.query = state_local.query:sub(1, math.max(0, #state_local.query - 1))
          state_local.index = 1
          return true
        end
        local printable = printable_char_for_key(key, mods)
        if printable ~= nil then
          state_local.query = state_local.query .. printable
          state_local.index = 1
          return true
        end
        local action_index = match_action_for_key(key, mods or "")
        if action_index ~= nil then
          return invoke_action(action_index)
        end
        if key == "enter" then
          return invoke_action(1)
        end
        return false
      end,
      width = opts.width,
      height = opts.height,
      max_height = opts.max_height,
      chrome = opts.chrome or {
        bg = theme.panel_bg,
        border = theme.panel_border,
      },
      backdrop = backdrop,
    })
    hollow.ui.overlay.push(widget)
  end

  function hollow.ui.select.close()
    hollow.ui.overlay.pop()
  end

  return {
    dispatch_widget_event = dispatch_widget_event,
    dispatch_overlay_key = dispatch_overlay_key,
    handle_bar_node_event = handle_bar_node_event,
  }
end

return M
