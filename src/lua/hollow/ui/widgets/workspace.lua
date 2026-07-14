local actions = require("hollow.ui.workspace.actions")
local color = require("hollow.color")
local format = require("hollow.ui.widgets.format")
local shared = require("hollow.ui.shared")
local source = require("hollow.ui.workspace.source")
local util = require("hollow.util")

---@type Hollow
local hollow = _G.hollow
---@type HollowUi
local ui = hollow.ui

ui.workspace = ui.workspace or {}

local DEFAULT_PROMPT = "Workspaces"
local DEFAULT_SELECT_WIDTH = 96
local DEFAULT_SELECT_MAX_HEIGHT = 18
local ACTIVE_WORKSPACE_MARKER = "•"
local DEFAULT_STATUS_COLUMN_WIDTH = 2
local DEFAULT_NAME_COLUMN_WIDTH = 24
local DEFAULT_COLUMN_GAP = 2
local DEFAULT_RENAME_KEY = "<C-r>"
local DEFAULT_CLOSE_KEY = "<C-x>"
local DEFAULT_CREATE_KEY = "<C-n>"

local function switcher_state()
  return source.switcher_state()
end

local function workspace_name_color(name)
  local custom_fn = switcher_state().workspace_color_fn
  if custom_fn then
    return custom_fn(name)
  end
  local theme = shared.resolve_theme()
  local hash = 0
  for i = 1, #name do
    hash = (hash * 31 + name:byte(i)) % 2147483647
  end
  -- Golden angle (~222.5deg) for maximal hue distance between workspaces
  local hue = ((hash / 2147483647) * 360 + 222.5) % 360
  local bg_luminance = color.hex_luminance(theme.palette.background)
  local is_dark = bg_luminance < 128
  local saturation = 0.3
  local lightness = is_dark and 0.22 or 0.68
  local bg = color.hex_from_hsl(hue, saturation, lightness)
  local fg = color.contrast_hex_color(bg, 0.45, theme.palette.foreground)
  return { bg = bg, fg = fg }
end

local function derived_palette()
  local theme = shared.resolve_theme()
  local palette = theme.palette
  return {
    fg = palette.foreground,
    muted = color.darken_hex_color(palette.foreground, 0.35, palette.foreground),
    subtle = color.brighten_hex_color(palette.background, 0.35, palette.foreground),
    open = palette.bright_green,
    user = palette.bright_blue,
  }
end

local function default_format_item(workspace)
  local switcher = switcher_state()
  local palette = derived_palette()
  local name_color = workspace.is_active and palette.open
    or (workspace.is_open and palette.user or palette.muted)
  local total_width = tonumber(switcher.width) or DEFAULT_SELECT_WIDTH
  local status_width =
    math.max(2, tonumber(switcher.status_column_width) or DEFAULT_STATUS_COLUMN_WIDTH)
  local name_width = math.max(12, tonumber(switcher.name_column_width) or DEFAULT_NAME_COLUMN_WIDTH)
  local gap_width = math.max(1, tonumber(switcher.column_gap) or DEFAULT_COLUMN_GAP)
  local cwd_width = math.max(12, total_width - status_width - name_width - (gap_width * 2) - 10)

  local cwd_text = source.trim_string(workspace.cwd)
  if cwd_text == "" then
    cwd_text = workspace.is_active and "Current workspace"
      or (workspace.is_open and "Open workspace" or "Known workspace")
  end

  local domain = source.normalize_domain(workspace.domain)
  local current_domain = source.normalize_domain(source.current_domain_name())
  if domain ~= nil and domain ~= current_domain then
    cwd_text = "[" .. domain .. "] " .. cwd_text
  end

  return format.columns({
    {
      text = workspace.is_active and ACTIVE_WORKSPACE_MARKER or " ",
      width = status_width,
      style = {
        fg = workspace.is_active and palette.open or palette.subtle,
        bold = workspace.is_active,
      },
    },
    { text = "", width = gap_width, style = { fg = palette.subtle } },
    {
      text = workspace.name,
      width = name_width,
      style = { fg = name_color, bold = workspace.is_active },
    },
    { text = "", width = gap_width, style = { fg = palette.subtle } },
    { text = cwd_text, width = cwd_width, style = { fg = palette.subtle, bold = false } },
  })
end

local function item_formatter()
  return switcher_state().format_item or default_format_item
end

local function workspace_parts(prefix, suffix)
  local current = hollow.term.current_workspace()
  local name = current and current.name or "workspace"
  local p = prefix or "  "
  local s = suffix
  if s == nil then
    local index = current and current.index or 1
    local count = current and #hollow.term.workspaces() or 1
    s = " " .. index .. "/" .. count
  end
  return { prefix = p, name = name, suffix = s }
end

local function search_text_for_item(workspace)
  local parts = { workspace.name }
  local cwd = source.trim_string(workspace.cwd)
  if cwd ~= "" then
    local basename = util.basename(cwd)
    basename = source.trim_string(basename)
    if basename ~= "" and basename ~= workspace.name then
      parts[#parts + 1] = basename
    end
  end

  local domain = source.normalize_domain(workspace.domain)
  local current_domain = source.normalize_domain(source.current_domain_name())
  if domain ~= nil and domain ~= current_domain then
    parts[#parts + 1] = domain
  end

  return table.concat(parts, "\n")
end

local function detail_for_item(_workspace)
  return nil
end

local function switcher_actions()
  local switcher = switcher_state()
  return {
    {
      name = "select",
      desc = "switch",
      fn = function(item)
        ui.select.close()
        actions.switch_to_workspace(item)
      end,
    },
    {
      name = "rename",
      key = switcher.rename_key or DEFAULT_RENAME_KEY,
      desc = switcher.rename_desc or "rename",
      fn = function(item)
        ui.select.close()
        actions.open_rename_input(item)
      end,
    },
    {
      name = "close",
      key = switcher.close_key or DEFAULT_CLOSE_KEY,
      desc = switcher.close_desc or "close",
      fn = function(item)
        ui.select.close()
        actions.close_workspace(item)
      end,
    },
    {
      name = "new",
      key = switcher.create_key or DEFAULT_CREATE_KEY,
      desc = switcher.create_desc or "new",
      fn = function()
        ui.select.close()
        actions.open_create_input()
      end,
    },
  }
end

function ui.workspace.configure(opts)
  source.configure(opts)
end

function ui.workspace.clear_cache()
  source.clear_cache()
end

function ui.workspace.known_workspaces(force_refresh)
  return source.known_workspaces(force_refresh)
end

function ui.workspace.items(force_refresh)
  return source.items(force_refresh)
end

function ui.workspace.create(opts)
  actions.open_create_input(opts)
end

function ui.workspace.rename(workspace, opts)
  actions.open_rename_input(workspace, opts)
end

function ui.workspace.close(workspace)
  actions.close_workspace(workspace)
end

function ui.workspace.open(opts)
  actions.open_workspace(opts)
end

function ui.workspace.open_switcher(opts)
  opts = opts or {}
  local force_refresh = opts.force_refresh == true
  opts.force_refresh = nil
  if next(opts) ~= nil then
    source.configure(opts)
  end

  local items = source.items(force_refresh)
  local switcher = switcher_state()
  ui.select.open({
    prompt = switcher.prompt or DEFAULT_PROMPT,
    items = items,
    fuzzy = false,
    width = switcher.width or DEFAULT_SELECT_WIDTH,
    height = switcher.height,
    max_height = switcher.max_height or DEFAULT_SELECT_MAX_HEIGHT,
    backdrop = switcher.backdrop,
    chrome = switcher.chrome,
    theme = switcher.theme,
    label = function(item)
      return item_formatter()(item)
    end,
    search_text = search_text_for_item,
    detail = detail_for_item,
    actions = switcher_actions(),
  })
end

function ui.workspace.topbar_button(opts)
  opts = opts or {}
  local style = {}
  if opts.colorize ~= false then
    local current = hollow.term.current_workspace()
    local colors = workspace_name_color(current and current.name or "workspace")
    style.bg = colors.bg
    style.fg = colors.fg
  end
  if type(opts.style) == "table" then
    for k, v in pairs(opts.style) do
      style[k] = v
    end
  end

  if opts.text ~= nil then
    return ui.button({
      id = opts.id or "workspace-switcher-button",
      text = opts.text,
      style = style,
      on_click = function()
        ui.workspace.open_switcher(opts.switcher or {})
      end,
    })
  end

  local parts = workspace_parts(opts.prefix, opts.suffix)
  return {
    ui.span(parts.prefix, {
      bg = style.bg,
      fg = color.brighten_hex_color(style.bg, 0.3, style.fg),
    }),
    ui.span(parts.name, {
      bg = style.bg,
      fg = style.fg,
      bold = true,
      id = opts.id or "workspace-switcher-button",
      on_click = function()
        ui.workspace.open_switcher(opts.switcher or {})
      end,
    }),
    ui.span(parts.suffix, {
      bg = style.bg,
      fg = color.brighten_hex_color(style.bg, 0.3, style.fg),
    }),
  }
end

ui.workspace.switcher = ui.workspace.open_switcher
