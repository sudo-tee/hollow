local M = {}

local THEME_KEYS = { "theme" }

local function invalidate_bars()
  if type(_G.hollow) == "table" and type(_G.hollow.ui) == "table" then
    if type(_G.hollow.ui.topbar) == "table" and type(_G.hollow.ui.topbar.invalidate) == "function" then
      _G.hollow.ui.topbar.invalidate()
    end
    if type(_G.hollow.ui.bottombar) == "table" and type(_G.hollow.ui.bottombar.invalidate) == "function" then
      _G.hollow.ui.bottombar.invalidate()
    end
    return
  end

  local ok_state, state = pcall(function()
    return require("hollow.state").get()
  end)
  if not ok_state or type(state) ~= "table" or type(state.ui) ~= "table" then
    return
  end

  state.ui.topbar_cache_dirty = true
  state.ui.bottombar_cache_dirty = true
end

---@param entry string
local function ensure_package_path_entry(entry)
  if type(package) ~= "table" or type(package.path) ~= "string" then
    return
  end
  if type(entry) ~= "string" or entry == "" then
    return
  end

  for existing in package.path:gmatch("[^;]+") do
    if existing == entry then
      return
    end
  end

  package.path = package.path .. ";" .. entry
end

---@param dir string|nil
---@param util HollowUtilNamespace
local function add_runtime_package_dir(dir, util)
  if type(dir) ~= "string" or dir == "" then
    return
  end

  ensure_package_path_entry(util.join_path(dir, "?.lua"))
  ensure_package_path_entry(util.join_path(dir, "?", "init.lua"))
end

---@param hollow Hollow
---@param host_api HollowHostBridge
---@param state HollowState
function M.setup(hollow, host_api, state)
  local theme_api = require("hollow.theme")

  local function sync_runtime_package_paths(values)
    local config_dir = type(host_api.default_config_path) == "function"
      and hollow.util.basepath(host_api.default_config_path())
      or nil
    add_runtime_package_dir(config_dir, hollow.util)
    add_runtime_package_dir(values.lib_dir, hollow.util)
  end

  local function resolve_config_theme(values)
    if not hollow.util.has_any_key(values, THEME_KEYS) then
      return nil
    end

    local theme_value = values.theme
    if type(theme_value) == "string" and theme_value ~= "" then
      local ok, resolved = pcall(theme_api.get, theme_value)
      return ok and resolved or nil
    end

    if type(theme_value) ~= "table" then
      return nil
    end

    return theme_api.create({
      terminal = theme_value.terminal,
      ui = theme_value.ui,
      palette = theme_value.palette,
    })
  end

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
    sync_runtime_package_paths(state.config.values)

    local resolved_theme = resolve_config_theme(state.config.values)
    local forwarded = hollow.util.clone_value(opts)
    if resolved_theme ~= nil then
      state.config.values.resolved_theme = hollow.util.clone_value(resolved_theme)

      if hollow.util.has_any_key(opts, THEME_KEYS) then
        forwarded.terminal_theme = hollow.util.clone_value(resolved_theme.terminal)
        forwarded.ui_theme = hollow.util.clone_value(resolved_theme.ui)
        forwarded.theme = type(state.config.values.theme) == "table" and {
          terminal = hollow.util.clone_value(resolved_theme.terminal),
          ui = hollow.util.clone_value(resolved_theme.ui),
          palette = hollow.util.clone_value(resolved_theme.palette),
        } or forwarded.theme
      end
    end

    if hollow.util.has_any_key(opts, THEME_KEYS) then
      invalidate_bars()
    end

    host_api.set_config(forwarded)
  end

  sync_runtime_package_paths(state.config.values)

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
