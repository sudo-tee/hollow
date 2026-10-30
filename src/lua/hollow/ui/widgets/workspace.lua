local actions = require("hollow.ui.workspace.actions")
local color = require("hollow.color")
local icons = require("hollow.ui.icons")
local program_status = require("hollow.program_status")
local shared = require("hollow.ui.shared")
local source = require("hollow.ui.workspace.source")
local styles = require("hollow.ui.recipes.workspace")
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
local CWD_FALLBACK = {
  active = "Current workspace",
  open = "Open workspace",
  known = "Known workspace",
}

---@class (exact) HollowWorkspaceItemPalette
---@field fg? HollowColor
---@field muted? HollowColor
---@field subtle? HollowColor
---@field open? HollowColor
---@field user? HollowColor
---@field bell? HollowColor
---@field bell_error? HollowColor
---@field styles? HollowUiThemeStyles

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
  local select = theme_api.resolve_widget("select")
  return {
    fg = palette.foreground,
    muted = color.darken_hex_color(palette.foreground, 0.35, palette.foreground),
    subtle = color.brighten_hex_color(palette.background, 0.35, palette.foreground),
    open = palette.bright_green,
    user = palette.bright_blue,
    bell = select.notify_levels.warn,
    bell_error = select.notify_levels.error,
    styles = select.styles,
  }
end

-- Retain the original padded accessibility labels independently of layout.
local function default_item_columns(workspace, domain_width)
  local attention = workspace.has_bell or workspace.program_status_attention
  local switcher = switcher_state()
  local variant = workspace.is_active and "active" or (workspace.is_open and "open" or "known")
  local total_width = tonumber(switcher.width) or DEFAULT_SELECT_WIDTH
  local status_width =
    math.max(2, tonumber(switcher.status_column_width) or DEFAULT_STATUS_COLUMN_WIDTH)
  local name_width = math.max(12, tonumber(switcher.name_column_width) or DEFAULT_NAME_COLUMN_WIDTH)
  local gap_width = math.max(1, tonumber(switcher.column_gap) or DEFAULT_COLUMN_GAP)
  local badge = workspace.program_status_badge or ""
  local badge_width = util.display_width(badge)
  domain_width = domain_width or 0
  local cwd_width = math.max(
    12,
    total_width - status_width - name_width - badge_width - domain_width - (gap_width * 2) - 10
  )

  local cwd_text = source.trim_string(workspace.cwd)
  if cwd_text == "" then
    cwd_text = CWD_FALLBACK[variant]
  end

  local domain = source.normalize_domain(workspace.domain)
  return {
    variant = variant,
    attention = attention,
    domain = domain,
    status = attention and icons.bell or (workspace.is_active and icons.workspace_active or " "),
    status_width = status_width,
    name_width = name_width,
    gap_width = gap_width,
    badge = badge,
    badge_width = badge_width,
    cwd = cwd_text,
    cwd_width = cwd_width,
    domain_text = domain and domain_width > 0 and (" " .. util.truncate_end(
      domain,
      domain_width - 3
    ) .. " ") or nil,
  }
end

local function default_plain_item(workspace, domain_width)
  local c = default_item_columns(workspace, domain_width)
  local function pad(text, width)
    return util.pad_right(util.truncate_end(tostring(text or ""), width), width)
  end
  return pad(c.status, c.status_width)
    .. pad("", c.gap_width)
    .. pad(workspace.name, c.name_width)
    .. pad("", c.gap_width)
    .. pad(c.badge, c.badge_width)
    .. pad(c.cwd, c.cwd_width)
    .. (c.domain_text or "")
end

-- Native counterpart of the default formatter: retain column settings/paint,
-- but let Clay allocate the remaining cwd width instead of padding strings.
local function layout_format_item(workspace, domain_width, ctx, view)
  local c = ui.components
  local component = require("hollow.ui.components.select")
  local switcher = switcher_state()
  ctx._workspace_palette = ctx._workspace_palette or derived_palette()
  local palette = ctx._workspace_palette
  local variant = workspace.is_active and "active" or (workspace.is_open and "open" or "known")
  local s = styles(palette, { variant = variant })
  local match = require("hollow.ui.recipes.select")(view.theme).match
  local cell_w, cell_h = ctx.cell_w or 8, ctx.cell_h or 19
  local status_width =
    math.max(2, tonumber(switcher.status_column_width) or DEFAULT_STATUS_COLUMN_WIDTH)
  local name_width = math.max(12, tonumber(switcher.name_column_width) or DEFAULT_NAME_COLUMN_WIDTH)
  local gap = math.max(1, tonumber(switcher.column_gap) or DEFAULT_COLUMN_GAP) * cell_w
  local attention = workspace.has_bell or workspace.program_status_attention
  local bell = workspace.program_status_attention_level == "error" and palette.bell_error
    or palette.bell
  local cwd = source.trim_string(workspace.cwd)
  if cwd == "" then
    cwd = CWD_FALLBACK[variant]
  end
  local function column(text, style, width, suffix)
    return component.inline(
      shared.highlight_inline_nodes({ ui.text(text, style) }, view.query, match),
      nil,
      {
        id = view.id .. ":" .. suffix,
        width = width,
        height = cell_h,
        scroll_x = true,
        align_y = "center",
      }
    )
  end
  local columns = {
    c.column({
      c.text(
        attention and icons.bell or (workspace.is_active and icons.workspace_active or " "),
        ui.style(s.status, attention and { fg = bell, bold = true }),
        { wrap = "none" }
      ),
    }, { width = status_width * cell_w }),
    c.column({}, { width = gap }),
    column(util.truncate_end(workspace.name, name_width), s.name, name_width * cell_w, "name"),
    c.column({}, { width = gap }),
  }
  local badge = workspace.program_status_badge or ""
  if badge ~= "" then
    columns[#columns + 1] = c.text(
      badge,
      ui.style(s.badge, { fg = program_status.color(workspace.program_status_state) }),
      { wrap = "none" }
    )
  end
  columns[#columns + 1] = column(cwd, s.cwd, "grow", "cwd")
  local domain = source.normalize_domain(workspace.domain)
  if domain and domain_width > 0 then
    local colors = workspace_name_color(domain)
    columns[#columns + 1] = c.column({
      c.text(
        " " .. util.truncate_end(domain, domain_width - 3) .. " ",
        { fg = colors.fg },
        { wrap = "none" }
      ),
    }, {
      style = ui.style(s.domain_pill, { fg = colors.fg, bg = colors.bg }),
    })
  end
  return c.row(columns, { width = "grow", height = cell_h, align_y = "center" })
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
  local dirty = false
  local deadline
  local events = {
    "term:program_status_changed",
    "term:bell",
    "term:pane_focused",
    "term:pane_created",
    "term:pane_exited",
    "term:pane_closed",
    "term:pane_layout_changed",
    "term:title_changed",
    "term:cwd_changed",
    "term:foreground_process_changed",
    "term:tab_activated",
    "term:tab_closed",
    "workspace:new",
    "workspace:changed",
    "workspace:closed",
    "workspace:items_changed",
    "config:reloaded",
    "config:changed",
    "theme:changed",
    "term:command_started",
    "term:command_finished",
  }
  local listeners = {}
  ui.select.open({
    layout_live = type(switcher.format_item) == "function",
    semantic_hover = false,
    layout_events = events,
    layout_refresh_after = function()
      return deadline
        and math.max(1, deadline - util.host_now_ms(require("hollow.state").get().host_api))
    end,
    on_mount = function()
      for _, name in ipairs(events) do
        if name ~= "term:program_status_changed" and name ~= "term:bell" then
          listeners[#listeners + 1] = hollow.events.on(name, function()
            dirty = true
          end)
        end
      end
    end,
    on_unmount = function()
      for _, listener in ipairs(listeners) do
        hollow.events.off(listener)
      end
    end,
    prompt = switcher.prompt or DEFAULT_PROMPT,
    items = function()
      local current_revision = switcher_state().host_scan_revision or 0
      if dirty or current_revision ~= host_revision then
        items = source.items()
        domain_width = domain_column_width(items)
        host_revision = current_revision
        dirty = false
      end
      -- Read live status without rescanning local/remote discovery sources.
      local badges = {}
      local states = {}
      local attention = {}
      local attention_levels = {}
      deadline = nil
      for _, workspace in ipairs(hollow.term.mux_tree()) do
        local next_frame
        badges[workspace.id], states[workspace.id], next_frame =
          program_status.workspace_badge(workspace)
        if next_frame then
          deadline = math.min(deadline or next_frame, next_frame)
        end
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
      return default_plain_item(item, domain_width)
    end,
    layout_label = function(item, ctx, view)
      if switcher_state().format_item then
        return nil
      end
      return layout_format_item(item, domain_width, ctx, view)
    end,
    search_text = search_text_for_item,
    actions = switcher_actions(),
  })
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
  local edge = { bg = style.bg, fg = color.brighten_hex_color(style.bg, 0.3, style.fg) }
  return {
    ui.span(parts.prefix, ui.style(edge)),
    ui.button({
      text = parts.name,
      style = ui.style({ bold = true, bg = style.bg, fg = style.fg }),
      id = opts.id or "workspace-switcher-button",
      on_click = function()
        ui.workspace.open_switcher(opts.switcher or {})
      end,
    }),
    ui.span(parts.suffix, ui.style(edge)),
  }
end

ui.workspace.switcher = ui.workspace.open_switcher
