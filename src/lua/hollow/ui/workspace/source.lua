local program_status = require("hollow.program_status")
local state = require("hollow.state").get()
local util = require("hollow.util")
local compat = require("hollow.ui.workspace.compat")
local hosts = require("hollow.ui.workspace.hosts")

---@type Hollow
local hollow = _G.hollow
---@type HollowUi
local ui = hollow.ui

local M = {}

local DEFAULT_CACHE_TTL_MS = 5000
local HOST_PAGE_SIZE = 256
local HOST_ENTRY_LIMIT = 4096
local HOST_STAT_CONCURRENCY = 4

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
  notify.warn(message, { ttl = ttl or 1800 })
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
  local normalized_name = normalize_workspace_id(name)
  local normalized_cwd = trim_string(cwd)

  if normalized_cwd ~= "" and normalized_name ~= "" then
    return normalized_domain .. ":" .. normalized_name .. ":" .. normalized_cwd
  end

  if normalized_cwd ~= "" then
    return normalized_domain .. ":" .. normalized_cwd
  end

  if normalized_name ~= "" then
    return normalized_domain .. ":name:" .. normalized_name
  end

  return normalized_domain .. ":workspace"
end

local function first_pane_cwd(workspace)
  local pane = type(workspace) == "table" and workspace.pane or nil
  local cwd = trim_string(type(pane) == "table" and pane.cwd)
  if cwd ~= "" then return cwd end
  -- mux_tree nests panes under tabs, not directly under the workspace.
  for _, tab in ipairs(workspace.tabs or {}) do
    if tab.is_active then
      local active_cwd = first_pane_cwd(tab)
      if active_cwd then return active_cwd end
    end
  end
  for _, tab in ipairs(workspace.tabs or {}) do
    local cwd = first_pane_cwd(tab)
    if cwd then return cwd end
  end
  local panes = type(workspace) == "table" and workspace.panes or nil
  if type(panes) == "table" then
    for _, pane in ipairs(panes) do
      local cwd = trim_string(type(pane) == "table" and pane.cwd)
      if cwd ~= "" then
        return cwd
      end
    end
  end

  return nil
end

local function workspace_name_key(name, domain)
  local normalized_name = normalize_workspace_id(name)
  if normalized_name == "" then
    return nil
  end

  local normalized_domain = normalize_domain(domain) or current_domain_name() or "default"
  return normalized_domain .. ":name:" .. normalized_name
end

local function configured_known_workspaces()
  return safe_table_result(switcher_state().known_workspaces) or {}
end

local function configured_sources()
  local switcher = switcher_state()
  local raw = safe_table_result(switcher.sources) or normalized_list(switcher.sources)
  local sources = {}
  for _, value in ipairs(raw) do
    if type(value) == "table" then
      local source, err = compat.source(value)
      if source then sources[#sources + 1] = source else compat.warn_invalid(value, err) end
    end
  end
  if switcher.known_workspaces == nil and #normalized_list(switcher.project_roots) > 0 then
    local raw_source = compat.project_roots(switcher.project_roots)
    local source, err = compat.source(raw_source)
    if source then sources[#sources + 1] = source else compat.warn_invalid(raw_source, err) end
  end
  return hosts.prepare(sources)
end

local function source_domain_name(source)
  return normalize_domain(source.domain) or current_domain_name()
end

local function host_key(source)
  local host = source.host
  if type(host) ~= "table" or type(host.fs) ~= "table" or type(host.fs.list) ~= "function" then
    return nil
  end
  return tostring(host.id or "") .. "\0" .. tostring(host.generation or "")
end

local function explicit_host(source)
  return source.host ~= nil
end

local function host_signature(sources)
  local parts = {}
  local function append(value)
    local text = tostring(value)
    parts[#parts + 1] = tostring(#text) .. ":" .. text
  end
  for index, source in ipairs(sources) do
    if explicit_host(source) then
      local host = source.host
      append(index); append(type(host) == "table" and host.id or "")
      append(type(host) == "table" and host.generation or "")
      append(source.domain or ""); append(source._legacy_cwd)
      append(source.default); append(source.name or "")
      append(#normalized_list(source.roots))
      for _, root in ipairs(normalized_list(source.roots)) do
        append(type(root)); append(root)
      end
    end
  end
  return table.concat(parts)
end

local function join_host_path(root, name)
  if root:sub(-1) == "/" then return root .. name end
  return root .. "/" .. name
end

local function valid_host_name(name)
  return type(name) == "string" and name ~= "" and name ~= "." and name ~= ".."
    and not name:find("/", 1, true) and not name:find("\0", 1, true)
end

local function promise_next(promise, resolve, reject)
  if type(promise) ~= "table" or type(promise.next) ~= "function" then
    reject("host fs API did not return a promise")
    return
  end
  local settled = false
  local ok, err = pcall(promise.next, promise, function(value)
    if settled then return end
    settled = true
    resolve(value)
  end, function(reason)
    if settled then return end
    settled = true
    reject(reason)
  end)
  if not ok and not settled then settled = true; reject(err) end
end

local function invalidate_host_scan()
  local s = switcher_state()
  s.host_scan_generation = (s.host_scan_generation or 0) + 1
  for promise in pairs(s.host_scan_active or {}) do
    if type(promise.cancel) == "function" then pcall(promise.cancel, promise) end
  end
  s.host_scan_active = {}
  s.host_scan_cache = nil
  s.host_scan_pending = nil
  s.host_scan_signature = nil
end

local function start_host_scan(sources, signature)
  local switcher = switcher_state()
  if switcher.host_scan_pending then return end
  local generation = switcher.host_scan_generation or 0
  local scans = {}
  for index, source in ipairs(sources) do
    if source.default ~= false and explicit_host(source) and not source._host_pending and #normalized_list(source.roots) > 0 then
      scans[#scans + 1] = { source = source, key = host_key(source), index = index }
    end
  end
  if #scans == 0 then return end
  switcher.host_scan_pending = true
  switcher.host_scan_signature = signature
  switcher.host_scan_active = switcher.host_scan_active or {}
  local combined = {}
  local warned = false
  local function warn_host_scan()
    if warned then return end
    warned = true
    notify_warn("Workspace host scan failed")
  end
  local scan_index = 0
  local function current()
    local s = switcher_state()
    return (s.host_scan_generation or 0) == generation and s.host_scan_signature == signature
      and host_signature(configured_sources()) == signature
  end
  local function defer(fn)
    local api = state.host_api
    if type(api) == "table" and type(api.defer) == "function" then
      local ok = pcall(api.defer, fn)
      if ok then return end
    end
    fn()
  end
  local function observe(promise, resolve, reject)
    if type(promise) == "table" then switcher_state().host_scan_active[promise] = true end
    promise_next(promise, function(value)
      if type(promise) == "table" then switcher_state().host_scan_active[promise] = nil end
      resolve(value)
    end, function(err)
      if type(promise) == "table" then switcher_state().host_scan_active[promise] = nil end
      reject(err)
    end)
  end
  local function finish_scan()
    if not current() then return end
    scan_index = scan_index + 1
    local scan = scans[scan_index]
    if not scan then
      local s = switcher_state()
      s.host_scan_cache = { generation = generation, signature = signature,
        loaded_at = util.host_now_ms(state.host_api), items = combined }
      s.host_scan_pending = nil
      s.host_scan_revision = (s.host_scan_revision or 0) + 1
      return
    end
    local source, host = scan.source, scan.source.host
    if not host_key(source) then
      warn_host_scan()
      finish_scan()
      return
    end
    local domain = source_domain_name(source)
    local roots = normalized_list(source.roots)
    local root_index = 0
    local function next_root()
      if not current() then return end
      root_index = root_index + 1
      local root = roots[root_index]
      if type(root) ~= "string" or root == "" then
        if root_index > #roots then finish_scan() else next_root() end
        return
      end
      local offset, count, entries = 0, 0, {}
      local function page()
        if not current() then return end
        local ok, promise = pcall(host.fs.list, root, { offset = offset, limit = HOST_PAGE_SIZE })
        if not ok then warn_host_scan(); next_root(); return end
        observe(promise, function(page_result)
          if not current() then return end
          local names = type(page_result) == "table" and page_result.entries or nil
          if type(names) ~= "table" or #names > HOST_PAGE_SIZE or type(page_result.eof) ~= "boolean" then
            warn_host_scan(); next_root(); return
          end
          for _, entry in ipairs(names) do
            local name = type(entry) == "table" and entry.name or entry
            count = count + 1
            if count <= HOST_ENTRY_LIMIT and valid_host_name(name) then
              entries[#entries + 1] = name
            end
          end
          local old_offset = offset
          local next_offset = page_result.next_offset
          local more = page_result.eof == false
          if more and (#names == 0 or type(next_offset) ~= "number" or next_offset % 1 ~= 0 or next_offset <= old_offset or next_offset > 1000000) then
            warn_host_scan(); next_root(); return
          end
          offset = more and next_offset or old_offset + #names
          if more and count < HOST_ENTRY_LIMIT then defer(page) else
            local cursor, active = 1, 0
            local root_finished = false
            local function pump()
              if not current() or root_finished then return end
              while active < HOST_STAT_CONCURRENCY and cursor <= #entries do
                local name = entries[cursor]; cursor = cursor + 1; active = active + 1
                local path = join_host_path(root, name)
                local good, stat_promise = pcall(host.fs.stat, path)
                if not good then
                  warn_host_scan()
                  active = active - 1
                  if cursor <= #entries then defer(pump) elseif active == 0 then root_finished = true; next_root() end
                else
                  observe(stat_promise, function(stat)
                    if not current() then return end
                    if type(stat) == "table" and stat.kind == "directory" and name:sub(1, 1) ~= "." then
                      combined[#combined + 1] = { name = name, cwd = path, domain = domain,
                        _host_key = scan.key, _host_source_index = scan.index }
                    end
                    active = active - 1
                    if cursor <= #entries then defer(pump) elseif active == 0 and not root_finished then root_finished = true; next_root() end
                  end, function()
                    if not current() then return end
                    warn_host_scan()
                    active = active - 1
                    if cursor <= #entries then defer(pump) elseif active == 0 and not root_finished then root_finished = true; next_root() end
                  end)
                end
              end
              if cursor > #entries and active == 0 and not root_finished then root_finished = true; next_root() end
            end
            defer(pump)
          end
        end, function()
          if current() then warn_host_scan(); next_root() end
        end)
      end
      page()
    end
    next_root()
  end
  finish_scan()
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
      has_bell = false,
    }
  end

  if type(item) ~= "table" then
    return nil
  end

  local name = trim_string(item.name or item.label or item.id or item.cwd)
  local host_identity = type(item._host_key) == "string" and item._host_key or nil
  if host_identity then
    name = type(item.name) == "string" and item.name or name
    if name == "" then return nil end
    local cwd = type(item.cwd) == "string" and item.cwd or nil
    return {
      id = "host:" .. host_identity .. "\0" .. tostring(item._host_id or "") .. "\0"
        .. workspace_identity(name, cwd, item.domain) .. "\0" .. tostring(cwd or ""),
      name = name,
      cwd = cwd,
      domain = normalize_domain(item.domain),
      source = "host",
      host_id = host_identity,
      is_active = false,
      is_open = false,
      has_bell = false,
    }
  end
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
    has_bell = false,
  }
end

local function source_workspace_item(raw, source, resolved_domain)
  raw = compat.item(source, raw)
  if type(raw) == "table" then
    raw = util.clone_value(raw)
    raw.domain = raw.domain or resolved_domain
    raw.source = raw.source or "host"
    if host_key(source) then
      raw._host_key = raw._host_key or host_key(source)
    end
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

local function remember_workspace_cwd(name, cwd, domain)
  cwd = trim_string(cwd)
  if cwd == "" then
    return
  end

  local key = workspace_name_key(name, domain)
  if key == nil then
    return
  end

  switcher_state().remembered_cwds[key] = cwd
end

local function remembered_workspace_cwd(name, domain)
  local key = workspace_name_key(name, domain)
  if key == nil then
    return nil
  end

  local cwd = trim_string(switcher_state().remembered_cwds[key])
  return cwd ~= "" and cwd or nil
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
    local pane = hollow.term.current_pane()
    local domain = workspace and workspace.domain or (pane and pane.domain)
    remember_workspace_cwd(name, pane and pane.cwd, domain)
    if name ~= "" then
      ensure_last_opened(name)
    end
  end

  on("workspace:new", touch_current_workspace)
  on("workspace:changed", touch_current_workspace)
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
  local sources = configured_sources()
  local signature = host_signature(sources)
  local has_host_source = false
  for _, source in ipairs(sources) do
    if explicit_host(source) and source.default ~= false then has_host_source = true; break end
  end
  if switcher.host_signature ~= signature then
    invalidate_host_scan()
    switcher.cached_items = nil
    switcher.cache_loaded_at_ms = 0
    switcher.host_signature = signature
  end
  if switcher.host_scan_cache and switcher.host_scan_cache.signature ~= signature then
    invalidate_host_scan()
    switcher.cached_items = nil
    switcher.cache_loaded_at_ms = 0
  end
  local host_fresh = switcher.host_scan_cache ~= nil and ttl >= 0
    and switcher.host_scan_cache.signature == signature
    and current - (switcher.host_scan_cache.loaded_at or 0) <= ttl
  local revision_changed = (switcher.cached_host_revision or -1) ~= (switcher.host_scan_revision or 0)
  local fresh = switcher.cached_items ~= nil
    and ttl >= 0
    and (current - (switcher.cache_loaded_at_ms or 0)) <= ttl
    and not revision_changed
    and (not has_host_source or host_fresh or switcher.host_scan_pending)

  if not force_refresh and fresh then
    return util.clone_value(switcher.cached_items)
  end
  if force_refresh then invalidate_host_scan(); host_fresh = false end

  local items = {}
  local seen = {}
  if #sources > 0 and not host_fresh then start_host_scan(sources, signature) end
  for source_index, source in ipairs(sources) do
    if source.default ~= false then
      local resolved_domain = source_domain_name(source)

      for _, raw in ipairs(safe_table_result(source.items) or {}) do
        append_unique(items, seen, source_workspace_item(raw, source, resolved_domain))
      end

      local host_id = host_key(source)
      local host_result = switcher.host_scan_cache
      if explicit_host(source) and host_result and host_result.signature == signature then
        for _, raw in ipairs(host_result.items) do
          if raw._host_source_index == source_index and raw._host_key == host_id then
            append_unique(items, seen, source_workspace_item(raw, source, resolved_domain))
          end
        end
      end
    end
  end

  for _, raw in ipairs(configured_known_workspaces()) do
    append_unique(items, seen, normalize_possible_workspace(raw))
  end

  switcher.cached_items = util.clone_value(items)
  switcher.cache_loaded_at_ms = current
  switcher.cached_host_revision = switcher.host_scan_revision or 0
  return items
end

local function open_workspace_items()
  local items = {}
  for _, workspace in ipairs(hollow.term.mux_tree()) do
    local domain = workspace.domain or current_domain_name()
    local cwd = first_pane_cwd(workspace) or remembered_workspace_cwd(workspace.name, domain)
    local id = workspace_identity(workspace.name, cwd, domain)
    ensure_last_opened(workspace.name)
    remember_workspace_cwd(workspace.name, cwd, domain)

    local badge, status_state = program_status.workspace_badge(workspace)
    local item = {
      id = id,
      workspace_id = workspace.id,
      name = workspace.name,
      cwd = cwd,
      domain = domain,
      source = "open",
      is_active = workspace.is_active == true,
      is_open = true,
      program_status_badge = badge,
      program_status_state = status_state,
      program_status_attention = program_status.workspace_needs_attention(workspace),
      program_status_attention_level = program_status.workspace_attention_level(workspace),
      has_bell = hollow.tbl(workspace.tabs):some(function(tab)
        return hollow.tbl(tab.panes):some(function(pane)
          return pane.has_bell
        end)
      end),
      open_index = workspace.index,
      last_opened_at = switcher_state().last_opened[id],
    }

    if id ~= "" and include_workspace_item(item) then
      items[#items + 1] = item
    end
  end

  table.sort(items, function(a, b)
    local a_attention = a.has_bell or a.program_status_attention == true
    local b_attention = b.has_bell or b.program_status_attention == true
    if a_attention ~= b_attention then
      return a_attention
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
    seen[workspace_identity(workspace.name, nil, workspace.domain)] = workspace
  end

  for _, workspace in ipairs(cached_known_workspaces(force_refresh)) do
    local existing = seen[workspace.id]
    if existing == nil and workspace.host_id == nil then
      existing = seen[workspace_identity(workspace.name, nil, workspace.domain)]
    end
    if existing == nil then
      workspace.last_opened_at = switcher.last_opened[workspace.id]
      merged[#merged + 1] = workspace
      seen[workspace.id] = workspace
      if workspace.host_id == nil then
        seen[workspace_identity(workspace.name, nil, workspace.domain)] = workspace
      end
    elseif existing.cwd == nil and workspace.cwd ~= nil then
      existing.cwd = workspace.cwd
    end
  end

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

function M.remember_workspace_cwd(name, cwd, domain)
  remember_workspace_cwd(name, cwd, domain)
end

function M.configure(opts)
  opts = opts or {}
  local switcher = switcher_state()
  local invalidate = util.has_any_key(opts, { "known_workspaces", "sources", "project_roots" })
  util.merge_tables(switcher, opts)
  if type(opts.sources) == "table" then switcher.sources = opts.sources end
  if type(opts.project_roots) == "table" then switcher.project_roots = opts.project_roots end
  if invalidate then
    invalidate_host_scan()
    switcher.cached_items = nil
    switcher.cache_loaded_at_ms = 0
    switcher.host_signature = host_signature(configured_sources())
  end
end

function M.clear_cache()
  local switcher = switcher_state()
  invalidate_host_scan()
  hosts.retry()
  switcher.cached_items = nil
  switcher.cache_loaded_at_ms = 0
  switcher.host_signature = host_signature(configured_sources())
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
