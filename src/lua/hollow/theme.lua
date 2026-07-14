local color = require("hollow.color")
local util = require("hollow.util")

local M = {}

local ANSI_COLOR_NAMES = {
  "black",
  "red",
  "green",
  "yellow",
  "blue",
  "magenta",
  "cyan",
  "white",
}

local BRIGHT_COLOR_NAMES = {
  "bright_black",
  "bright_red",
  "bright_green",
  "bright_yellow",
  "bright_blue",
  "bright_magenta",
  "bright_cyan",
  "bright_white",
}

local DEFAULT_WIDGET_THEME = {
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
  primary_bg = "#5e81ac",
  primary_fg = "#eceff4",
  destructive_bg = "#bf616a",
  destructive_fg = "#eceff4",
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

local hollow_theme = require("hollow.themes.hollow")
local DEFAULT_TERMINAL = hollow_theme.terminal
local DEFAULT_UI = hollow_theme.ui

---@param value any
---@param label string
---@return table
local function table_or_empty(value, label)
  if value == nil then
    return {}
  end
  if type(value) ~= "table" then
    error(label .. " must be a table")
  end
  return value
end

---@param value any
---@param fallback HollowColor|string
---@return HollowColor
local function color_or(value, fallback)
  return color.normalize_hex_color(value, fallback) --[[@as HollowColor]]
end

---@param values HollowColor[]|nil
---@param defaults HollowColor[]
---@return HollowColor[]
local function merge_color_list(values, defaults)
  local merged = {}
  values = table_or_empty(values, "theme colors")
  for index, fallback in ipairs(defaults) do
    merged[index] = color_or(values[index], fallback)
  end
  return merged
end

---@param spec HollowThemeTerminalSpec|nil
---@return HollowTerminalTheme
local function create_terminal(spec)
  local terminal = util.clone_value(DEFAULT_TERMINAL)
  util.merge_tables(terminal, util.clone_value(table_or_empty(spec, "theme.terminal")))

  terminal.foreground = color_or(terminal.foreground, DEFAULT_TERMINAL.foreground)
  terminal.background = color_or(terminal.background, DEFAULT_TERMINAL.background)
  terminal.cursor_bg = color_or(terminal.cursor_bg, terminal.foreground)
  terminal.cursor_fg = color_or(terminal.cursor_fg, terminal.background)
  terminal.selection_bg = color_or(terminal.selection_bg, terminal.background)
  terminal.selection_fg = color_or(terminal.selection_fg, terminal.foreground)
  terminal.ansi = merge_color_list(terminal.ansi, DEFAULT_TERMINAL.ansi)
  terminal.brights = merge_color_list(terminal.brights, DEFAULT_TERMINAL.brights)

  return terminal
end

---@param terminal HollowTerminalTheme
---@return HollowPalette
local function create_palette(terminal)
  local palette = {
    foreground = terminal.foreground,
    background = terminal.background,
    cursor_bg = terminal.cursor_bg,
    cursor_fg = terminal.cursor_fg,
    selection_bg = terminal.selection_bg,
    selection_fg = terminal.selection_fg,
  }

  for index, name in ipairs(ANSI_COLOR_NAMES) do
    palette[name] = terminal.ansi[index]
  end
  for index, name in ipairs(BRIGHT_COLOR_NAMES) do
    palette[name] = terminal.brights[index]
  end

  return palette
end

---@param spec HollowThemeUiSpec|nil
---@param palette HollowPalette
---@return HollowAppTheme
local function create_ui(spec, palette)
  local ui = util.clone_value(DEFAULT_UI)
  util.merge_tables(ui, util.clone_value(table_or_empty(spec, "theme.ui")))

  local widgets = ui.widgets
  local all = widgets.all
  all.title = color_or(all.title, palette.bright_blue)
  all.fg = color_or(all.fg, palette.foreground)
  all.input_bg = color_or(all.input_bg, palette.black)
  all.input_fg = color_or(all.input_fg, palette.foreground)
  all.cursor_bg = color_or(all.cursor_bg, palette.foreground)
  all.cursor_fg = color_or(all.cursor_fg, palette.background)
  all.divider = color_or(all.divider, palette.bright_black)

  widgets.input.backdrop = widgets.input.backdrop or { color = palette.black, alpha = 168 }

  local select = widgets.select
  local select_bg = color.brighten_hex_color(all.panel_bg, 0.4, all.panel_bg)
  select.selected_bg = color_or(select.selected_bg, select_bg)
  select.selected_detail_bg = color_or(select.selected_detail_bg, all.panel_bg)
  select.scrollbar_thumb = color_or(select.scrollbar_thumb, palette.bright_yellow)
  select.backdrop = select.backdrop or { color = palette.black, alpha = 168 }

  local levels = widgets.notify.notify_levels
  levels.info = color_or(levels.info, palette.bright_blue)
  levels.warn = color_or(levels.warn, palette.bright_yellow)
  levels.error = color_or(levels.error, palette.bright_red)
  levels.success = color_or(levels.success, palette.bright_green)

  local tab_bar = ui.tab_bar
  local bar_bg = color.darken_hex_color(palette.background, 0.1, palette.black)
  local active_bg = color.brighten_hex_color(palette.background, 0.06, palette.background)
  local hover_bg = color.brighten_hex_color(bar_bg, 0.12, active_bg)
  local inactive_fg = color.darken_hex_color(palette.foreground, 0.50, palette.foreground)

  tab_bar.background = color_or(tab_bar.background, bar_bg)
  tab_bar.active_tab.bg = color_or(tab_bar.active_tab.bg, active_bg)
  tab_bar.active_tab.fg = color_or(tab_bar.active_tab.fg, palette.bright_yellow)
  if tab_bar.active_tab.bold == nil then
    tab_bar.active_tab.bold = true
  end
  tab_bar.inactive_tab.bg = color_or(tab_bar.inactive_tab.bg, tab_bar.background)
  tab_bar.inactive_tab.fg = color_or(tab_bar.inactive_tab.fg, inactive_fg)
  tab_bar.hover_tab.bg = color_or(tab_bar.hover_tab.bg, hover_bg)
  tab_bar.hover_tab.fg = color_or(tab_bar.hover_tab.fg, palette.bright_white)

  all.panel_bg = color_or(all.panel_bg, tab_bar.background)

  ui.top_bar.height = math.max(0, math.floor(tonumber(ui.top_bar.height) or 22))
  ui.top_bar.background = color_or(ui.top_bar.background, tab_bar.background)

  local scrollbar = ui.scrollbar
  scrollbar.track = color_or(scrollbar.track, palette.black)
  scrollbar.thumb = color_or(scrollbar.thumb, palette.bright_black)
  scrollbar.thumb_hover = color_or(scrollbar.thumb_hover, palette.blue)
  scrollbar.thumb_active = color_or(scrollbar.thumb_active, palette.bright_blue)
  scrollbar.border = color_or(scrollbar.border, palette.background)

  ui.split_active = color_or(ui.split_active, palette.magenta)
  ui.split_inactive =
    color_or(ui.split_inactive, color.brighten_hex_color(palette.black, 0.08, palette.black))
  ui.floating_active = color_or(ui.floating_active, palette.magenta)
  ui.floating_inactive =
    color_or(ui.floating_inactive, color.brighten_hex_color(palette.black, 0.08, palette.black))
  ui.accent = color_or(ui.accent, palette.magenta)
  ui.warm = color_or(ui.warm, palette.bright_yellow)
  ui.status.bg = color_or(ui.status.bg, palette.black)
  ui.status.fg = color_or(ui.status.fg, palette.blue)

  return ui
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

---@param spec HollowThemeSpec|nil
---@return HollowResolvedTheme
function M.create(spec)
  spec = table_or_empty(spec, "theme")

  local terminal = create_terminal(spec.terminal)
  local palette = create_palette(terminal)
  if type(spec.palette) == "table" then
    util.merge_tables(palette, util.clone_value(spec.palette))
  end

  return {
    terminal = terminal,
    palette = palette,
    ui = create_ui(spec.ui, palette),
  }
end

---@param name string
---@return string[]
local function theme_module_candidates(name)
  return {
    "hollow.themes." .. name,
    "themes." .. name,
    name,
  }
end

---@param name string
---@return HollowResolvedTheme
function M.get(name)
  if type(name) ~= "string" or name == "" then
    error("hollow.theme.get(name) expects a non-empty string")
  end

  for _, module_name in ipairs(theme_module_candidates(name)) do
    local ok, value = pcall(require, module_name)
    if ok and type(value) == "table" then
      return M.create(value)
    end
  end

  error("theme not found: " .. name)
end

---@return HollowResolvedTheme
function M.current()
  local hollow = _G.hollow
  local config = type(hollow) == "table" and type(hollow.config) == "table" and hollow.config or nil
  if type(config) == "table" and type(config.get) == "function" then
    local resolved = config.get("resolved_theme")
    if type(resolved) == "table" then
      return resolved
    end

    local theme_value = config.get("theme")
    if type(theme_value) == "string" and theme_value ~= "" then
      return M.get(theme_value)
    end
    if type(theme_value) == "table" then
      return M.create({
        terminal = theme_value.terminal,
        ui = theme_value.ui,
        palette = theme_value.palette,
      })
    end
  end

  return M.create()
end

---@param kind string
---@param theme HollowResolvedTheme|nil
---@return HollowUiTheme
function M.resolve_widget(kind, theme)
  theme = type(theme) == "table" and theme or M.current()
  local ui = theme.ui
  local terminal = theme.terminal

  local ansi = table_field(terminal, "ansi")
  local brights = table_field(terminal, "brights")
  local status = table_field(ui, "status")
  local tab_bar = table_field(ui, "tab_bar")
  local workspace = table_field(ui, "workspace")
  local widgets = table_field(ui, "widgets")
  local workspace_active = table_field(workspace, "active")

  local accent = ui.accent or ansi[5]
  local warm = ui.warm or brights[4]
  local split = ui.split or status.fg
  local panel_bg = ui.widgets and ui.widgets.all and ui.widgets.all.panel_bg or terminal.background

  local resolved = {
    panel_bg = color_or(panel_bg, color.brighten_hex_color(terminal.background, 0.2, nil)),
    panel_border = color_or(accent, nil),
    divider = color_or(split, nil),
    title = color_or(accent, nil),
    fg = color_or(terminal.foreground, nil),
    muted = color_or(status.fg or brights[1], nil),
    input_bg = color_or(tab_bar.background or terminal.background, nil),
    input_fg = color_or(terminal.foreground, nil),
    cursor_bg = color_or(terminal.foreground, nil),
    cursor_fg = color_or(terminal.background, nil),
    selected_bg = color_or(widgets.selected_bg, color.brighten_hex_color(panel_bg, 0.1, nil)),
    selected_detail_bg = color_or(
      widgets.selected_bg,
      color.brighten_hex_color(panel_bg, 0.1, nil)
    ),
    selected_fg = color_or(terminal.foreground, nil),
    selection_bg = color_or(terminal.selection_bg, nil),
    selection_fg = color_or(terminal.selection_fg, nil),
    primary_bg = color_or(accent, nil),
    primary_fg = color_or(terminal.foreground, nil),
    destructive_bg = color_or(brights[2], nil),
    destructive_fg = color_or(terminal.foreground, nil),
    selected_muted = color_or(workspace_active.fg or terminal.foreground, nil),
    detail = color_or(status.fg, nil),
    notify_fg = color_or(terminal.foreground, nil),
    counter = color_or(status.fg, nil),
    empty = color_or(status.fg, nil),
    scrollbar_track = color_or(split, nil),
    scrollbar_thumb = color_or(accent, nil),
    notify_levels = {
      info = color_or(accent, nil),
      warn = color_or(warm, nil),
      error = color_or(brights[2] or ansi[2], nil),
      success = color_or(brights[3], nil),
    },
  }

  local widgets = table_field(ui, "widgets")
  local all_widgets = table_field(widgets, "all")
  local widget_theme = table_field(widgets, kind)
  util.merge_tables(resolved, util.clone_value(all_widgets))
  util.merge_tables(resolved, util.clone_value(widget_theme))

  local result = util.clone_value(DEFAULT_WIDGET_THEME)
  for key, value in pairs(resolved) do
    if value ~= nil then
      if type(value) == "table" and type(result[key]) == "table" then
        util.merge_tables(result[key], value)
      else
        result[key] = value
      end
    end
  end

  if resolved.backdrop == false then
    result.backdrop = nil
  elseif resolved.backdrop ~= nil then
    if color.is_hex_color(resolved.backdrop) then
      result.backdrop = { color = resolved.backdrop, alpha = DEFAULT_WIDGET_THEME.backdrop.alpha }
    elseif type(resolved.backdrop) == "table" then
      result.backdrop = {
        color = color_or(
          resolved.backdrop.color or resolved.backdrop.bg,
          DEFAULT_WIDGET_THEME.backdrop.color
        ),
        alpha = math.max(
          0,
          math.min(
            255,
            math.floor(tonumber(resolved.backdrop.alpha) or DEFAULT_WIDGET_THEME.backdrop.alpha)
          )
        ),
      }
    end
  end

  return result
end

return M
