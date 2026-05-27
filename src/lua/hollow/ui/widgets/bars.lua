local shared = require("hollow.ui.shared")
local widget_core = require("hollow.ui.widgets.core")

---@type Hollow
local hollow = _G.hollow
local state = require("hollow.state").get()
---@type HollowUi
local ui = hollow.ui
local util = hollow.util

local BAR_CACHE_NO_EXPIRY = false
local DEFAULT_TOPBAR_HEIGHT = 22
local DEFAULT_TOPBAR_LAYOUT = {
  padding = { left = 1, right = 1, top = 1, bottom = 1 },
}

local function resolved_topbar_theme()
  local top_bar = shared.resolve_theme().ui.top_bar or {}
  return {
    height = tonumber(top_bar.height) or DEFAULT_TOPBAR_HEIGHT,
    background = shared.normalize_hex_color(top_bar.background, nil),
  }
end

---@param value any
---@return table|nil
local function optional_table(value)
  return type(value) == "table" and value or nil
end

---@param value any
---@return table
local function clone_table(value)
  return util.clone_value(type(value) == "table" and value or {})
end

---@param base table|nil
---@param overlay table|nil
---@return table
local function merge_tables(base, overlay)
  local result = clone_table(base)
  if type(overlay) == "table" then
    util.merge_tables(result, overlay)
  end
  return result
end

---@param value any
---@return HollowUiRenderableNode|nil
local function configured_topbar_separator(value)
  if value == false then
    return nil
  end
  if type(value) == "string" then
    return ui.span(value)
  end
  if type(value) ~= "table" then
    return nil
  end

  local text = value.text
  if text == nil then
    text = value.value
  end
  if text == nil then
    return nil
  end

  local theme = shared.resolve_theme()
  value.style = merge_tables({
    fg = theme.ui.widgets.all.divider,
  }, value.style)
  return ui.text(text, value.style)
end

---@param ctx HollowWidgetCtx
---@param value any
---@return HollowUiRenderableNode|nil
local function configured_topbar_cwd(ctx, value)
  if value == false then
    return nil
  end

  local pane = ctx.term.pane
  local text = pane and pane.cwd or ""
  local style = nil
  if type(value) == "table" then
    style = value.style
    if type(value.format) == "function" then
      local ok, result = pcall(value.format, pane, ctx)
      if ok then
        text = result
      end
    end
  end

  if text == nil or text == "" then
    return nil
  end
  if type(text) == "string" then
    text = " " .. text .. " "
  end
  return ui.text(text, style)
end

---@param value any
---@return table|false
local function configured_topbar_bar_opts(value)
  if value == false then
    return false
  end
  return type(value) == "table" and value or {}
end

---@return HollowUiWidget|nil
local function configured_topbar_widget()
  local opts = optional_table(state.ui.configured_topbar)
  if opts == nil then
    return nil
  end

  return ui.new_widget("topbar", {
    height = tonumber(opts.height) or resolved_topbar_theme().height,
    style = merge_tables({ bg = resolved_topbar_theme().background }, opts.style),
    layout = type(opts.layout) == "table" and opts.layout or DEFAULT_TOPBAR_LAYOUT,
    render = function(ctx)
      local items = {}
      local workspace = configured_topbar_bar_opts(opts.workspace)
      local tabs = configured_topbar_bar_opts(opts.tabs)
      local separator = configured_topbar_separator(opts.separator)

      if workspace ~= false then
        items[#items + 1] = ui.bar.workspace(workspace)
      end
      if separator ~= nil and workspace ~= false and tabs ~= false then
        items[#items + 1] = separator
      end
      if tabs ~= false then
        items[#items + 1] = ui.bar.tabs(tabs)
      end

      local right_items = {}
      local cwd = configured_topbar_cwd(ctx, opts.cwd)
      if cwd ~= nil then
        right_items[#right_items + 1] = cwd
      end

      local key_legend = configured_topbar_bar_opts(opts.key_legend)
      if key_legend ~= false then
        right_items[#right_items + 1] = ui.bar.key_legend(key_legend)
      end

      if opts.time ~= false then
        local time_format = "%H:%M"
        local time_opts = nil
        if type(opts.time) == "string" then
          time_format = opts.time
        elseif type(opts.time) == "table" then
          time_format = opts.time.format or time_format
          if opts.time.style ~= nil then
            time_opts = { style = opts.time.style }
          end
        end
        right_items[#right_items + 1] = ui.bar.time(time_format, time_opts)
      end

      if #right_items > 0 then
        items[#items + 1] = ui.spacer()
        for _, item in ipairs(right_items) do
          items[#items + 1] = item
        end
      end

      return items
    end,
  })
end

local function leader_state()
  local value = hollow.keymap.get_leader_state()
  if type(value) == "table" and value.active then
    return value
  end
  return nil
end

local function copy_mode_state()
  local value = state.copy_mode
  if type(value) == "table" and value.active == true then
    return value
  end
  return nil
end

local function special_mode_theme()
  local resolved = shared.resolve_theme().ui
  local all = resolved.widgets.all
  local util = hollow.util
  local base_bg = shared.normalize_hex_color(all.panel_bg, resolved.top_bar.background)
  local mode_copy_bg = shared.normalize_hex_color(util.brighten_hex_color(base_bg, 0.08, base_bg), base_bg)
  local mode_leader_bg = shared.normalize_hex_color(util.darken_hex_color(base_bg, 0.04, base_bg), base_bg)
  local hint_key_bg = shared.normalize_hex_color(util.brighten_hex_color(base_bg, 0.14, base_bg), base_bg)
  return {
    bg = shared.normalize_hex_color(resolved.status and resolved.status.bg, resolved.top_bar.background),
    fg = shared.normalize_hex_color(resolved.status and resolved.status.fg, all.title),
    chip_bg = base_bg,
    chip_fg = shared.normalize_hex_color(all.fg, resolved.status and resolved.status.fg),
    accent = shared.normalize_hex_color(resolved.accent, all.title),
    muted = shared.normalize_hex_color(all.muted, all.fg),
    divider = shared.normalize_hex_color(all.divider, resolved.status and resolved.status.fg),
    counter = shared.normalize_hex_color(all.counter, all.muted),
    copy_bg = mode_copy_bg,
    leader_bg = mode_leader_bg,
    hint_key_bg = hint_key_bg,
  }
end

local function special_mode_chip(text, style)
  return ui.span(text, merge_tables({
    bold = true,
    radius = 4,
    padding = { left = 2, right = 2, top = 1, bottom = 1 },
    margin = { right = 1 },
  }, style))
end

local function special_mode_key(text, style)
  return ui.span(text, merge_tables({
    bold = true,
    radius = 4,
    padding = { left = 1, right = 1, top = 0, bottom = 0 },
  }, style))
end

local function special_mode_hint(key, label, theme)
  return {
    special_mode_key(key, {
      fg = theme.fg,
      bg = theme.hint_key_bg,
    }),
    ui.span(" " .. label .. " ", {
      fg = theme.muted,
    }),
  }
end

local function flatten_nodes(items)
  local out = {}
  for _, item in ipairs(items or {}) do
    if type(item) == "table" and item[1] ~= nil and item._type == nil then
      for _, nested in ipairs(item) do
        out[#out + 1] = nested
      end
    else
      out[#out + 1] = item
    end
  end
  return out
end

local function copy_mode_search_chip(copy_mode, theme)
  local pieces = {
    special_mode_key("/", {
      fg = theme.fg,
      bg = theme.hint_key_bg,
    }),
  }

  local query = copy_mode.query ~= "" and copy_mode.query or "search"
  pieces[#pieces + 1] = ui.span(query, {
    fg = theme.chip_fg,
  })

  if copy_mode.match_count > 0 then
    pieces[#pieces + 1] = ui.span(string.format("  %d/%d", copy_mode.match_index or 0, copy_mode.match_count), {
      fg = theme.counter,
    })
  elseif copy_mode.query ~= "" then
    pieces[#pieces + 1] = ui.span("  0/0", {
      fg = theme.counter,
    })
  end

  if copy_mode.selecting then
    pieces[#pieces + 1] = ui.span(copy_mode.block and "  BLK" or "  SEL", {
      fg = theme.accent,
      bold = true,
    })
  end

  pieces[#pieces + 1] = ui.span(" ")
  return ui.group(flatten_nodes(pieces), {
    bg = theme.copy_bg,
    radius = 4,
    padding = { left = 2, right = 2, top = 1, bottom = 1 },
    margin = { right = 1 },
  })
end

local function special_mode_legend(copy_mode, theme)
  local leader = copy_mode == nil and leader_state() or nil
  local hints = copy_mode ~= nil and {
    special_mode_hint("h/j/k/l", "move", theme),
    special_mode_hint("gg/G", "ends", theme),
    special_mode_hint("v", "sel", theme),
    special_mode_hint("C-v", "blk", theme),
    special_mode_hint("n/N", "match", theme),
    special_mode_hint("y", "copy", theme),
    special_mode_hint("q", "exit", theme),
  } or (leader ~= nil and leader.next_display and #leader.next_display > 0) and (function()
    local leader_hints = {}
    for _, item in ipairs(leader.next_display) do
      local key, label = item:match("^([^:]+):(.+)$")
      leader_hints[#leader_hints + 1] = special_mode_hint(key or item, label or "", theme)
    end
    return leader_hints
  end)() or {}

  return ui.bar.custom({
    id = copy_mode ~= nil and "mode:copy-legend" or "mode:leader-legend",
    cache_ttl_ms = leader ~= nil and math.max(1, tonumber(leader.remaining_ms) or 0) or nil,
    render = function()
      return flatten_nodes(hints)
    end,
  })
end

local function configured_bottombar_widget()
  local theme = special_mode_theme()
  return ui.new_widget("bottombar", {
    height = resolved_topbar_theme().height,
    style = { bg = theme.chip_bg },
    layout = {
      padding = { left = 1, right = 1, top = 0, bottom = 0 },
    },
    render = function()
      local copy_mode = copy_mode_state()
      local leader = copy_mode == nil and leader_state() or nil
      if copy_mode == nil and leader == nil then
        return {}
      end

      local items = {}
      if copy_mode ~= nil then
        items[#items + 1] = ui.bar.custom({
          id = "mode:copy",
          render = function()
            return special_mode_chip(" COPY ", {
              bg = theme.copy_bg,
              fg = theme.accent,
            })
          end,
        })

        items[#items + 1] = ui.bar.custom({
          id = "mode:search",
          render = function()
            return copy_mode_search_chip(copy_mode, theme)
          end,
        })
      elseif leader ~= nil then
        items[#items + 1] = ui.bar.custom({
          id = "mode:leader",
          render = function()
            return special_mode_chip(" LEADER ", {
              bg = theme.leader_bg,
              fg = theme.fg,
            })
          end,
        })
      end

      items[#items + 1] = ui.spacer()
      items[#items + 1] = special_mode_legend(copy_mode, theme)
      return items
    end,
  })
end

local function visible_bar_item_count(items)
  local count = 0
  for _, item in ipairs(items or {}) do
    if type(item) == "table" and item.kind ~= "spacer" then
      count = count + 1
    end
  end
  return count
end

local function sync_topbar_config(opts)
  local topbar_theme = resolved_topbar_theme()
  local style = merge_tables({ bg = topbar_theme.background }, opts.style)
  local config_opts = {
    top_bar_height = tonumber(opts.height) or topbar_theme.height,
  }

  if style.bg ~= nil then
    config_opts.top_bar_bg = style.bg
  end

  hollow.config.set(config_opts)
end

local function cache_state_key(surface)
  if surface == "topbar" then
    return "topbar_cache_state"
  end
  if surface == "bottombar" then
    return "bottombar_cache_state"
  end
  return nil
end

local function cache_layout_key(surface)
  if surface == "topbar" then
    return "topbar_cache_layout"
  end
  if surface == "bottombar" then
    return "bottombar_cache_layout"
  end
  return nil
end

local function cache_dirty_key(surface)
  if surface == "topbar" then
    return "topbar_cache_dirty"
  end
  if surface == "bottombar" then
    return "bottombar_cache_dirty"
  end
  return nil
end

local function cache_expires_key(surface)
  if surface == "topbar" then
    return "topbar_cache_expires_at"
  end
  if surface == "bottombar" then
    return "bottombar_cache_expires_at"
  end
  return nil
end

local function invalidate_bar_cache(surface)
  local dirty_key = cache_dirty_key(surface)
  local state_key = cache_state_key(surface)
  local layout_key = cache_layout_key(surface)
  local expires_key = cache_expires_key(surface)
  if dirty_key == nil then
    return false
  end

  local visible = state_key ~= nil and state.ui[state_key] ~= nil
  state.ui[dirty_key] = true
  ui[dirty_key] = true
  if state_key ~= nil then
    state.ui[state_key] = nil
    ui[state_key] = nil
  end
  if layout_key ~= nil then
    state.ui[layout_key] = nil
    ui[layout_key] = nil
  end
  if expires_key ~= nil then
    state.ui[expires_key] = nil
    ui[expires_key] = nil
  end
  if type(state.host_api) == "table" and type(state.host_api.set_bar_cache_state) == "function" then
    state.host_api.set_bar_cache_state(surface, true, 0, visible)
  end
  return true
end

local function current_time_ms()
  return util.host_now_ms(state.host_api)
end

local function cache_is_valid(surface)
  local dirty_key = cache_dirty_key(surface)
  local state_key = cache_state_key(surface)
  local layout_key = cache_layout_key(surface)
  local expires_key = cache_expires_key(surface)
  if dirty_key == nil or state_key == nil or layout_key == nil or expires_key == nil then
    return false
  end
  if state.ui[dirty_key] then
    return false
  end
  if state.ui[state_key] == nil or state.ui[layout_key] == nil then
    return false
  end

  local expires_at = state.ui[expires_key]
  return expires_at == BAR_CACHE_NO_EXPIRY
    or (type(expires_at) == "number" and expires_at > current_time_ms())
end

local function set_bar_cache(surface, payload, layout, expires_at)
  local dirty_key = cache_dirty_key(surface)
  local state_key = cache_state_key(surface)
  local layout_key = cache_layout_key(surface)
  local expires_key = cache_expires_key(surface)
  if dirty_key == nil or state_key == nil or layout_key == nil or expires_key == nil then
    return payload
  end

  state.ui[state_key] = payload
  state.ui[layout_key] = layout
  state.ui[expires_key] = expires_at == nil and BAR_CACHE_NO_EXPIRY or expires_at
  state.ui[dirty_key] = false
  ui[state_key] = payload
  ui[layout_key] = layout
  ui[expires_key] = expires_at == nil and BAR_CACHE_NO_EXPIRY or expires_at
  ui[dirty_key] = false
  if type(state.host_api) == "table" and type(state.host_api.set_bar_cache_state) == "function" then
    state.host_api.set_bar_cache_state(
      surface,
      false,
      type(expires_at) == "number" and math.floor(expires_at) or 0,
      payload ~= nil
    )
  end
  return payload
end

local function set_bar_layout_cache(surface, layout)
  local layout_key = cache_layout_key(surface)
  local dirty_key = cache_dirty_key(surface)
  local state_key = cache_state_key(surface)
  if layout_key == nil or dirty_key == nil then
    return layout
  end

  state.ui[layout_key] = layout
  ui[layout_key] = layout
  if state_key ~= nil and state.ui[state_key] ~= nil then
    state.ui[dirty_key] = false
    ui[dirty_key] = false
    if
      type(state.host_api) == "table" and type(state.host_api.set_bar_cache_state) == "function"
    then
      local expires_key = cache_expires_key(surface)
      local expires_at = expires_key ~= nil and state.ui[expires_key] or nil
        state.host_api.set_bar_cache_state(
          surface,
          false,
          type(expires_at) == "number" and math.floor(expires_at) or 0,
          state.ui[state_key] ~= nil
        )
      end
    end
  return layout
end

local function bar_cache_payload(surface)
  local state_key = cache_state_key(surface)
  return state_key ~= nil and state.ui[state_key] or nil
end

local function bar_cache_layout(surface)
  local layout_key = cache_layout_key(surface)
  return layout_key ~= nil and state.ui[layout_key] or nil
end

local function min_expiry(current, candidate)
  if candidate == nil then
    return current
  end
  if current == nil or candidate < current then
    return candidate
  end
  return current
end

local BAR_EVENT_FIELDS = {
  "on_click",
  "on_mouse_enter",
  "on_mouse_leave",
}

---@param surface string
---@return string|nil
local function hovered_bar_id_key(surface)
  if surface == "topbar" then
    return "topbar_hovered_id"
  end
  if surface == "bottombar" then
    return "bottombar_hovered_id"
  end
  return nil
end

---@param surface string|nil
---@param style any
---@return boolean
local function is_hovered_bar_style(surface, style)
  if surface ~= "topbar" and surface ~= "bottombar" then
    return false
  end
  if type(style) ~= "table" or type(style.id) ~= "string" or style.id == "" then
    return false
  end

  local hovered_key = hovered_bar_id_key(surface)
  return hovered_key ~= nil and state.ui[hovered_key] == style.id
end

---@param surface string|nil
---@param style any
---@return any
local function resolve_bar_hover_style(surface, style)
  if type(style) ~= "table" then
    return style
  end

  if not is_hovered_bar_style(surface, style) then
    return style
  end

  local hover = type(style.hover) == "table" and style.hover or nil
  if hover == nil then
    return style
  end

  return shared.merge_style_tables(style, hover)
end

---@param surface string|nil
---@param value any
---@return any
local function resolve_bar_hover_value(surface, value)
  if type(value) ~= "table" then
    return value
  end

  local resolved = hollow.util.clone_value(value)
  if type(resolved.style) == "table" then
    resolved.style = resolve_bar_hover_style(surface, resolved.style)
  end

  if resolved._type == nil then
    for index, item in ipairs(resolved) do
      resolved[index] = resolve_bar_hover_value(surface, item)
    end
  elseif resolved._type == "group" and type(resolved.children) == "table" then
    for index, child in ipairs(resolved.children) do
      resolved.children[index] = resolve_bar_hover_value(surface, child)
    end
  end

  return resolved
end

---@param value any
---@param fallback integer
---@return integer
local function normalize_px(value, fallback)
  local number = tonumber(value)
  if number == nil then
    return fallback
  end

  number = math.floor(number)
  if number < 0 then
    return 0
  end
  return number
end

---@param value any
---@return {top:integer,right:integer,bottom:integer,left:integer}
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

---@param style any
---@return table|nil
local function serialize_bar_style(style)
  style = type(style) == "table" and style or nil
  if style == nil then
    return nil
  end

  local bg = shared.normalize_hex_color(style.bg, nil)
  local fg = shared.normalize_hex_color(style.fg, nil)
  local border = shared.normalize_hex_color(style.border, nil)
  local close_bg = shared.normalize_hex_color(style.close_bg, nil)
  local close_fg = shared.normalize_hex_color(style.close_fg, nil)
  local close_hover_bg = shared.normalize_hex_color(style.close_hover_bg, nil)
  local close_hover_fg = shared.normalize_hex_color(style.close_hover_fg, nil)
  local radius = normalize_px(style.radius, 0)
  local close_radius = normalize_px(style.close_radius, 0)
  local padding = normalize_box(style.padding)
  local margin = normalize_box(style.margin)
  local serialized = {}

  if bg ~= nil then
    serialized.bg = bg
  end
  if fg ~= nil then
    serialized.fg = fg
  end
  if border ~= nil then
    serialized.border = border
  end
  if close_bg ~= nil then
    serialized.close_bg = close_bg
  end
  if close_fg ~= nil then
    serialized.close_fg = close_fg
  end
  if close_hover_bg ~= nil then
    serialized.close_hover_bg = close_hover_bg
  end
  if close_hover_fg ~= nil then
    serialized.close_hover_fg = close_hover_fg
  end
  if radius > 0 then
    serialized.radius = radius
  end
  if close_radius > 0 then
    serialized.close_radius = close_radius
  end
  if style.bold == true then
    serialized.bold = true
  end
  if type(style.id) == "string" and style.id ~= "" then
    serialized.id = style.id
  end
  if padding.top > 0 or padding.right > 0 or padding.bottom > 0 or padding.left > 0 then
    serialized.padding = padding
  end
  if margin.top > 0 or margin.right > 0 or margin.bottom > 0 or margin.left > 0 then
    serialized.margin = margin
  end

  return next(serialized) ~= nil and serialized or nil
end

---@param style any
---@return table|nil
local function serialize_bar_text_style(style)
  style = type(style) == "table" and style or nil
  if style == nil then
    return nil
  end

  local serialized = {}
  local fg = shared.normalize_hex_color(style.fg, nil)
  local bg = shared.normalize_hex_color(style.bg, nil)
  if fg ~= nil then
    serialized.fg = fg
  end
  if bg ~= nil then
    serialized.bg = bg
  end
  if style.bold == true then
    serialized.bold = true
  end
  if type(style.id) == "string" and style.id ~= "" then
    serialized.id = style.id
  end

  return next(serialized) ~= nil and serialized or nil
end

---@param surface string|nil
---@param value any
---@param fallback_text string
---@param style any
---@return HollowUiSegment
local function serialize_bar_value(surface, value, fallback_text, style)
  value = resolve_bar_hover_value(surface, value)
  local resolved_style = resolve_bar_hover_style(surface, style)
  local merged_style = resolved_style
  local text_style = serialize_bar_text_style(resolved_style)
  if type(value) == "table" and type(value.style) == "table" then
    merged_style =
      shared.merge_style_tables(resolved_style, resolve_bar_hover_style(surface, value.style))
  end

  local segments = shared.bar_value_to_segments(value, fallback_text, text_style)
  local segment = shared.style_to_segment(shared.segments_plain_text(segments), merged_style)
  segment.segments = segments
  segment.style = serialize_bar_style(merged_style)
  return segment
end

---@param widget HollowUiWidget
---@return table
local function serialize_bar_layout(widget)
  local layout = type(widget.layout) == "table" and widget.layout or {}
  return {
    padding = normalize_box(layout.padding),
    margin = normalize_box(layout.margin),
  }
end

---@param widget HollowUiWidget
---@return {height:integer,padding:{top:integer,right:integer,bottom:integer,left:integer},margin:{top:integer,right:integer,bottom:integer,left:integer}}
local function serialize_bar_surface_layout(widget)
  local layout = serialize_bar_layout(widget)
  return {
    height = math.max(0, math.floor(tonumber(widget.height) or 0)),
    padding = layout.padding,
    margin = layout.margin,
  }
end

---@param widget HollowUiWidget
---@return table|nil
local function serialize_bar_widget_style(widget)
  local style = serialize_bar_style(widget.style)
  if type(style) ~= "table" then
    return nil
  end

  style.padding = nil
  style.margin = nil
  return next(style) ~= nil and style or nil
end

---@param text string
---@param width integer
---@return string
local function truncate_text_end(text, width)
  text = tostring(text or "")
  if width <= 0 then
    return ""
  end
  if util.utf8_len(text) <= width then
    return text
  end

  if utf8 and type(utf8.offset) == "function" then
    if width <= 3 then
      local byte_end = utf8.offset(text, width + 1)
      return byte_end and text:sub(1, byte_end - 1) or text
    end

    local byte_end = utf8.offset(text, width - 3 + 1)
    local prefix = byte_end and text:sub(1, byte_end - 1) or text
    return prefix .. "..."
  end

  return util.truncate_end(text, width)
end

---@param segments HollowUiSegment[]|nil
---@param width integer
---@return HollowUiSegment[]|nil
local function truncate_segments_end(segments, width)
  if type(segments) ~= "table" or width <= 0 then
    return nil
  end

  local out = {}
  local remaining = width
  for _, segment in ipairs(segments) do
    if remaining <= 0 then
      break
    end

    local text = tostring(segment.text or "")
    local seg_len = util.utf8_len(text)
    if seg_len == 0 then
      goto continue
    end

    local clipped = truncate_text_end(text, remaining)
    if clipped ~= "" then
      local copy = util.clone_value(segment)
      copy.text = clipped
      out[#out + 1] = copy
      remaining = remaining - util.utf8_len(clipped)
    end

    if util.utf8_len(clipped) < seg_len then
      break
    end

    ::continue::
  end

  return #out > 0 and out or nil
end

---@param segment HollowUiSegment
---@param width integer
---@return HollowUiSegment
local function clamp_tab_segment_width(segment, width)
  if type(segment) ~= "table" or width <= 0 then
    return segment
  end

  local text = truncate_text_end(segment.text or "", width)
  if text == segment.text then
    return segment
  end

  local clamped = util.clone_value(segment)
  clamped.text = text
  clamped.segments = truncate_segments_end(segment.segments, width)
  return clamped
end

---@param surface string|nil
---@param node HollowUiBarTabsNode
---@param ctx HollowWidgetCtx
---@param handlers table<string, table<string, function>>
---@return HollowUiTabsLayout
local function serialize_tabs(surface, node, ctx, handlers)
  local tabs_list = ctx.term.tabs or {}
  if #tabs_list <= 1 and hollow.config.get("top_bar_mode") ~= "always" then
    return nil
  end
  local tabs = {}

  for _, tab in ipairs(tabs_list) do
    local tab_state = {
      id = tab.id,
      title = tab.title ~= "" and tab.title,
      index = tab.index,
      is_active = tab.is_active == true,
      is_hovered = false,
      pane = tab.pane,
      panes = tab.panes or {},
    }

    local style = node.style
    if type(style) == "function" then
      local ok, result = pcall(style, tab_state, ctx)
      style = ok and result or nil
    end
    style = resolve_bar_hover_style(surface, style)

    local label = tab_state.title
    if type(node.format) == "function" then
      local ok, result = pcall(node.format, tab_state, ctx)
      if ok then
        label = result
      end
    end

    if type(label) == "table" then
      for _, formatted_node in
        ipairs(shared.flatten_span_nodes(shared.normalize_inline_nodes(label)))
      do
        local formatted_style = formatted_node.style
        if
          type(formatted_style) == "table"
          and type(formatted_style.id) == "string"
          and formatted_style.id ~= ""
        then
          local entry = handlers[formatted_style.id] or {}
          for _, field in ipairs(BAR_EVENT_FIELDS) do
            if type(formatted_style[field]) == "function" then
              entry[field] = formatted_style[field]
            end
          end
          handlers[formatted_style.id] = entry
        end
      end
    end

    local segment = serialize_bar_value(surface, label, tab_state.title, style)
    if type(node.max_width) == "number" and node.max_width > 0 then
      segment = clamp_tab_segment_width(segment, math.floor(node.max_width))
    end
    tabs[#tabs + 1] = segment
  end

  return {
    kind = "tabs",
    fit = node.fit == "content" and "content" or "fill",
    max_width = type(node.max_width) == "number" and node.max_width or nil,
    style = serialize_bar_style(resolve_bar_hover_style(surface, node.style)),
    tabs = tabs,
  }
end

---@param surface string|nil
---@param node HollowUiBarWorkspaceNode
---@param ctx HollowWidgetCtx
---@return HollowUiSegment
local function serialize_workspace(surface, node, ctx)
  local workspace = ctx.term.workspace
  local workspace_state = {
    index = workspace and workspace.index or 1,
    name = workspace and workspace.name or "ws",
    is_active = true,
    active_index = workspace and workspace.index or 1,
    count = #ctx.term.workspaces,
  }

  local text = workspace_state.name
  if type(node.format) == "function" then
    local ok, result = pcall(node.format, workspace_state, ctx)
    if ok then
      text = result
    end
  end

  local style = node.style
  if type(style) == "function" then
    local ok, result = pcall(style, workspace_state, ctx)
    style = ok and result or nil
  end
  style = resolve_bar_hover_style(surface, style)

  local segment = serialize_bar_value(surface, text, workspace_state.name, style)
  segment.kind = "segment"
  return segment
end

---@param surface string|nil
---@param node HollowUiBarTimeNode
---@return HollowUiSegment
local function serialize_time(surface, node)
  local style = resolve_bar_hover_style(surface, node.style)
  local segment = shared.style_to_segment(os.date(node.format or "%H:%M"), style)
  segment.kind = "segment"
  segment.style = serialize_bar_style(style)
  local next_tick_ms = (math.floor(current_time_ms() / 1000) + 1) * 1000
  return segment, next_tick_ms
end

---@param surface string|nil
---@param node HollowUiBarKeyLegendNode
---@return HollowUiSegment
local function serialize_key_legend(surface, node)
  local copy_mode = copy_mode_state()
  if copy_mode ~= nil then
    return nil, nil
  end

  ---@type HollowLeaderState|nil
  local leader_state = leader_state()
  local text = ""
  if
    leader_state
    and leader_state.active
    and leader_state.next_display
    and #leader_state.next_display > 0
  then
    text = " " .. table.concat(leader_state.next_display, "  ") .. " "
  end

  local style = resolve_bar_hover_style(surface, node.style)
  local segment = shared.style_to_segment(text, style)
  segment.kind = "segment"
  segment.style = serialize_bar_style(style)
  local expires_at = leader_state
      and leader_state.active
      and (current_time_ms() + math.max(1, tonumber(leader_state.remaining_ms) or 0))
    or nil
  return segment, expires_at
end

---@param surface string|nil
---@param node HollowUiBarCustomNode
---@param ctx HollowWidgetCtx
---@return HollowUiSegment|nil
local function serialize_custom(surface, node, ctx)
  local ok, rendered = pcall(node.render, ctx)
  if not ok then
    return nil
  end

  local segment
  if type(rendered) == "string" or type(rendered) == "table" then
    segment = serialize_bar_value(surface, rendered, "", node.style)
    segment.kind = "segment"
    segment.id = segment.id or node.id
  end

  local expires_at = type(node.cache_ttl_ms) == "number"
      and current_time_ms() + math.max(1, math.floor(node.cache_ttl_ms))
    or nil
  return segment, expires_at
end

---@alias HollowUiBarSerializableNode
---| HollowUiRenderableNode
---| HollowUiBarTabsNode
---| HollowUiBarWorkspaceNode
---| HollowUiBarTimeNode
---| HollowUiBarKeyLegendNode
---| HollowUiBarCustomNode

---@param surface string|nil
---@param node HollowUiBarSerializableNode|nil
---@param ctx HollowWidgetCtx
---@param handlers table<string, table<string, function>>
---@return HollowUiSegment|HollowUiTabsLayout|{kind:"spacer"}|nil
local function serialize_bar_item(surface, node, ctx, handlers)
  if type(node) ~= "table" then
    return nil
  end

  if node._type == "bar_tabs" then
    return serialize_tabs(surface, node, ctx, handlers), nil
  end
  if node._type == "bar_workspace" then
    return serialize_workspace(surface, node, ctx), nil
  end
  if node._type == "bar_time" then
    return serialize_time(surface, node)
  end
  if node._type == "bar_key_legend" then
    return serialize_key_legend(surface, node)
  end
  if node._type == "bar_custom" then
    return serialize_custom(surface, node, ctx)
  end
  if node._type == "spacer" then
    return { kind = "spacer" }, nil
  end
  if shared.is_span_node(node) then
    local segment = serialize_bar_value(surface, node, node.text or node.name or "", node.style)
    segment.kind = "segment"
    return segment, nil
  end

  return nil, nil
end

---@param widget HollowUiWidget|nil
---@param surface string|nil
---@return {items:(HollowUiSegment|HollowUiTabsLayout|{kind:"spacer"})[],layout:table,style:table|nil}|nil
local function serialize_bar_widget(widget, surface)
  if widget == nil then
    return nil
  end

  if cache_is_valid(surface) then
    return bar_cache_payload(surface)
  end

  local ctx = shared.widget_ctx()
  local items = shared.normalize_bar_items(shared.render_widget(widget))
  local serialized = {}
  local handlers = {}
  local expires_at = nil
  local layout = serialize_bar_layout(widget)
  local surface_layout = serialize_bar_surface_layout(widget)

  for _, item in ipairs(items) do
    local ok, value, item_expires_at = pcall(serialize_bar_item, surface, item, ctx, handlers)
    if ok and value ~= nil then
      serialized[#serialized + 1] = value
      expires_at = min_expiry(expires_at, item_expires_at)
    end
  end

  local visible_items = visible_bar_item_count(serialized)

  if surface == "topbar" then
    state.ui.topbar_handlers = handlers
  elseif surface == "bottombar" then
    state.ui.bottombar_handlers = handlers
  end

  if visible_items == 0 then
    return set_bar_cache(surface, nil, nil, expires_at)
  end

  return set_bar_cache(surface, {
    items = serialized,
    layout = layout,
    style = serialize_bar_widget_style(widget),
  }, surface_layout, expires_at)
end

---@param surface string
---@return HollowUiWidget|nil
local function mounted_bar_widget(surface)
  if surface == "topbar" then
    return state.ui.mounted_topbar
  end
  if surface == "bottombar" then
    return state.ui.mounted_bottombar
  end
  return nil
end

---@param surface string
---@return HollowUiWidget|nil
local function configured_bar_widget(surface)
  if surface == "topbar" then
    return configured_topbar_widget()
  end
  if surface == "bottombar" then
    return configured_bottombar_widget()
  end
  return nil
end

---@param surface string
---@return HollowUiWidget|nil
local function active_bar_widget(surface)
  return mounted_bar_widget(surface) or configured_bar_widget(surface)
end

---@param surface string
---@param payload any
---@return string|nil
local function bar_payload_node_id(surface, payload)
  if type(payload) ~= "table" then
    return nil
  end

  if type(payload.id) == "string" and payload.id ~= "" then
    return payload.id
  end

  local key = surface == "topbar" and "topbar_node"
    or surface == "bottombar" and "bottombar_node"
    or nil
  local node = key ~= nil and payload[key] or nil
  if type(node) == "table" and type(node.id) == "string" and node.id ~= "" then
    return node.id
  end

  return nil
end

---@param node HollowUiRenderableNode|HollowUiBarCustomNode
---@param node_id string
---@param field "on_click"|"on_mouse_enter"|"on_mouse_leave"
---@param payload HollowUiBarNodePayload
---@return boolean
local function visit_bar_nodes(node, node_id, field, payload)
  if type(node) ~= "table" then
    return false
  end

  if node._type == "group" then
    for _, child in ipairs(node.children or {}) do
      if visit_bar_nodes(child, node_id, field, payload) then
        return true
      end
    end
    return false
  end

  if node._type == "bar_custom" and type(node.id) == "string" and node.id == node_id then
    if type(node[field]) == "function" then
      node[field](payload)
      return true
    end
    return false
  end

  local style = node.style
  if type(style) == "table" and style.id == node_id and type(style[field]) == "function" then
    style[field](payload)
    return true
  end

  return false
end

---@param surface string
---@param node_id string
---@param field "on_click"|"on_mouse_enter"|"on_mouse_leave"
---@param payload HollowUiBarNodePayload
---@return boolean
local function call_bar_node_handler(surface, node_id, field, payload)
  local handler_map = surface == "topbar" and state.ui.topbar_handlers
    or state.ui.bottombar_handlers
  if type(handler_map) == "table" then
    local entry = handler_map[node_id]
    if type(entry) == "table" and type(entry[field]) == "function" then
      entry[field](payload)
      return true
    end
  end

  local widget = active_bar_widget(surface)
  if widget == nil or type(node_id) ~= "string" or node_id == "" then
    return false
  end

  local rendered = shared.normalize_bar_items(shared.render_widget(widget))
  for _, node in ipairs(rendered) do
    if visit_bar_nodes(node, node_id, field, payload) then
      return true
    end
  end

  return false
end

---@param namespace table<string, fun(...):any>
---@param kind string
---@param state_key string
---@param visibility_key string|nil
local function define_mount_api(namespace, kind, state_key, visibility_key)
  function namespace.new(opts)
    return ui.new_widget(kind, opts)
  end

  function namespace.mount(widget)
    widget_core.unmount_widget(state.ui[state_key])
    state.ui[state_key] = widget
    if visibility_key ~= nil then
      state.ui[visibility_key] = widget.hidden ~= true
    end
    widget_core.mount_widget(widget)
    invalidate_bar_cache(kind)
  end

  function namespace.unmount()
    widget_core.unmount_widget(state.ui[state_key])
    state.ui[state_key] = nil
    if visibility_key ~= nil then
      state.ui[visibility_key] = false
    end
    invalidate_bar_cache(kind)
  end

  function namespace.invalidate()
    if active_bar_widget(kind) == nil then
      return false
    end

    invalidate_bar_cache(kind)
    return true
  end
end

ui.topbar = ui.topbar or {}
ui.bottombar = ui.bottombar or {}
ui.sidebar = ui.sidebar or {}

define_mount_api(ui.topbar, "topbar", "mounted_topbar", nil)
define_mount_api(ui.bottombar, "bottombar", "mounted_bottombar", nil)
define_mount_api(ui.sidebar, "sidebar", "mounted_sidebar", "sidebar_visible")

function ui.sidebar.toggle()
  if state.ui.mounted_sidebar == nil then
    return false
  end

  state.ui.sidebar_visible = not state.ui.sidebar_visible
  return state.ui.sidebar_visible
end

---@param kind string
---@param payload HollowUiBarNodePayload|any
function ui.handle_bar_node_event(kind, payload)
  local surface = kind:match("^(%a+bar):")
  if surface ~= "topbar" and surface ~= "bottombar" then
    return
  end

  local hovered_key = hovered_bar_id_key(surface)
  if hovered_key == nil then
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
      invalidate_bar_cache(surface)
    end
    return
  end

  local node_id = bar_payload_node_id(surface, payload)
  if node_id == nil then
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
      invalidate_bar_cache(surface)
    end
    return
  end

  if kind == surface .. ":click" then
    call_bar_node_handler(surface, node_id, "on_click", payload)
  end
end

function ui._topbar_state()
  local widget = active_bar_widget("topbar")
  if widget == nil then
    if
      type(state.host_api) == "table" and type(state.host_api.set_bar_cache_state) == "function"
    then
      state.host_api.set_bar_cache_state("topbar", false, 0, false)
    end
    return nil
  end
  return serialize_bar_widget(widget, "topbar")
end

function ui._bottombar_state()
  local widget = active_bar_widget("bottombar")
  if widget == nil then
    if
      type(state.host_api) == "table" and type(state.host_api.set_bar_cache_state) == "function"
    then
      state.host_api.set_bar_cache_state("bottombar", false, 0, false)
    end
    return nil
  end
  return serialize_bar_widget(widget, "bottombar")
end

function ui._bottombar_layout()
  local widget = active_bar_widget("bottombar")
  if widget == nil then
    if
      type(state.host_api) == "table" and type(state.host_api.set_bar_cache_state) == "function"
    then
      state.host_api.set_bar_cache_state("bottombar", false, 0, false)
    end
    return nil
  end

  if cache_is_valid("bottombar") then
    return bar_cache_layout("bottombar")
  end

  local payload = serialize_bar_widget(widget, "bottombar")
  if payload == nil then
    return nil
  end

  return set_bar_layout_cache("bottombar", serialize_bar_surface_layout(widget))
end

function ui._topbar_layout()
  local widget = active_bar_widget("topbar")
  if widget == nil then
    if
      type(state.host_api) == "table" and type(state.host_api.set_bar_cache_state) == "function"
    then
      state.host_api.set_bar_cache_state("topbar", false, 0, false)
    end
    return nil
  end

  if cache_is_valid("topbar") then
    return bar_cache_layout("topbar")
  end

  local payload = serialize_bar_widget(widget, "topbar")
  if payload == nil then
    return nil
  end

  return set_bar_layout_cache("topbar", serialize_bar_surface_layout(widget))
end

function ui.topbar.configure(opts)
  opts = opts or {}
  local configured = clone_table(state.ui.configured_topbar)
  util.merge_tables(configured, opts)
  state.ui.configured_topbar = configured
  sync_topbar_config(configured)
  invalidate_bar_cache("topbar")
end

function ui._register_bar_invalidation_hooks()
  if state.ui._bar_invalidation_hooks_registered then
    return
  end

  state.ui._bar_invalidation_hooks_registered = true
  hollow.events.on("config:reloaded", function()
    ui.topbar.invalidate()
    ui.bottombar.invalidate()
  end)

  for _, event_name in ipairs({
    "copy_mode:changed",
    "term:tab_activated",
    "term:tab_closed",
    "term:pane_focused",
    "term:pane_layout_changed",
    "term:title_changed",
    "term:cwd_changed",
    "term:foreground_process_changed",
    "workspace:changed",
    "window:resized",
  }) do
    hollow.events.on(event_name, function()
      ui.topbar.invalidate()
      ui.bottombar.invalidate()
    end)
  end
end

function ui._sidebar_state()
  if state.ui.mounted_sidebar == nil or not state.ui.sidebar_visible then
    return nil
  end

  local rows = shared.render_widget_rows(state.ui.mounted_sidebar)
  local side = state.ui.mounted_sidebar.side == "right" and "right" or "left"
  local width = tonumber(state.ui.mounted_sidebar.width) or 24
  local segments = {}

  for index, row in ipairs(rows) do
    segments[index] = ui.trim_row_for_width(row, width)
  end

  return {
    side = side,
    width = math.max(1, math.floor(width)),
    reserve = state.ui.mounted_sidebar.reserve == true,
    rows = segments,
  }
end
