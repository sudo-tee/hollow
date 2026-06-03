local hollow = assert(rawget(_G, "hollow"), "global hollow is missing")
local util = require("hollow.util")

local M = {
  _specs = {},
}

local function runtime_dir()
  return util.join_path(hollow.fs.data_dir(), "plugins")
end

local function log(message)
  hollow.log("hollow.plugins: " .. message)
end

local function expand_home(path)
  if type(path) ~= "string" or path:sub(1, 1) ~= "~" then
    return path
  end

  local home = os.getenv("HOME") or os.getenv("USERPROFILE")
  if type(home) ~= "string" or home == "" then
    return path
  end

  if path == "~" then
    return home
  end

  local first = path:sub(2, 2)
  if first == "/" or first == "\\" then
    return util.join_path(home, path:sub(3))
  end

  return path
end

local function is_local_path(value)
  return value:match("^~") ~= nil
    or value:match("^/") ~= nil
    or value:match("^%a:[/\\]") ~= nil
    or value:match("^[\\/][\\/]") ~= nil
end

local function repo_dir_name(value)
  local normalized = tostring(value or ""):gsub("[\\]+", "/"):gsub("/$", "")
  normalized = normalized:gsub("%.git$", "")
  return normalized:match("([^/]+)$")
end

local function normalize(entry)
  local raw = entry
  local opts = {}
  if type(entry) == "table" then
    raw = entry[1]
    opts = entry.opts or {}
  end

  if type(raw) ~= "string" or raw == "" then
    error("plugin spec must be a string or { spec, opts = ... }")
  end

  if is_local_path(raw) then
    local path = util.normalize_path(expand_home(raw))
    return {
      path = path,
      url = nil,
      opts = opts,
      source = "local",
    }
  end

  local url = raw
  if raw:match("^https?://") == nil then
    url = "https://github.com/" .. raw .. ".git"
  end

  local dir_name = repo_dir_name(url)
  if type(dir_name) ~= "string" or dir_name == "" then
    error("could not derive plugin directory name from spec: " .. tostring(raw))
  end

  return {
    path = util.join_path(runtime_dir(), dir_name),
    url = url,
    opts = opts,
    source = "git",
  }
end

local function prepend_package_path(entry)
  if type(package) ~= "table" or type(package.path) ~= "string" then
    return
  end

  for existing in package.path:gmatch("[^;]+") do
    if existing == entry then
      return
    end
  end

  package.path = entry .. ";" .. package.path
end

local function add_to_path(plugin_path)
  prepend_package_path(util.join_path(plugin_path, "lua", "?", "init.lua"))
  prepend_package_path(util.join_path(plugin_path, "lua", "?.lua"))
end

local function autoload(plugin_path)
  local autoload_dir = util.join_path(plugin_path, "hollow_plugin")
  local files = hollow.fs.glob(util.join_path(autoload_dir, "*.lua"))
  table.sort(files)

  for _, file in ipairs(files) do
    local ok, err = pcall(dofile, file)
    if not ok then
      log("autoload error in " .. file .. ": " .. tostring(err))
    end
  end
end

local function call_setup(spec)
  local name = util.basename(spec.path)
  if type(name) ~= "string" or name == "" then
    return
  end

  local ok, mod = pcall(require, name)
  if not ok or type(mod) ~= "table" or type(mod.setup) ~= "function" then
    return
  end

  local setup_ok, err = pcall(mod.setup, spec.opts or {})
  if not setup_ok then
    log("setup error in " .. name .. ": " .. tostring(err))
  end
end

local function ensure_plugin(spec)
  if spec.source ~= "git" then
    return true
  end

  if hollow.fs.is_dir(util.join_path(spec.path, ".git")) then
    return true
  end

  hollow.fs.mkdir_p(runtime_dir())
  local result = hollow.process.run("git", {
    "clone",
    "--depth=1",
    "--recurse-submodules",
    spec.url,
    spec.path,
  })
  if result.code ~= 0 then
    log("clone failed for " .. spec.url .. ": " .. tostring(result.stderr))
    return false
  end

  return true
end

function M.setup(config)
  config = config or {}
  local plugins = config.plugins or {}
  if type(plugins) ~= "table" then
    error("hollow.plugins.setup(config) expects config.plugins to be a table")
  end

  M._specs = {}

  for _, entry in ipairs(plugins) do
    local ok, spec_or_err = pcall(normalize, entry)
    if not ok then
      log("invalid plugin spec: " .. tostring(spec_or_err))
    else
      local spec = spec_or_err
      M._specs[#M._specs + 1] = spec

      local proceed = false
      if spec.source == "local" then
        proceed = hollow.fs.is_dir(spec.path)
        if not proceed then
          log("missing local plugin path: " .. spec.path)
        end
      else
        proceed = ensure_plugin(spec)
      end
      if proceed then
        add_to_path(spec.path)
        autoload(spec.path)
        call_setup(spec)
      end
    end
  end
end

function M.sync()
  for _, spec in ipairs(M._specs or {}) do
    if spec.source == "git" and hollow.fs.is_dir(util.join_path(spec.path, ".git")) then
      local result = hollow.process.run("git", {
        "-C",
        spec.path,
        "pull",
        "--ff-only",
        "--recurse-submodules",
      })
      if result.code ~= 0 then
        log("update failed for " .. spec.path .. ": " .. tostring(result.stderr))
      else
        log("updated " .. spec.path)
      end
    end
  end
end

return M
