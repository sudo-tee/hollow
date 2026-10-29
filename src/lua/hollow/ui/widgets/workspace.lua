local actions = require("hollow.ui.workspace.actions")
local color = require("hollow.color")
local format = require("hollow.ui.widgets.format")
local icons = require("hollow.ui.icons")
local program_status = require("hollow.program_status")
local shared = require("hollow.ui.shared")
local source = require("hollow.ui.workspace.source")
local theme_api = require("hollow.theme")
local util = require("hollow.util")

---@type Hollow
local hollow = _G.hollow
---@type HollowUi
local ui = hollow.ui

ui.workspace = ui.workspace or {}

local DEFAULT_PROMPT = "Workspaces"
local DEFAULT_SELECT_WIDTH = 96
local DEFAULT_SELECT_MAX_HEIGHT = 24
local DEFAULT_STATUS_COLUMN_WIDTH = 2
local DEFAULT_NAME_COLUMN_WIDTH = 24
local DEFAULT_COLUMN_GAP = 2
local DEFAULT_RENAME_KEY = "<C-r>"
local DEFAULT_CLOSE_KEY = "<C-x>"
local DEFAULT_CREATE_KEY = "<C-n>"
---@type HollowUiNodeStyle
local DOMAIN_PILL = { radius = 4 }
---@type HollowUiNodeStyle
local BOLD = { bold = true }
---@type HollowUiNodeStyle
local PLAIN = { bold = false }

---@class (exact) HollowWorkspaceItemPalette
---@field fg? HollowColor
---@field muted? HollowColor
---@field subtle? HollowColor
---@field open? HollowColor
---@field user? HollowColor
---@field bell? HollowColor
---@field bell_error? HollowColor

---@class (exact) HollowWorkspaceItemStyles
---@field status HollowUiNodeStyle
---@field gap HollowUiNodeStyle
---@field name HollowUiNodeStyle
---@field badge HollowUiNodeStyle
---@field cwd HollowUiNodeStyle

---@class (exact) HollowWorkspaceTopbarStyles
---@field edge HollowUiNodeStyle
---@field name HollowUiNodeStyle

---@return HollowUiWorkspaceSwitcherState
local function switcher_state()
  return source.switcher_state()
end

---@param name string
---@return HollowUiColorPair
local function workspace_name_color(name)
  return shared.workspace_colors(name, switcher_state().workspace_color_fn)
end

---@return HollowWorkspaceItemPalette
local function derived_palette()
  local theme = shared.resolve_theme()
  local palette = theme.palette
  return {
    fg = palette.foreground,
    muted = color.darken_hex_color(palette.foreground, 0.35, palette.foreground),
    subtle = color.brighten_hex_color(palette.background, 0.35, palette.foreground),
    open = palette.bright_green,
    user = palette.bright_blue,
    bell = theme_api.resolve_widget("select").notify_levels.warn,
    bell_error = theme_api.resolve_widget("select").notify_levels.error,
  }
end

---@param workspace HollowUiWorkspaceItem
---@param palette HollowWorkspaceItemPalette
---@return HollowWorkspaceItemStyles
local function item_styles(workspace, palette)
  local attention = workspace.has_bell or workspace.program_status_attention
  local bell = workspace.program_status_attention_level == "error" and palette.bell_error
    or palette.bell
  return {
    status = {
      fg = attention and bell or (workspace.is_active and palette.open or palette.subtle),
      bold = attention or workspace.is_active,
    },
    gap = { fg = palette.subtle },
    name = {
      fg = util.state_value(
        workspace.is_active,
        workspace.is_open,
        palette.open,
        palette.user,
        palette.muted
      ),
      bold = workspace.is_active,
    },
    badge = ui.style(BOLD, { fg = program_status.color(workspace.program_status_state) }),
    cwd = ui.style(PLAIN, { fg = palette.subtle }),
  }
end

---@param colors HollowUiColorPair
---@return HollowUiNodeStyle
local function domain_pill_style(colors)
  -- Color callbacks supply paint only, never pill geometry or interaction.
  return ui.style(DOMAIN_PILL, { fg = colors.fg, bg = colors.bg })
end

---@param workspace HollowUiWorkspaceItem
---@param domain_width? integer
---@return HollowUiRenderableNode[]
local function default_format_item(workspace, domain_width)
  local attention = workspace.has_bell or workspace.program_status_attention
  local switcher = switcher_state()
  local palette = derived_palette()
  local styles = item_styles(workspace, palette)
  local total_width = tonumber(switcher.width) or DEFAULT_SELECT_WIDTH
  local status_width =
    math.max(2, tonumber(switcher.status_column_width) or DEFAULT_STATUS_COLUMN_WIDTH)
  local name_width = math.max(12, tonumber(switcher.name_column_width) or DEFAULT_NAME_COLUMN_WIDTH)
  local gap_width = math.max(1, tonumber(switcher.column_gap) or DEFAULT_COLUMN_GAP)
  local badge = workspace.program_status_badge or ""
  local badge_width = util.utf8_len(badge)
  domain_width = domain_width or 0
  local cwd_width = math.max(
    12,
    total_width - status_width - name_width - badge_width - domain_width - (gap_width * 2) - 10
  )

  local cwd_text = source.trim_string(workspace.cwd)
  if cwd_text == "" then
    cwd_text = util.state_value(
      workspace.is_active,
      workspace.is_open,
      "Current workspace",
      "Open workspace",
      "Known workspace"
    )
  end

  local domain = source.normalize_domain(workspace.domain)
  local domain_colors = workspace_name_color(domain or "default")

  local columns = format.columns({
    {
      text = attention and icons.bell or (workspace.is_active and icons.workspace_active or " "),
      width = status_width,
      style = styles.status,
    },
    { text = "", width = gap_width, style = styles.gap },
    {
      text = workspace.name,
      width = name_width,
      style = styles.name,
    },
    { text = "", width = gap_width, style = styles.gap },
    {
      text = badge,
      width = badge_width,
      style = styles.badge,
    },
    { text = cwd_text, width = cwd_width, style = styles.cwd },
  })
  return shared.normalize_inline_nodes({
    columns,
    ui.when(domain and domain_width > 0, function()
      return {
        ui.spacer(),
        ui.span(
          " " .. util.truncate_end(domain, domain_width - 3) .. " ",
          domain_pill_style(domain_colors)
        ),
      }
    end),
  })
end

---@param items HollowUiWorkspaceItem[]
---@return integer
local function domain_column_width(items)
  local width = 0
  local domains = {}
  local count = 0
  for _, workspace in ipairs(items) do
    local domain = source.normalize_domain(workspace.domain)
    if domain then
      if not domains[domain] then
        domains[domain] = true
        count = count + 1
      end
      width = math.max(width, math.min(23, #domain + 3))
    end
  end
  return count > 1 and width or 0
end

---@param prefix? string
---@param suffix? string
---@return {prefix: string, name: string, suffix: string}
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

---@param workspace HollowUiWorkspaceItem
---@return string
local function search_text_for_item(workspace)
  local cwd = source.trim_string(workspace.cwd)
  local basename = source.trim_string(cwd ~= "" and util.basename(cwd) or nil)
  local domain = source.normalize_domain(workspace.domain)
  return hollow
    .tbl({ workspace.name })
    :concat(
      basename ~= "" and basename ~= workspace.name and { basename } or {},
      domain ~= nil and { domain } or {}
    )
    :join("\n")
end

---@return HollowUiSelectAction[]
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

---@param opts? HollowUiWorkspaceSwitcherOptions
function ui.workspace.configure(opts)
  source.configure(opts)
end

function ui.workspace.clear_cache()
  source.clear_cache()
end

---@param force_refresh? boolean
---@return HollowUiWorkspaceItem[]
function ui.workspace.known_workspaces(force_refresh)
  return source.known_workspaces(force_refresh)
end

---@param force_refresh? boolean
---@return HollowUiWorkspaceItem[]
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

---@param opts? HollowUiWorkspaceSwitcherOptions
function ui.workspace.open_switcher(opts)
  opts = opts or {}
  local force_refresh = opts.force_refresh == true
  local config = hollow.tbl(opts):omit("force_refresh")
  if next(config) ~= nil then
    source.configure(config)
  end

  local items = source.items(force_refresh)
  local domain_width = domain_column_width(items)
  local switcher = switcher_state()
  local host_revision = switcher.host_scan_revision or 0
  ui.select.open({
    prompt = switcher.prompt or DEFAULT_PROMPT,
    items = function()
      local current_revision = switcher_state().host_scan_revision or 0
      if current_revision ~= host_revision then
        items = source.items()
        domain_width = domain_column_width(items)
        host_revision = current_revision
      end
      -- Read live status without rescanning local/remote discovery sources.
      local badges = {}
      local states = {}
      local attention = {}
      local attention_levels = {}
      for _, workspace in ipairs(hollow.term.mux_tree()) do
        badges[workspace.id], states[workspace.id] = program_status.workspace_badge(workspace)
        attention[workspace.id] = program_status.workspace_needs_attention(workspace)
        attention_levels[workspace.id] = program_status.workspace_attention_level(workspace)
      end
      for _, item in ipairs(items) do
        item.program_status_badge = badges[item.workspace_id]
        item.program_status_state = states[item.workspace_id]
        item.program_status_attention = attention[item.workspace_id]
        item.program_status_attention_level = attention_levels[item.workspace_id]
      end
      return items
    end,
    fuzzy = false,
    width = switcher.width or DEFAULT_SELECT_WIDTH,
    height = switcher.height,
    max_height = switcher.max_height or DEFAULT_SELECT_MAX_HEIGHT,
    backdrop = switcher.backdrop,
    chrome = switcher.chrome,
    theme = switcher.theme,
    label = function(item)
      local formatter = switcher_state().format_item
      if formatter then
        return formatter(item)
      end
      return default_format_item(item, domain_width)
    end,
    search_text = search_text_for_item,
    actions = switcher_actions(),
  })
end

---@param style HollowUiNodeStyle
---@return HollowWorkspaceTopbarStyles
local function topbar_part_styles(style)
  return {
    edge = { bg = style.bg, fg = color.brighten_hex_color(style.bg, 0.3, style.fg) },
    name = ui.style(BOLD, { bg = style.bg, fg = style.fg }),
  }
end

---@param opts? HollowUiWorkspaceTopbarOptions
---@return HollowUiSpanNode|HollowUiSpanNode[]
function ui.workspace.topbar_button(opts)
  opts = opts or {}
  local style = hollow.tbl(type(opts.style) == "table" and opts.style or {}):entries()
  if opts.colorize ~= false then
    local current = hollow.term.current_workspace()
    local colors = workspace_name_color(current and current.name or "workspace")
    style = util.merge_tables({ bg = colors.bg, fg = colors.fg }, style)
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
  local styles = topbar_part_styles(style)
  return {
    ui.span(parts.prefix, ui.style(styles.edge)),
    ui.button({
      text = parts.name,
      style = styles.name,
      id = opts.id or "workspace-switcher-button",
      on_click = function()
        ui.workspace.open_switcher(opts.switcher or {})
      end,
    }),
    ui.span(parts.suffix, ui.style(styles.edge)),
  }
end

ui.workspace.switcher = ui.workspace.open_switcher
