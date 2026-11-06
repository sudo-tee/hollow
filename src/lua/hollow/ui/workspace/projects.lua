-- SSH project discovery is explicit, independent of local scans and sessions.
local M = {}
---@type Hollow
local hollow = _G.hollow
local hosts = require("hollow.workspace.hosts")
local util = require("hollow.util")
---@class HollowWorkspaceProjectLoad
---@field status "idle"|"loading"|"ready"|"failed"
---@field generation integer
---@field items HollowUiWorkspaceItem[]
---@field active table<HollowPromise, boolean>
---@field release? fun()
---@field signature? string
---@field error? string
---@field started? number
---@field deadline? number

---@type table<string, HollowWorkspaceProjectLoad>
local domains = {}
local PAGE, LIMIT, CONCURRENCY, MAX_DOMAINS = 256, 4096, 4, 64
local LOAD_LABELS = {
  idle = "Load projects",
  loading = "Loading projects…",
  failed = "Projects unavailable",
  ready = "No projects",
}
local LOAD_BADGES = { idle = "remote", loading = "loading", failed = "retry", ready = "refresh" }

local function source()
  return require("hollow.ui.workspace.source")
end

local function now()
  return util.host_now_ms(require("hollow.state").get().host_api)
end

local function changed()
  hollow.events.emit("workspace:items_changed", {})
end

---@param entry HollowWorkspaceProjectLoad
local function cleanup(entry)
  local active, release = entry.active, entry.release
  entry.active, entry.release = {}, nil
  for promise in pairs(active) do
    if type(promise.cancel) == "function" then
      pcall(promise.cancel, promise)
    end
  end
  if release then
    release()
  end
end

---@param name string
---@return HollowWorkspaceProjectLoad|nil
local function state(name)
  if not domains[name] then
    local count = 0
    for _ in pairs(domains) do
      count = count + 1
    end
    if count >= MAX_DOMAINS then
      return nil
    end
    domains[name] = { status = "idle", items = {}, generation = 0, active = {} }
  end
  return domains[name]
end

local function signature(sources)
  local values = {}
  for _, config in ipairs(sources) do
    values[#values + 1] = {
      host = config._ssh_spec,
      roots = config.roots,
      name = config.name,
      domain = config.domain,
      items = tostring(config.items),
      transform = tostring(config._legacy_cwd),
    }
  end
  return hosts._key(values)
end

local function reconcile()
  local configured = {}
  for _, config in ipairs(source().remote_sources()) do
    configured[config.domain] = configured[config.domain] or {}
    table.insert(configured[config.domain], config)
  end
  for name, entry in pairs(domains) do
    if
      not configured[name] or (entry.signature and entry.signature ~= signature(configured[name]))
    then
      entry.generation = entry.generation + 1
      cleanup(entry)
      domains[name] = nil
    end
  end
end

---@param name string
---@return boolean, string?
function M.load(name)
  reconcile()
  local sources = {}
  for _, item in ipairs(source().remote_sources()) do
    if item.domain == name then
      sources[#sources + 1] = item
    end
  end
  if #sources == 0 then
    return false
  end
  local entry = state(name)
  if not entry then
    return false, "ResourceExhausted"
  end
  if entry.status == "loading" then
    return true
  end
  entry.generation = entry.generation + 1
  entry.signature = signature(sources)
  local generation = entry.generation
  local function current()
    return domains[name] == entry and entry.generation == generation
  end
  entry.status, entry.error, entry.started = "loading", nil, now()
  local timeout = tonumber(source().switcher_state().load_timeout_ms) or 15000
  entry.deadline = entry.started + math.max(1000, math.min(300000, timeout))
  changed()
  hollow.async.run(function()
    local items, count = {}, 0
    ---@generic T
    ---@param promise HollowPromise<T>
    ---@return T
    local function await(promise)
      if not current() then
        error("Canceled")
      end
      entry.active[promise] = true
      local result = hollow.async.await(function(resolve, reject)
        promise:next(resolve, reject)
      end)
      entry.active[promise] = nil
      if not current() then
        error("Canceled")
      end
      return result
    end
    local function scan()
      for _, config in ipairs(sources) do
        local host
        local release = function() end
        if #(config.roots or {}) > 0 then
          hosts.retry(config._ssh_spec)
          local promise
          promise, release = hosts.acquire(config._ssh_spec)
          entry.release = release
          host = await(promise)
          config.host = host
        end
        for _, root in ipairs(config.roots or {}) do
          if type(root) ~= "string" or root == "" then
            error("Invalid project root")
          end
          local offset, names = 0, {}
          while true do
            local page = await(host.fs.list(root, { offset = offset, limit = PAGE }))
            if
              type(page) ~= "table"
              or type(page.entries) ~= "table"
              or #page.entries > PAGE
              or type(page.eof) ~= "boolean"
            then
              error("Invalid directory page")
            end
            for _, value in ipairs(page.entries) do
              count = count + 1
              if count > LIMIT then
                error("ResourceExhausted")
              end
              local child = type(value) == "table" and value.name or value
              if
                type(child) == "string"
                and child ~= ""
                and child:sub(1, 1) ~= "."
                and not child:find("/", 1, true)
                and not child:find("\0", 1, true)
              then
                names[#names + 1] = child
              end
            end
            if page.eof then
              break
            end
            local next_offset = page.next_offset
            if
              #page.entries == 0
              or type(next_offset) ~= "number"
              or next_offset % 1 ~= 0
              or next_offset <= offset
              or next_offset > 1000000
            then
              error("Invalid directory cursor")
            end
            offset = next_offset
          end
          for start = 1, #names, CONCURRENCY do
            local batch = {}
            for index = start, math.min(#names, start + CONCURRENCY - 1) do
              local path = root .. (root:sub(-1) == "/" and "" or "/") .. names[index]
              batch[#batch + 1] = { name = names[index], cwd = path, promise = host.fs.stat(path) }
              entry.active[batch[#batch].promise] = true
            end
            for _, value in ipairs(batch) do
              if await(value.promise).kind == "directory" then
                items[#items + 1] = source().source_workspace_item(
                  { name = value.name, cwd = value.cwd },
                  config,
                  name
                )
              end
            end
          end
        end
        if type(config.items) == "function" then
          for _, value in ipairs(config.items() or {}) do
            if #items >= LIMIT then
              error("ResourceExhausted")
            end
            items[#items + 1] = source().source_workspace_item(value, config, name)
          end
        end
        entry.release = nil
        release()
      end
    end
    local ok, err = pcall(scan)
    if not current() then
      return
    end
    cleanup(entry)
    if ok then
      entry.status, entry.items = "ready", items
    else
      entry.status = "failed"
      entry.error = type(err) == "table" and (err.message or err.code) or tostring(err)
    end
    changed()
  end)
  return true
end

function M.tick()
  reconcile()
  for _, entry in pairs(domains) do
    if entry.status == "loading" and now() >= entry.deadline then
      entry.generation = entry.generation + 1
      entry.status, entry.error = "failed", "Project discovery timed out"
      cleanup(entry)
      changed()
    end
  end
end

function M.loading()
  for _, entry in pairs(domains) do
    if entry.status == "loading" then
      return true
    end
  end
  return false
end

function M.items()
  M.tick()
  local items = {}
  for _, entry in pairs(domains) do
    for _, item in ipairs(entry.items) do
      items[#items + 1] = item
    end
  end
  table.sort(items, function(a, b)
    return a.id < b.id
  end)
  return items
end

function M.status_items()
  M.tick()
  local items, seen = {}, {}
  for _, config in ipairs(source().remote_sources()) do
    local name = config.domain
    if not seen[name] then
      seen[name] = true
      local entry = state(name) or { status = "failed", error = "ResourceExhausted", items = {} }
      if entry.status ~= "ready" or #entry.items == 0 then
        local detail = entry.error or "Configured SSH project sources"
        if entry.status == "loading" then
          detail = string.format("Discovering… %ds", math.floor((now() - entry.started) / 1000))
        end
        items[#items + 1] = {
          id = "project-load:" .. name,
          name = LOAD_LABELS[entry.status],
          domain = name,
          source = "project_load",
          load_state = entry.status,
          is_open = false,
          cwd = detail,
          session_badge = LOAD_BADGES[entry.status],
        }
      end
    end
  end
  return items
end

function M.refresh_all()
  local names = {}
  for name, entry in pairs(domains) do
    if entry.status ~= "idle" then
      names[#names + 1] = name
    end
  end
  for _, name in ipairs(names) do
    M.load(name)
  end
end

function M.reset()
  for _, entry in pairs(domains) do
    entry.generation = entry.generation + 1
    cleanup(entry)
  end
  domains = {}
end

return M
