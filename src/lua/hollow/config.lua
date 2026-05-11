local M = {}

---@param hollow Hollow
---@param host_api HollowHostBridge
---@param state HollowState
function M.setup(hollow, host_api, state)
  local function ensure_default_wsl_domain(domains)
    local default_domain = hollow.config.get("default_domain")
    if
      type(default_domain) ~= "string"
      or default_domain == ""
      or domains[default_domain] ~= nil
    then
      return false
    end
    local distro = default_domain:match("^(.-)WSL$")
    hollow.log("Ensuring default WSL domain: " .. default_domain .. " -> " .. tostring(distro))
    if type(distro) ~= "string" or distro == "" then
      return false
    end
    domains[default_domain] = { shell = "wsl.exe -d " .. distro, wsl_distro = distro }
    return true
  end

  function hollow.config.set(opts)
    if type(opts) ~= "table" then
      error("hollow.config.set(opts) expects a table")
    end
    hollow.util.merge_tables(state.config.values, hollow.util.clone_value(opts))
    host_api.set_config(opts)
  end

  function hollow.config.get(key)
    return state.config.values[key]
  end

  function hollow.config.snapshot()
    return hollow.util.clone_value(state.config.values)
  end

  function hollow.config.reload()
    if not host_api.reload_config() then
      error("hollow.config.reload() failed")
    end
  end

  function hollow.config.populate_wsl_domains()
    local distros = host_api.list_wsl_distros()
    hollow.log("Populating WSL domains, found distros: " .. table.concat(distros or {}, ", "))
    if type(distros) ~= "table" then
      local domains = hollow.config.get("domains") or {}
      if ensure_default_wsl_domain(domains) then
        hollow.config.set({ domains = domains })
      end
      return
    end
    local domains = hollow.config.get("domains") or {}
    local changed = ensure_default_wsl_domain(domains)
    for _, distro in ipairs(distros) do
      if domains[distro .. "WSL"] == nil then
        domains[distro .. "WSL"] = { shell = "wsl.exe -d " .. distro, wsl_distro = distro }
        changed = true
      end
    end
    hollow.log("WSL domains after population: ", domains)
    if changed then
      hollow.config.set({ domains = domains })
    end
  end
end

return M
