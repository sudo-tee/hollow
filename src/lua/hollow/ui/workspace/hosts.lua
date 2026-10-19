-- Own descriptor-created connections, not caller-supplied hosts. Scans borrow them.
local M = {}
local pool = {}
local next_id = 0

local function changed()
  local switcher = require("hollow.state").get().ui.workspace_switcher
  switcher.host_scan_revision = (switcher.host_scan_revision or 0) + 1
end

local function encode(value, seen)
  local kind = type(value)
  if kind == "nil" or kind == "boolean" or kind == "number" then return kind .. ":" .. tostring(value) end
  if kind == "string" then return #value .. ":" .. value end
  if kind ~= "table" then error("host descriptors must contain only data") end
  seen = seen or {}
  if seen[value] then error("cyclic host descriptor") end
  seen[value] = true
  local entries = {}
  for key, item in pairs(value) do entries[#entries + 1] = encode(key, seen) .. "=" .. encode(item, seen) end
  table.sort(entries)
  seen[value] = nil
  return "{" .. table.concat(entries, ";") .. "}"
end

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[key] = copy(item) end
  return result
end

local function retire(entry)
  entry.retired = true
  if entry.owned and entry.host then entry.host:close()
  elseif entry.owned and entry.promise and type(entry.promise.cancel) == "function" then entry.promise:cancel() end
end

local function failed(entry, err)
  if entry.retired then return end
  entry.error = err
  changed()
  local message = type(err) == "table" and (err.message or err.code) or tostring(err)
  _G.hollow.log("Workspace host connection failed", message)
  _G.hollow.ui.notify.warn("Workspace host: " .. tostring(message) .. ". Fix configuration, then clear workspace cache to retry.", { ttl = 10000 })
end

local function connect(spec)
  local entry = { owned = spec.type ~= "local" }
  local ok, promise = pcall(function()
    local api = _G.hollow.host
    if spec.type == "local" then return api.local_host() end
    if spec.type ~= "wsl" and spec.type ~= "ssh" and spec.type ~= "podman" and spec.type ~= "docker" then
      error("unsupported workspace host type")
    end
    local opts = copy(spec)
    opts.type = nil
    next_id = next_id + 1
    opts.id = opts.id or ("workspace-host-" .. next_id)
    return api[spec.type](opts)
  end)
  if not ok then failed(entry, promise); return entry end
  entry.promise = promise
  local good, err = pcall(function()
    promise:next(function(host)
      if entry.retired then
        if entry.owned then host:close() end
        return
      end
      entry.host = host
      changed()
    end, function(reason) failed(entry, reason) end)
  end)
  if not good then failed(entry, err) end
  return entry
end

function M.prepare(sources)
  local used = {}
  for _, source in ipairs(sources) do
    local spec = source.host
    if type(spec) == "table" and spec.type ~= nil then
      local ok, key = pcall(encode, spec)
      if not ok then
        source.host = false
        require("hollow.ui.workspace.compat").warn_invalid(source, "invalid host descriptor")
      elseif source.default ~= false and type(source.roots) == "table" and #source.roots > 0 then
        used[key] = true
        local entry = pool[key]
        if not entry then entry = connect(spec); pool[key] = entry end
        source.host = entry.host or false
        source._host_pending = entry.host == nil
      else
        source.host = false
      end
    end
  end
  for key, entry in pairs(pool) do
    if not used[key] then retire(entry); pool[key] = nil end
  end
  return sources
end

-- Explicit retry only. Never reconnect/replay work just because a picker polls.
function M.retry()
  for key, entry in pairs(pool) do
    if entry.error or (entry.host and (entry.host.closed or entry.host:status() ~= "ready")) then
      retire(entry)
      pool[key] = nil
    end
  end
end

return M
