local state = require("hollow.state").get()
local util = require("hollow.util")

---@type Hollow
local hollow = _G.hollow
---@type HollowUi
local ui = hollow.ui

ui.workspace = ui.workspace or {}

local DEFAULT_CACHE_TTL_MS = 5000
local DEFAULT_PROMPT = "Workspace"
local DEFAULT_SELECT_WIDTH = 96
local DEFAULT_SELECT_MAX_HEIGHT = 18
local ACTIVE_WORKSPACE_MARKER = "•"
local DEFAULT_STATUS_COLUMN_WIDTH = 2
local DEFAULT_NAME_COLUMN_WIDTH = 24
local DEFAULT_COLUMN_GAP = 2
local DEFAULT_RENAME_KEY = "<C-r>"
local DEFAULT_CLOSE_KEY = "<C-w>"
local DEFAULT_CREATE_KEY = "<C-n>"

local ui_theme = {
  accent = "#e6c384",
  fg = "#dcd7ba",
  muted = "#727169",
  subtle = "#5f5b53",
  open = "#98bb6c",
  user = "#7fb4ca",
}

local function switcher_state()
  return state.ui.workspace_switcher
end

local function now_ms()
  local ok, value = pcall(hollow.now_ms)
  if ok and type(value) == "number" then
    return value
  end

  local ok_host, host_value = pcall(state.host_api.now_ms)
  if ok_host and type(host_value) == "number" then
    return host_value
  end

  return math.floor(os.time() * 1000)
end

local function trim_string(value)
  if type(value) ~= "string" then
    return ""
  end

  return value:match("^%s*(.-)%s*$") or ""
end

local function path_join(base, name)
  if type(base) ~= "string" or base == "" then
    return name
  end
  if type(name) ~= "string" or name == "" then
    return base
  end

  local separator = base:find("\\", 1, true) and "\\" or "/"
  local trimmed_base = base:gsub("[\\/]+$", "")
  local trimmed_name = name:gsub("^[\\/]+", "")
  return trimmed_base .. separator .. trimmed_name
end

local function shell_escape(value)
  value = tostring(value or "")
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function default_project_roots()
  local roots = {}
  local home = os.getenv("HOME")
  local userprofile = os.getenv("USERPROFILE")

  if type(home) == "string" and home ~= "" then
    roots[#roots + 1] = path_join(home, "src")
    roots[#roots + 1] = path_join(home, "code")
    roots[#roots + 1] = path_join(home, "projects")
    roots[#roots + 1] = path_join(home, "work")
    roots[#roots + 1] = path_join(home, "dev")
  end

  if type(userprofile) == "string" and userprofile ~= "" then
    roots[#roots + 1] = path_join(userprofile, "src")
    roots[#roots + 1] = path_join(userprofile, "code")
    roots[#roots + 1] = path_join(userprofile, "projects")
    roots[#roots + 1] = path_join(userprofile, "work")
    roots[#roots + 1] = path_join(userprofile, "dev")
  end

  return roots
end

local function path_exists(path)
  if type(path) ~= "string" or path == "" then
    return false
  end

  local ok, result, code = os.rename(path, path)
  if ok then
    return true
  end
  return code == 13 or type(result) == "string"
end

local function scan_projects_in_root(root)
  if type(root) ~= "string" or root == "" or not path_exists(root) then
    return {}
  end

  local command = string.format('ls -1A "%s" 2>/dev/null', root:gsub('"', '\\"'))
  local pipe = io.popen(command)
  if pipe == nil then
    return {}
  end

  local items = {}
  for entry in pipe:lines() do
    local name = trim_string(entry)
    if name ~= "" and name:sub(1, 1) ~= "." then
      local cwd = path_join(root, name)
      if path_exists(cwd) then
        items[#items + 1] = {
          name = name,
          cwd = cwd,
        }
      end
    end
  end
  pipe:close()
  return items
end

local function scan_projects_in_wsl_root(source_name, root)
  source_name = trim_string(source_name)
  if source_name == "" or type(root) ~= "string" or root == "" then
    return {}
  end

  local escaped_name = source_name:gsub('"', '\\"')
  local escaped_root = root:gsub('"', '\\"')
  local command = 'cmd.exe /c "wsl.exe -d ' .. escaped_name .. ' -- ls -1A \"' .. escaped_root .. '\" 2>nul"'
  local pipe = io.popen(command)
  if pipe == nil then
    if ui.notify and ui.notify.warn then
      ui.notify.warn("Workspace source failed: wsl " .. source_name, { ttl = 1800 })
    end
    return {}
  end

  local items = {}
  for line in pipe:lines() do
    local name = trim_string(line)
    local cwd = name ~= "" and path_join(root, name) or ""
    if name ~= "" and cwd ~= "" then
      items[#items + 1] = {
        name = name,
        cwd = cwd,
      }
    end
  end
  pipe:close()
  if #items == 0 and ui.notify and ui.notify.warn then
    ui.notify.warn("Workspace source returned no folders: wsl " .. source_name, { ttl = 1800 })
  end
  return items
end

local function normalize_workspace_id(name)
  return trim_string(name):lower()
end

local function normalize_domain(value)
  local domain = trim_string(value)
  if domain == "" then
    return nil
  end
  return domain
end

local function current_domain_name()
  local pane = hollow.term.current_pane()
  if pane and type(pane.domain) == "string" and pane.domain ~= "" then
    return pane.domain
  end
  return nil
end

local function workspace_identity(name, cwd, domain)
  local normalized_domain = normalize_domain(domain) or current_domain_name() or "default"
  local normalized_cwd = trim_string(cwd)
  if normalized_cwd ~= "" then
    return normalized_domain .. ":" .. normalized_cwd
  end
  local normalized_name = normalize_workspace_id(name)
  if normalized_name ~= "" then
    return normalized_domain .. ":name:" .. normalized_name
  end
  return normalized_domain .. ":workspace"
end

local function default_known_workspaces()
  local switcher = switcher_state()
  local roots = switcher.project_roots or default_project_roots()
  local merged = {}
  local seen = {}
  local domain = current_domain_name()

  for _, root in ipairs(roots) do
    for _, item in ipairs(scan_projects_in_root(root)) do
      local id = workspace_identity(item.name, item.cwd, domain)
      if id ~= "" and not seen[id] then
        seen[id] = true
        item.domain = domain
        merged[#merged + 1] = item
      end
    end
  end

  table.sort(merged, function(a, b)
    return a.name < b.name
  end)

  return merged
end

local function first_pane_cwd(workspace)
  if type(workspace) ~= "table" then
    return nil
  end

  local panes = workspace.panes
  if type(panes) == "table" then
    for _, pane in ipairs(panes) do
      if type(pane) == "table" and type(pane.cwd) == "string" and pane.cwd ~= "" then
        return pane.cwd
      end
    end
  end

  local pane = workspace.pane
  if type(pane) == "table" and type(pane.cwd) == "string" and pane.cwd ~= "" then
    return pane.cwd
  end

  return nil
end

local function current_pane_cwd()
  local pane = hollow.term.current_pane()
  if pane and type(pane.cwd) == "string" and pane.cwd ~= "" then
    return pane.cwd
  end
  return nil
end

local function active_workspace_name()
  local workspace = hollow.term.current_workspace()
  if workspace and type(workspace.name) == "string" then
    return workspace.name
  end
  return nil
end

local function send_cwd_to_active_workspace(cwd)
  if type(cwd) ~= "string" or cwd == "" then
    return
  end

  local escaped = cwd:gsub('"', '\\"')
  hollow.term.send_text('cd "' .. escaped .. '"\r')
end

local function ensure_last_opened(name, timestamp)
  local id = normalize_workspace_id(name)
  if id == "" then
    return
  end

  local switcher = switcher_state()
  local value = tonumber(timestamp) or now_ms()
  local existing = switcher.last_opened[id]
  if existing == nil or value >= existing then
    switcher.last_opened[id] = value
  end
end

local function register_workspace_listeners()
  local switcher = switcher_state()
  if switcher.listeners_registered then
    return
  end
  if type(hollow.events) ~= "table" or type(hollow.events.on) ~= "function" then
    return
  end

  hollow.events.on("term:tab_activated", function()
    local workspace = hollow.term.current_workspace()
    if workspace and workspace.name then
      ensure_last_opened(workspace.name)
    end
  end)

  hollow.events.on("term:cwd_changed", function()
    local workspace = hollow.term.current_workspace()
    if workspace and workspace.name then
      ensure_last_opened(workspace.name)
    end
  end)

  hollow.events.on("term:title_changed", function()
    local workspace = hollow.term.current_workspace()
    if workspace and workspace.name then
      ensure_last_opened(workspace.name)
    end
  end)

  hollow.events.on("term:tab_closed", function()
    local workspace = hollow.term.current_workspace()
    if workspace and workspace.name then
      ensure_last_opened(workspace.name)
    end
  end)

  local current_name = active_workspace_name()
  if current_name then
    ensure_last_opened(current_name)
  end

  switcher.listeners_registered = true
end

local function configured_known_workspaces()
  local callback = switcher_state().known_workspaces
  if type(callback) ~= "function" then
    callback = default_known_workspaces
  end

  local ok, items = pcall(callback)
  if not ok or type(items) ~= "table" then
    return {}
  end

  return items
end

local function configured_sources()
  local sources = switcher_state().sources
  if type(sources) == "function" then
    local ok, result = pcall(sources)
    if ok and type(result) == "table" then
      return result
    end
    return {}
  end
  if type(sources) == "table" then
    return sources
  end
  return {}
end

local function workspace_filter()
  local filter = switcher_state().filter_item
  if type(filter) == "function" then
    return filter
  end
  return nil
end

local function include_workspace_item(item)
  local filter = workspace_filter()
  if filter == nil then
    return true
  end

  local ok, allowed = pcall(filter, util.clone_value(item))
  if not ok then
    return true
  end

  return allowed ~= false
end

local function source_domain_name(source)
  return normalize_domain(source.domain) or current_domain_name()
end

local function source_resolver(source)
  local resolver = trim_string(source.resolver)
  if resolver == "" then
    return "local"
  end
  return resolver
end

local function normalize_possible_workspace(item)
  if type(item) == "string" then
    local name = trim_string(item)
    if name == "" then
      return nil
    end
    return {
      id = workspace_identity(name, nil, nil),
      name = name,
      cwd = nil,
      domain = nil,
      source = "user",
      is_active = false,
      is_open = false,
    }
  end

  if type(item) ~= "table" then
    return nil
  end

  local name = trim_string(item.name or item.label or item.id or item.cwd)
  if name == "" then
    return nil
  end

  local cwd = trim_string(item.cwd)
  if cwd == "" then
    cwd = nil
  end

  local domain = normalize_domain(item.domain)

  return {
    id = trim_string(item.id) ~= "" and trim_string(item.id) or workspace_identity(name, cwd, domain),
    name = name,
    cwd = cwd,
    domain = domain,
    source = "user",
    is_active = false,
    is_open = false,
  }
end

local function cached_known_workspaces(force_refresh)
  local switcher = switcher_state()
  local ttl = tonumber(switcher.cache_ttl_ms) or DEFAULT_CACHE_TTL_MS
  local current = now_ms()
  local fresh = switcher.cached_items ~= nil
    and ttl >= 0
    and (current - (switcher.cache_loaded_at_ms or 0)) <= ttl

  if not force_refresh and fresh then
    return util.clone_value(switcher.cached_items)
  end

  local seen = {}
  local items = {}
  for _, source in ipairs(configured_sources()) do
    local resolved_domain = source_domain_name(source)
    local resolver = source_resolver(source)
    if type(source.items) == "function" then
      local ok, result = pcall(source.items)
      if ok and type(result) == "table" then
        for _, raw in ipairs(result) do
          if type(raw) == "table" and raw.domain == nil then
            raw = util.clone_value(raw)
            raw.domain = resolved_domain
          end
          local item = normalize_possible_workspace(raw)
          if item ~= nil and item.id ~= "" and include_workspace_item(item) and not seen[item.id] then
            seen[item.id] = true
            items[#items + 1] = item
          end
        end
      end
    end

    if type(source.roots) == "table" then
      for _, root in ipairs(source.roots) do
        local scanned
        if resolver == "wsl" then
          scanned = scan_projects_in_wsl_root(source.name or source.domain or "", root)
        else
          scanned = scan_projects_in_root(root)
        end
        for _, raw in ipairs(scanned) do
          raw.domain = resolved_domain
          local item = normalize_possible_workspace(raw)
          if item ~= nil and item.id ~= "" and include_workspace_item(item) and not seen[item.id] then
            seen[item.id] = true
            items[#items + 1] = item
          end
        end
      end
    end
  end

  for _, raw in ipairs(configured_known_workspaces()) do
    local item = normalize_possible_workspace(raw)
    if item ~= nil and item.id ~= "" and include_workspace_item(item) and not seen[item.id] then
      seen[item.id] = true
      items[#items + 1] = item
    end
  end

  switcher.cached_items = util.clone_value(items)
  switcher.cache_loaded_at_ms = current
  return items
end

local function open_workspace_items()
  local items = {}
  for _, workspace in ipairs(hollow.term.workspaces()) do
    local domain = workspace.domain or current_domain_name()
    local id = workspace_identity(workspace.name, first_pane_cwd(workspace), domain)
    if id ~= "" then
      ensure_last_opened(workspace.name)
      local item = {
        id = id,
        name = workspace.name,
        cwd = first_pane_cwd(workspace),
        domain = domain,
        source = "open",
        is_active = workspace.is_active == true,
        is_open = true,
        open_index = workspace.index,
        last_opened_at = switcher_state().last_opened[id],
      }
      if include_workspace_item(item) then
        items[#items + 1] = item
      end
    end
  end

  return items
end

local function merged_workspace_items(force_refresh)
  register_workspace_listeners()

  local switcher = switcher_state()
  local merged = {}
  local seen = {}

  for _, workspace in ipairs(open_workspace_items()) do
    workspace.last_opened_at = workspace.last_opened_at
      or switcher.last_opened[workspace.id]
      or now_ms()
    merged[#merged + 1] = workspace
    seen[workspace.id] = workspace
  end

  for _, workspace in ipairs(cached_known_workspaces(force_refresh)) do
    if not seen[workspace.id] then
      workspace.last_opened_at = switcher.last_opened[workspace.id]
      merged[#merged + 1] = workspace
      seen[workspace.id] = workspace
    elseif seen[workspace.id].cwd == nil and workspace.cwd ~= nil then
      seen[workspace.id].cwd = workspace.cwd
    end
  end

  table.sort(merged, function(a, b)
    if a.is_open ~= b.is_open then
      return a.is_open
    end
    if a.is_active ~= b.is_active then
      return not a.is_active
    end

    local a_time = tonumber(a.last_opened_at) or 0
    local b_time = tonumber(b.last_opened_at) or 0
    if a_time ~= b_time then
      return a_time > b_time
    end
    return a.name < b.name
  end)

  return merged
end

local function default_format_item(workspace)
  local switcher = switcher_state()
  local name_color = workspace.is_active and ui_theme.open
    or (workspace.is_open and ui_theme.user or ui_theme.muted)
  local total_width = tonumber(switcher.width) or DEFAULT_SELECT_WIDTH
  local status_width = math.max(2, tonumber(switcher.status_column_width) or DEFAULT_STATUS_COLUMN_WIDTH)
  local name_width = math.max(12, tonumber(switcher.name_column_width) or DEFAULT_NAME_COLUMN_WIDTH)
  local gap_width = math.max(1, tonumber(switcher.column_gap) or DEFAULT_COLUMN_GAP)
  local cwd_width = math.max(12, total_width - status_width - name_width - (gap_width * 2) - 10)

  local function pad_right(value, width)
    value = tostring(value or "")
    if #value >= width then
      return value
    end
    return value .. string.rep(" ", width - #value)
  end

  local function truncate_end(value, width)
    value = tostring(value or "")
    if #value <= width then
      return value
    end
    if width <= 3 then
      return value:sub(1, width)
    end
    return value:sub(1, width - 3) .. "..."
  end

  local function truncate_start(value, width)
    value = tostring(value or "")
    if #value <= width then
      return value
    end
    if width <= 3 then
      return value:sub(#value - width + 1)
    end
    return "..." .. value:sub(#value - width + 4)
  end

  local name_text = pad_right(truncate_end(workspace.name, name_width), name_width)
  local status_text = workspace.is_active and ACTIVE_WORKSPACE_MARKER or " "
  local cwd_text = trim_string(workspace.cwd)
  if cwd_text == "" then
    cwd_text = workspace.is_active and "Current workspace"
      or (workspace.is_open and "Open workspace" or "Known workspace")
  end

  local domain = normalize_domain(workspace.domain)
  local current_domain = normalize_domain(current_domain_name())
  if domain ~= nil and domain ~= current_domain then
    cwd_text = "[" .. domain .. "] " .. cwd_text
  end

  cwd_text = truncate_start(cwd_text, cwd_width)

  return {
    ui.span(pad_right(status_text, status_width), { fg = workspace.is_active and ui_theme.open or ui_theme.subtle, bold = workspace.is_active }),
    ui.span(string.rep(" ", gap_width), { fg = ui_theme.subtle }),
    ui.span(name_text, { fg = name_color, bold = workspace.is_active }),
    ui.span(string.rep(" ", gap_width), { fg = ui_theme.subtle }),
    ui.span(cwd_text, { fg = ui_theme.subtle }),
  }
end

local function item_formatter()
  return switcher_state().format_item or default_format_item
end

local function workspace_badge_text()
  local current = hollow.term.current_workspace()
  local name = current and current.name or "workspace"
  return " ws: " .. name .. " "
end

local function detail_for_item(workspace)
  return nil
end

local open_new_workspace_from_item

local function switch_to_workspace(workspace)
  if type(workspace) ~= "table" then
    return
  end

  if workspace.is_open and workspace.open_index ~= nil then
    hollow.term.switch_workspace(workspace.open_index)
    if workspace.source == "user" and workspace.cwd ~= nil then
      send_cwd_to_active_workspace(workspace.cwd)
    end
    ensure_last_opened(workspace.name)
    return
  end

  open_new_workspace_from_item({
    name = workspace.name,
    cwd = workspace.cwd or current_pane_cwd(),
    domain = workspace.domain,
  })
end

open_new_workspace_from_item = function(item)
  local name = item and item.name or nil
  local cwd = item and item.cwd or nil
  local domain = item and item.domain or nil

  hollow.term.new_workspace({ cwd = cwd, domain = domain })
  if type(name) == "string" and name ~= "" then
    hollow.term.set_workspace_name(name)
    ensure_last_opened(name)
  else
    local current_name = active_workspace_name()
    if current_name then
      ensure_last_opened(current_name)
    end
  end
  if type(cwd) == "string" and cwd ~= "" then
    send_cwd_to_active_workspace(cwd)
  end
end

local function open_create_input(opts)
  opts = opts or {}
  ui.input.open({
    prompt = opts.prompt or "New workspace name",
    on_confirm = function(value)
      local name = trim_string(value)
      if name == "" then
        ui.notify.warn("Workspace name cannot be empty", { ttl = 1400 })
        return
      end
      open_new_workspace_from_item({ name = name })
      if type(opts.on_confirm) == "function" then
        opts.on_confirm(name)
      end
    end,
  })
end

local function open_rename_input(workspace, opts)
  opts = opts or {}
  local target = workspace or hollow.term.current_workspace()
  if type(target) ~= "table" or type(target.name) ~= "string" or target.name == "" then
    return
  end

  local current = hollow.term.current_workspace()
  local current_name = current and current.name or nil
  if target.name ~= current_name then
    ui.notify.warn("Rename works on the active workspace", { ttl = 1400 })
    return
  end

  ui.input.open({
    prompt = opts.prompt or "Rename workspace",
    default = target.name,
    on_confirm = function(value)
      local name = trim_string(value)
      if name == "" then
        ui.notify.warn("Workspace name cannot be empty", { ttl = 1400 })
        return
      end
      hollow.term.set_workspace_name(name)
      ensure_last_opened(name)
      if type(opts.on_confirm) == "function" then
        opts.on_confirm(name, target)
      end
    end,
  })
end

local function close_workspace(workspace)
  local target = workspace or hollow.term.current_workspace()
  if type(target) ~= "table" or target.is_open == false then
    return
  end

  local current = hollow.term.current_workspace()
  if current == nil or current.name ~= target.name then
    ui.notify.warn("Close works on the active workspace", { ttl = 1400 })
    return
  end

  hollow.term.close_workspace()
end

function ui.workspace.configure(opts)
  local switcher = switcher_state()
  opts = opts or {}

  if opts.known_workspaces ~= nil then
    switcher.known_workspaces = opts.known_workspaces
    switcher.cached_items = nil
    switcher.cache_loaded_at_ms = 0
  end
  if opts.sources ~= nil then
    switcher.sources = opts.sources
    switcher.cached_items = nil
    switcher.cache_loaded_at_ms = 0
  end
  if opts.format_item ~= nil then
    switcher.format_item = opts.format_item
  end
  if opts.filter_item ~= nil then
    switcher.filter_item = opts.filter_item
  end
  if opts.cache_ttl_ms ~= nil then
    switcher.cache_ttl_ms = opts.cache_ttl_ms
  end
  if opts.project_roots ~= nil then
    switcher.project_roots = opts.project_roots
    switcher.cached_items = nil
    switcher.cache_loaded_at_ms = 0
  end
  if opts.prompt ~= nil then
    switcher.prompt = opts.prompt
  end
  if opts.width ~= nil then
    switcher.width = opts.width
  end
  if opts.name_column_width ~= nil then
    switcher.name_column_width = opts.name_column_width
  end
  if opts.status_column_width ~= nil then
    switcher.status_column_width = opts.status_column_width
  end
  if opts.column_gap ~= nil then
    switcher.column_gap = opts.column_gap
  end
  if opts.height ~= nil then
    switcher.height = opts.height
  end
  if opts.max_height ~= nil then
    switcher.max_height = opts.max_height
  end
  if opts.backdrop ~= nil then
    switcher.backdrop = opts.backdrop
  end
  if opts.chrome ~= nil then
    switcher.chrome = opts.chrome
  end
  if opts.theme ~= nil then
    switcher.theme = opts.theme
  end
  if opts.rename_key ~= nil then
    switcher.rename_key = opts.rename_key
  end
  if opts.rename_desc ~= nil then
    switcher.rename_desc = opts.rename_desc
  end
  if opts.close_key ~= nil then
    switcher.close_key = opts.close_key
  end
  if opts.close_desc ~= nil then
    switcher.close_desc = opts.close_desc
  end
  if opts.create_key ~= nil then
    switcher.create_key = opts.create_key
  end
  if opts.create_desc ~= nil then
    switcher.create_desc = opts.create_desc
  end
end

function ui.workspace.clear_cache()
  local switcher = switcher_state()
  switcher.cached_items = nil
  switcher.cache_loaded_at_ms = 0
end

function ui.workspace.known_workspaces(force_refresh)
  return cached_known_workspaces(force_refresh == true)
end

function ui.workspace.items(force_refresh)
  return merged_workspace_items(force_refresh == true)
end

function ui.workspace.create(opts)
  open_create_input(opts)
end

function ui.workspace.rename(workspace, opts)
  open_rename_input(workspace, opts)
end

function ui.workspace.close(workspace)
  close_workspace(workspace)
end

function ui.workspace.open_switcher(opts)
  opts = opts or {}
  local force_refresh = opts.force_refresh == true
  opts.force_refresh = nil
  if next(opts) ~= nil then
    ui.workspace.configure(opts)
  end

  local switcher = switcher_state()

  local actions = {
    {
      name = "select",
      desc = "switch",
      fn = function(item)
        ui.select.close()
        switch_to_workspace(item)
      end,
    },
    {
      name = "rename",
      key = switcher.rename_key or DEFAULT_RENAME_KEY,
      desc = switcher.rename_desc or "rename",
      fn = function(item)
        ui.select.close()
        open_rename_input(item)
      end,
    },
    {
      name = "close",
      key = switcher.close_key or DEFAULT_CLOSE_KEY,
      desc = switcher.close_desc or "close",
      fn = function(item)
        ui.select.close()
        close_workspace(item)
      end,
    },
    {
      name = "new",
      key = switcher.create_key or DEFAULT_CREATE_KEY,
      desc = switcher.create_desc or "new",
      fn = function()
        ui.select.close()
        open_create_input()
      end,
    },
  }

  ui.select.open({
    prompt = switcher.prompt or DEFAULT_PROMPT,
    items = merged_workspace_items(force_refresh),
    width = switcher.width or DEFAULT_SELECT_WIDTH,
    height = switcher.height,
    max_height = switcher.max_height or DEFAULT_SELECT_MAX_HEIGHT,
    backdrop = switcher.backdrop,
    chrome = switcher.chrome,
    theme = switcher.theme,
    label = function(item)
      local formatter = item_formatter()
      return formatter(item)
    end,
    detail = detail_for_item,
    actions = actions,
  })
end

function ui.workspace.topbar_button(opts)
  opts = opts or {}
  return ui.button({
    id = opts.id or "workspace-switcher-button",
    text = opts.text or workspace_badge_text(),
    style = opts.style,
    on_click = function()
      ui.workspace.open_switcher(opts.switcher or {})
    end,
  })
end

ui.workspace.switcher = ui.workspace.open_switcher
