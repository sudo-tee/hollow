local state = require("hollow.state").get()
local util = require("hollow.util")

---@type Hollow
local hollow = _G.hollow
---@type HollowUi
local ui = hollow.ui

local M = {}

local DEFAULT_CACHE_TTL_MS = 5000

local function switcher_state()
  return state.ui.workspace_switcher
end

local function trim_string(value)
  if type(value) ~= "string" then
    return ""
  end

  return value:match("^%s*(.-)%s*$") or ""
end

local function notify_warn(message, ttl)
  local notify = ui.notify
  local warn = notify and notify.warn
  if type(warn) == "function" then
    warn(message, { ttl = ttl or 1800 })
  end
end

local function path_exists(path)
  path = trim_string(path)
  if path == "" then
    return false
  end

  local ok, result, code = os.rename(path, path)
  return ok or code == 13 or type(result) == "string"
end

local function safe_table_result(callback)
  if type(callback) ~= "function" then
    return nil
  end

  local ok, result = pcall(callback)
  if ok and type(result) == "table" then
    return result
  end

  return nil
end

local function normalized_list(value)
  return type(value) == "table" and value or {}
end

local function workspace_filter()
  local filter = switcher_state().filter_item
  return type(filter) == "function" and filter or nil
end

local function include_workspace_item(item)
  local filter = workspace_filter()
  if filter == nil then
    return true
  end

  local ok, allowed = pcall(filter, util.clone_value(item))
  return not ok or allowed ~= false
end

local function normalize_workspace_id(name)
  return trim_string(name):lower()
end

local function normalize_domain(value)
  local domain = trim_string(value)
  return domain ~= "" and domain or nil
end

local function current_domain_name()
  local pane = hollow.term.current_pane()
  return normalize_domain(pane and pane.domain)
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

local function first_pane_cwd(workspace)
  local panes = type(workspace) == "table" and workspace.panes or nil
  if type(panes) == "table" then
    for _, pane in ipairs(panes) do
      local cwd = trim_string(type(pane) == "table" and pane.cwd)
      if cwd ~= "" then
        return cwd
      end
    end
  end

  local pane = type(workspace) == "table" and workspace.pane or nil
  local cwd = trim_string(type(pane) == "table" and pane.cwd)
  return cwd ~= "" and cwd or nil
end

local function scan_projects_in_root(root)
  root = trim_string(root)
  if root == "" or not path_exists(root) then
    return {}
  end

  local entries = safe_table_result(function()
    return hollow.read_dir(root)
  end) or {}

  local items = {}
  for _, entry in ipairs(entries) do
    local cwd = trim_string(entry)
    local name = trim_string(util.basename(cwd))
    if name ~= "" and name:sub(1, 1) ~= "." and path_exists(cwd) then
      items[#items + 1] = {
        name = name,
        cwd = cwd,
      }
    end
  end

  return items
end

local function scan_projects_in_wsl_root(source_name, root)
  source_name = trim_string(source_name)
  root = trim_string(root)
  if source_name == "" or root == "" then
    return {}
  end

  local escaped_name = source_name:gsub('"', '\\"')
  local escaped_root = root:gsub('"', '\\"')
  local command = 'cmd.exe /c "wsl.exe -d '
    .. escaped_name
    .. ' -- ls -1A "'
    .. escaped_root
    .. '" 2>nul"'
  local pipe = io.popen(command)
  if pipe == nil then
    notify_warn("Workspace source failed: wsl " .. source_name)
    return {}
  end

  local items = {}
  for line in pipe:lines() do
    local name = trim_string(line)
    local cwd = name ~= "" and util.join_path(root, name) or ""
    if cwd ~= "" then
      items[#items + 1] = {
        name = name,
        cwd = cwd,
      }
    end
  end
  pipe:close()

  if #items == 0 then
    notify_warn("Workspace source returned no folders: wsl " .. source_name)
  end

  return items
end

local function scan_projects_in_ssh_root(domain, root)
  domain = trim_string(domain)
  root = trim_string(root)
  if domain == "" or root == "" then
    return {}
  end

  local ok, stdout, stderr = hollow.term.run_domain_process({ "ls", "-1Ap", root }, domain)
  if not ok then
    local detail = trim_string(stderr)
    notify_warn(detail ~= "" and ("Workspace source failed: " .. detail) or ("Workspace source failed: ssh " .. domain))
    return {}
  end

  local items = {}
  for line in stdout:gmatch("[^\r\n]+") do
    local raw_name = trim_string(line)
    local is_dir = raw_name:sub(-1) == "/"
    local name = is_dir and raw_name:sub(1, -2) or raw_name
    local cwd = name ~= "" and util.join_path(root, name) or ""
    local basename = trim_string(util.basename(cwd))
    if is_dir and basename ~= "" and basename:sub(1, 1) ~= "." then
      items[#items + 1] = {
        name = basename,
        cwd = cwd,
        domain = domain,
      }
    end
  end

  if #items == 0 then
    notify_warn("Workspace source returned no folders: ssh " .. domain)
  end

  return items
end

local function default_known_workspaces()
  local domain = current_domain_name()
  local merged = {}
  local seen = {}

  for _, root in ipairs(normalized_list(switcher_state().project_roots)) do
    for _, item in ipairs(scan_projects_in_root(root)) do
      local id = workspace_identity(item.name, item.cwd, domain)
      if not seen[id] then
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

local function configured_known_workspaces()
  return safe_table_result(switcher_state().known_workspaces or default_known_workspaces) or {}
end

local function configured_sources()
  local sources = switcher_state().sources
  return safe_table_result(sources) or normalized_list(sources)
end

local function source_domain_name(source)
  return normalize_domain(source.domain) or current_domain_name()
end

local function source_resolver(source)
  local resolver = trim_string(source.resolver)
  return resolver ~= "" and resolver or "local"
end

local function wsl_unc_to_linux_path(path)
  local normalized = trim_string(path):gsub("\\", "/")
  if normalized == "" then
    return nil
  end

  return normalized:match("^//wsl%$/[^/]+(/.*)$") or normalized:match("^//wsl%.localhost/[^/]+(/.*)$")
end

local function resolve_source_item_cwd(source, item)
  local resolver = source.cwd_resolver
  local cwd = trim_string(item.cwd)
  if resolver == nil or cwd == "" then
    return item
  end

  local clone = util.clone_value(item)
  if resolver == "wsl_unc" then
    clone.cwd = wsl_unc_to_linux_path(cwd) or cwd
    return clone
  end

  if type(resolver) ~= "function" then
    return item
  end

  local ok, resolved = pcall(resolver, cwd, util.clone_value(clone), util.clone_value(source))
  if not ok then
    return item
  end

  if type(resolved) == "string" then
    resolved = trim_string(resolved)
    clone.cwd = resolved ~= "" and resolved or nil
  elseif resolved == nil then
    clone.cwd = nil
  end

  return clone
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
  cwd = cwd ~= "" and cwd or nil

  local id = trim_string(item.id)
  return {
    id = id ~= "" and id or workspace_identity(name, cwd, item.domain),
    name = name,
    cwd = cwd,
    domain = normalize_domain(item.domain),
    source = trim_string(item.source) ~= "" and trim_string(item.source) or "user",
    is_active = false,
    is_open = false,
  }
end

local function source_workspace_item(raw, source, resolved_domain)
  if type(raw) == "table" then
    raw = util.clone_value(raw)
    raw.domain = raw.domain or resolved_domain
    raw.source = raw.source or source_resolver(source)
    raw = resolve_source_item_cwd(source, raw)
  end

  return normalize_possible_workspace(raw)
end

local function append_unique(items, seen, item)
  if item == nil or item.id == "" or seen[item.id] or not include_workspace_item(item) then
    return
  end

  seen[item.id] = true
  items[#items + 1] = item
end

local function ensure_last_opened(name, timestamp)
  local id = normalize_workspace_id(name)
  if id == "" then
    return
  end

  local switcher = switcher_state()
  local value = tonumber(timestamp) or util.host_now_ms(state.host_api)
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

  local events = hollow.events
  local on = events and events.on
  if type(on) ~= "function" then
    return
  end

  local function touch_current_workspace()
    local workspace = hollow.term.current_workspace()
    local name = trim_string(workspace and workspace.name)
    if name ~= "" then
      ensure_last_opened(name)
    end
  end

  on("term:tab_activated", touch_current_workspace)
  on("term:cwd_changed", touch_current_workspace)
  on("term:title_changed", touch_current_workspace)
  on("term:tab_closed", touch_current_workspace)
  touch_current_workspace()

  switcher.listeners_registered = true
end

local function cached_known_workspaces(force_refresh)
  local switcher = switcher_state()
  local ttl = tonumber(switcher.cache_ttl_ms) or DEFAULT_CACHE_TTL_MS
  local current = util.host_now_ms(state.host_api)
  local fresh = switcher.cached_items ~= nil
    and ttl >= 0
    and (current - (switcher.cache_loaded_at_ms or 0)) <= ttl

  if not force_refresh and fresh then
    return util.clone_value(switcher.cached_items)
  end

  local items = {}
  local seen = {}

  for _, source in ipairs(configured_sources()) do
    if source.default ~= false then
      local resolved_domain = source_domain_name(source)
      local resolver = source_resolver(source)

      for _, raw in ipairs(safe_table_result(source.items) or {}) do
        append_unique(items, seen, source_workspace_item(raw, source, resolved_domain))
      end

      for _, root in ipairs(normalized_list(source.roots)) do
        local scanned = resolver == "wsl" and scan_projects_in_wsl_root(source.name or source.domain or "", root)
          or resolver == "ssh" and scan_projects_in_ssh_root(resolved_domain, root)
          or scan_projects_in_root(root)

        for _, raw in ipairs(scanned) do
          append_unique(items, seen, source_workspace_item(raw, source, resolved_domain))
        end
      end
    end
  end

  for _, raw in ipairs(configured_known_workspaces()) do
    append_unique(items, seen, normalize_possible_workspace(raw))
  end

  switcher.cached_items = util.clone_value(items)
  switcher.cache_loaded_at_ms = current
  return items
end

local function open_workspace_items()
  local items = {}
  for _, workspace in ipairs(hollow.term.workspaces()) do
    local cwd = first_pane_cwd(workspace)
    local domain = workspace.domain or current_domain_name()
    local id = workspace_identity(workspace.name, cwd, domain)
    ensure_last_opened(workspace.name)

    local item = {
      id = id,
      name = workspace.name,
      cwd = cwd,
      domain = domain,
      source = "open",
      is_active = workspace.is_active == true,
      is_open = true,
      open_index = workspace.index,
      last_opened_at = switcher_state().last_opened[id],
    }

    if id ~= "" and include_workspace_item(item) then
      items[#items + 1] = item
    end
  end

  return items
end

local function merged_workspace_items(force_refresh)
  register_workspace_listeners()

  local switcher = switcher_state()
  local merged = {}
  local seen = {}
  local now = util.host_now_ms(state.host_api)

  for _, workspace in ipairs(open_workspace_items()) do
    workspace.last_opened_at = workspace.last_opened_at or switcher.last_opened[workspace.id] or now
    merged[#merged + 1] = workspace
    seen[workspace.id] = workspace
  end

  for _, workspace in ipairs(cached_known_workspaces(force_refresh)) do
    local existing = seen[workspace.id]
    if existing == nil then
      workspace.last_opened_at = switcher.last_opened[workspace.id]
      merged[#merged + 1] = workspace
      seen[workspace.id] = workspace
    elseif existing.cwd == nil and workspace.cwd ~= nil then
      existing.cwd = workspace.cwd
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

function M.trim_string(value)
  return trim_string(value)
end

function M.normalize_domain(value)
  return normalize_domain(value)
end

function M.current_domain_name()
  return current_domain_name()
end

function M.workspace_identity(name, cwd, domain)
  return workspace_identity(name, cwd, domain)
end

function M.source_domain_name(source)
  return source_domain_name(source)
end

function M.source_workspace_item(raw, source, resolved_domain)
  return source_workspace_item(raw, source, resolved_domain)
end

function M.find_source(name)
  name = trim_string(name)
  if name == "" then
    return nil
  end

  for _, source in ipairs(configured_sources()) do
    if trim_string(source.name) == name or trim_string(source.domain) == name then
      return source
    end
  end

  return nil
end

function M.ensure_last_opened(name, timestamp)
  ensure_last_opened(name, timestamp)
end

function M.configure(opts)
  opts = opts or {}
  local switcher = switcher_state()
  local invalidate = util.has_any_key(opts, { "known_workspaces", "sources", "project_roots" })
  util.merge_tables(switcher, opts)
  if invalidate then
    switcher.cached_items = nil
    switcher.cache_loaded_at_ms = 0
  end
end

function M.clear_cache()
  local switcher = switcher_state()
  switcher.cached_items = nil
  switcher.cache_loaded_at_ms = 0
end

function M.known_workspaces(force_refresh)
  return cached_known_workspaces(force_refresh == true)
end

function M.items(force_refresh)
  return merged_workspace_items(force_refresh == true)
end

function M.switcher_state()
  return switcher_state()
end

return M
