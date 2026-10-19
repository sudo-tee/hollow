-- Temporary legacy-config adapter. Platform knowledge must not leak into discovery.
local M = {}
local warned = {}

local function warn(key, message)
  if warned[key] then return end
  warned[key] = true
  local hollow = _G.hollow
  message = "Workspace config: " .. message
  hollow.log(message)
  hollow.ui.notify.warn(message, { ttl = 10000 })
end

local function copy(value)
  local result = {}
  for key, item in pairs(value) do result[key] = item end
  return result
end

local function unc(path)
  if type(path) ~= "string" then return end
  local normalized = path:gsub("\\", "/")
  local lower = normalized:lower()
  local prefix = lower:match("^//wsl%$/()") or lower:match("^//wsl%.localhost/()")
  if not prefix then return end
  local distro, path = normalized:sub(prefix):match("^([^/]+)(.*)$")
  if distro then return distro, path == "" and "/" or path end
end

local function domain_host(domain)
  local config = _G.hollow.config.snapshot()
  local value = (config.domains or {})[domain]
  if type(value) ~= "table" then return end
  if type(value.wsl_distro) == "string" and value.wsl_distro ~= "" then
    return { type = "wsl", distro = value.wsl_distro }
  end
  local ssh = value.ssh
  if type(ssh) == "table" then
    if ssh.backend ~= nil and ssh.backend ~= "native" then return nil, "SSH backend is not native" end
    local destination = ssh.alias or ssh.host
    if type(destination) == "string" and destination ~= "" then
      return { type = "ssh", destination = destination, user = ssh.user }
    end
  end
end

function M.source(raw)
  local source = copy(raw)
  local roots, distro = {}, nil
  for index, root in ipairs(type(source.roots) == "table" and source.roots or {}) do
    -- Explicit host-native paths are opaque, even if they resemble Windows UNC.
    local name, path
    if source.host == nil or source.cwd_resolver == "wsl_unc" then name, path = unc(root) end
    if name then
      if distro and distro ~= name then
        return nil, "mixed WSL distributions; split roots into separate host sources"
      end
      distro, roots[index] = name, path
    else
      roots[index] = root
    end
  end
  local legacy = source.resolver ~= nil or source.cwd_resolver ~= nil or distro ~= nil
  if distro then
    if source.host == nil and source.resolver ~= nil and source.resolver ~= "local" and source.resolver ~= "wsl" then
      return nil, "UNC guest disagrees with resolver; configure an explicit host and guest-native roots"
    end
    if source.host == nil and source.resolver == "wsl" and source.name ~= nil and source.name ~= "" and source.name ~= distro then
      return nil, "WSL UNC roots disagree with legacy distribution name"
    end
    for _, root in ipairs(source.roots) do
      if not unc(root) then return nil, "mixed UNC and native roots; split into separate host sources" end
    end
  end
  if source.host == nil then
    local mapped, mapping_error
    if source.resolver ~= "local" or distro then mapped, mapping_error = domain_host(source.domain) end
    if mapping_error then return nil, mapping_error .. "; configure host explicitly" end
    if distro then
      if mapped and (mapped.type ~= "wsl" or mapped.distro ~= distro) then
        return nil, "WSL UNC roots disagree with domain; configure host and Linux roots explicitly"
      end
      source.host = { type = "wsl", distro = distro }
    elseif source.resolver == "wsl" then
      source.host = mapped
      if mapped and source.name ~= nil and source.name ~= "" and source.name ~= mapped.distro then
        return nil, "legacy WSL name disagrees with domain; configure an explicit matching host"
      end
      if not source.host and type(source.name) == "string" and source.name ~= "" then
        source.host = { type = "wsl", distro = source.name }
      end
      if not source.host or source.host.type ~= "wsl" then
        return nil, "cannot identify WSL distribution; configure host = { type = 'wsl', distro = '...' }"
      end
    elseif source.resolver == "ssh" then
      if not mapped or mapped.type ~= "ssh" then
        return nil, "cannot identify SSH destination; configure host = { type = 'ssh', destination = '...' }"
      end
      source.host = mapped
    elseif source.resolver == nil or source.resolver == "local" then
      -- An explicit local resolver must not silently switch credential/host context.
      source.host = (source.resolver == nil and mapped) or { type = "local" }
      legacy = legacy or (source.resolver == nil and mapped ~= nil)
    else
      return nil, "unknown resolver; configure an explicit host"
    end
  elseif distro then
    if type(source.host) ~= "table" or source.host.type ~= "wsl" or source.host.distro ~= distro then
      return nil, "UNC conversion requires an explicit matching WSL host descriptor and Linux roots"
    end
  end
  source.roots = roots
  if source.cwd_resolver ~= nil and source.cwd_resolver ~= "wsl_unc" and type(source.cwd_resolver) ~= "function" then
    return nil, "unknown cwd_resolver; use host-native paths"
  end
  if legacy then
    local remote = type(source.host) == "table" and source.host.type ~= nil and source.host.type ~= "local"
    local target = remote and (source.host.distro or source.host.destination) or nil
    local target_key = remote and source.host.type == "wsl" and "distro" or "destination"
    local replacement = remote and ("host = { type = " .. string.format("%q", source.host.type)
      .. (target and (", " .. target_key .. " = " .. string.format("%q", target)) or "")
      .. " }, roots = { <guest-native paths> }")
      or "host = { type = 'local' }, roots = { <native paths> } (or pass a ready host)"
    warn("source:" .. tostring(source.name or source.domain or "") .. ":" .. tostring(source.resolver) .. ":" .. tostring(distro)
      .. ":" .. tostring(roots[1]) .. ":" .. tostring(source.cwd_resolver),
      "legacy source converted in memory; update to " .. replacement .. "."
        .. (remote and " Connecting may deploy the bundled agent into the selected guest's cache." or ""))
  end
  -- Custom transforms survive only at this compatibility boundary.
  source._legacy_cwd = source.cwd_resolver
  source.cwd_resolver, source.resolver = nil, nil
  return source
end

function M.item(source, raw)
  if type(raw) ~= "table" then return raw end
  local item = copy(raw)
  local resolver = item.cwd_resolver or source._legacy_cwd
  if resolver == "wsl_unc" then
    local _, path = unc(item.cwd)
    item.cwd = path or item.cwd
  elseif type(resolver) == "function" then
    local ok, value = pcall(resolver, item.cwd, copy(item), copy(source))
    if ok and (value == nil or type(value) == "string") then item.cwd = value end
  end
  item.cwd_resolver = nil
  return item
end

function M.warn_invalid(source, reason)
  warn("invalid:" .. tostring(source.name or source.domain or "") .. ":" .. reason,
    "source disabled: " .. reason .. ". No local or shell fallback is used.")
end

function M.project_roots(roots)
  warn("project_roots", "project_roots is deprecated; use sources = { { roots = { ... } } }. Paths are scanned through host.fs.")
  return { roots = roots }
end

return M
