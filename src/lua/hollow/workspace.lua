local M = {}

---@type Hollow
local hollow = _G.hollow
local host_api = assert(rawget(_G, "host_api"), "global host_api bridge is missing")
local async = require("hollow.async")
local json = require("hollow.json")
local util = require("hollow.util")

local function trim_string(value)
  if type(value) ~= "string" then
    return ""
  end
  return value:match("^%s*(.-)%s*$") or ""
end

local function normalize_base_dir(base_dir)
  base_dir = trim_string(base_dir)
  if base_dir == "" then
    return nil
  end
  if util.basename(base_dir) == ".hollow" then
    return util.basepath(base_dir)
  end
  return base_dir
end

local function shell_quote(value)
  value = trim_string(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function send_startup_commands(pane)
  local lines = {}
  if pane.cwd ~= nil then
    lines[#lines + 1] = "cd -- " .. shell_quote(pane.cwd)
  end
  if pane.command ~= nil then
    lines[#lines + 1] = pane.command
  end
  if #lines > 0 then
    hollow.term.send_text(table.concat(lines, " && ") .. "\r")
  end
end

local function normalize_tags(value)
  if value == nil then
    return nil
  end
  if type(value) == "string" then
    local trimmed = trim_string(value)
    return trimmed ~= "" and { trimmed } or nil
  end
  if type(value) ~= "table" then
    return nil
  end
  local tags = hollow.tbl(value):filter_map(function(tag)
    local trimmed = trim_string(tag)
    return trimmed ~= "" and trimmed or nil
  end):get()
  return #tags > 0 and tags or nil
end

local function normalize_relative_path(base_dir, value)
  value = trim_string(value)
  if value == "" then
    return nil
  end

  if value == "." then
    return normalize_base_dir(base_dir)
  end

  local normalized = util.normalize_path(value)
  if normalized == nil then
    return value
  end

  if
    normalized:match("^%a:[/\\]")
    or normalized:sub(1, 1) == "/"
    or normalized:sub(1, 2) == "\\\\"
  then
    return normalized
  end

  if base_dir == nil or base_dir == "" then
    return normalized
  end

  return util.join_path(base_dir, normalized)
end

local function clone_with_resolved_paths(base_dir, pane)
  local copy = util.clone_value(pane)
  copy.cwd = normalize_relative_path(base_dir, copy.cwd)
  copy.tags = normalize_tags(copy.tags or copy.tag)
  copy.tag = nil
  return copy
end

local function is_main_pane(value)
  return value == true
end

local function select_main_pane(current, pane_id, pane)
  if not is_main_pane(pane.main or pane.default) then
    return current
  end
  if current ~= nil then
    error("workspace spec may only mark one pane as main/default")
  end
  if pane_id == nil then
    error("workspace bootstrap could not resolve main/default pane")
  end
  return pane_id
end

local function pane_opts(pane, tab_layout)
  local opts = {}
  if pane.cwd ~= nil then
    opts.cwd = pane.cwd
  end
  if pane.domain ~= nil then
    opts.domain = pane.domain
  end
  if pane.command ~= nil then
    opts.command = pane.command
  end
  if pane.command_mode ~= nil then
    opts.command_mode = pane.command_mode
  end
  if pane.close_on_exit ~= nil then
    opts.close_on_exit = pane.close_on_exit == true
  end
  if pane.floating ~= nil then
    opts.floating = pane.floating == true
  end
  if pane.fullscreen ~= nil then
    opts.fullscreen = pane.fullscreen == true
  end
  if pane.x ~= nil then
    opts.x = pane.x
  end
  if pane.y ~= nil then
    opts.y = pane.y
  end
  if pane.width ~= nil then
    opts.width = pane.width
  end
  if pane.height ~= nil then
    opts.height = pane.height
  end
  if pane.size ~= nil and opts.ratio == nil then
    opts.ratio = pane.size
  end
  opts.direction = pane.direction or tab_layout
  return opts
end

local function bootstrap_tab(tab, base_dir, is_first_tab, reuse_existing)
  local panes = type(tab.panes) == "table" and tab.panes or {}
  if #panes == 0 then
    return nil
  end

  local tab_start_ms = host_api.now_ms and host_api.now_ms() or nil

  local first = clone_with_resolved_paths(base_dir, panes[1])
  local main_pane_id = nil
  if is_first_tab and reuse_existing == true then
    if first.cwd ~= nil then
      hollow.term.set_workspace_default_cwd(first.cwd)
    end
    local current_pane = hollow.term.current_pane()
    main_pane_id = select_main_pane(main_pane_id, current_pane and current_pane.id or nil, first)
    async.next_tick()
  else
    local create_start_ms = host_api.now_ms and host_api.now_ms() or nil
    local result = async.await(function(resolve)
      local create = is_first_tab and hollow.term.new_workspace or hollow.term.new_tab
      create({
        cwd = first.cwd,
        domain = first.domain,
        command = is_first_tab and nil or first.command,
        name = is_first_tab and tab.name or nil,
        on_complete = resolve,
      })
    end)
    local create_end_ms = host_api.now_ms and host_api.now_ms() or nil
    if create_start_ms ~= nil and create_end_ms ~= nil then
      hollow.log(
        "workspace bootstrap create waited_ms=",
        create_end_ms - create_start_ms,
        "first_tab=",
        is_first_tab == true
      )
    end
    if result == nil or result.success ~= true then
      error("workspace bootstrap " .. (is_first_tab and "new_workspace" or "new_tab") .. " failed")
    end
    local current_pane = hollow.term.current_pane()
    main_pane_id = select_main_pane(main_pane_id, current_pane and current_pane.id or nil, first)
    async.next_tick()
  end

  if first.tags ~= nil then
    hollow.term.set_pane_tags(first.tags)
  end

  if reuse_existing == true or not is_first_tab then
    send_startup_commands(first)
  end

  if not is_first_tab and trim_string(tab.name) ~= "" then
    hollow.term.set_title(tab.name)
  end

  for index = 2, #panes do
    local pane = clone_with_resolved_paths(base_dir, panes[index])
    hollow.log("Creating pane with options: ", pane)
    local opts = pane_opts(pane, tab.layout)

    local split_start_ms = host_api.now_ms and host_api.now_ms() or nil
    local result = async.await(function(resolve)
      opts.on_complete = resolve
      hollow.term.split_pane(opts)
    end)
    local split_end_ms = host_api.now_ms and host_api.now_ms() or nil
    if split_start_ms ~= nil and split_end_ms ~= nil then
      hollow.log(
        "workspace bootstrap split waited_ms=",
        split_end_ms - split_start_ms,
        "index=",
        index
      )
    end

    if result == nil or result.success ~= true then
      error("workspace bootstrap split_pane failed")
    end
    if pane.tags ~= nil then
      hollow.term.set_pane_tags(pane.tags, result.pane_id)
    end
    main_pane_id = select_main_pane(main_pane_id, result.pane_id, pane)
    async.next_tick()
  end

  local tab_end_ms = host_api.now_ms and host_api.now_ms() or nil
  if tab_start_ms ~= nil and tab_end_ms ~= nil then
    hollow.log(
      "workspace bootstrap tab total_ms=",
      tab_end_ms - tab_start_ms,
      "panes=",
      #panes,
      "first_tab=",
      is_first_tab == true
    )
  end

  return main_pane_id
end

local function workspace_spec_name(spec, fallback)
  local value = trim_string(type(spec) == "table" and spec.name or nil)
  if value ~= "" then
    return value
  end
  return fallback
end

local function validate_spec(spec)
  if type(spec) ~= "table" then
    error("workspace spec must be a table")
  end
  if spec.tabs ~= nil and type(spec.tabs) ~= "table" then
    error("workspace spec tabs must be a table")
  end
end

function M.bootstrap(spec, opts)
  opts = opts or {}
  validate_spec(spec)

  local tabs = spec.tabs or {}
  if #tabs == 0 then
    return nil
  end

  local base_dir = normalize_base_dir(opts.base_dir)
  local existing_workspaces = hollow.term.workspaces()
  local previous_workspace = hollow.term.current_workspace()
  local reuse_existing = not (
    opts.replace_current == true
    and #existing_workspaces == 1
    and previous_workspace ~= nil
  )

  local function finish()
    if opts.replace_current == true and #existing_workspaces == 1 and previous_workspace ~= nil then
      local current_workspace = hollow.term.current_workspace()
      if current_workspace ~= nil and current_workspace.index ~= previous_workspace.index then
        hollow.term.switch_workspace(previous_workspace.index)
        hollow.term.close_workspace()
      end
    end
  end

  async.run(function()
    local main_pane_id = nil
    for index, tab in ipairs(tabs) do
      local tab_main_pane_id = bootstrap_tab(tab, base_dir, index == 1, reuse_existing)
      if tab_main_pane_id ~= nil then
        if main_pane_id ~= nil then
          error("workspace spec may only mark one pane as main/default")
        end
        main_pane_id = tab_main_pane_id
      end
    end
    if main_pane_id ~= nil then
      hollow.term.focus_pane_by_id(main_pane_id)
    end
    finish()
  end)

  return hollow.term.current_workspace()
end

function M.load(path)
  if type(path) ~= "string" or path == "" then
    error("hollow.workspace.load(path) expects a path string")
  end
  local text = host_api.read_file(path)
  local spec = json.decode(text)
  validate_spec(spec)
  spec._path = path
  return spec
end

function M.load_and_bootstrap(path, opts)
  local spec = M.load(path)
  opts = opts or {}
  opts.base_dir = normalize_base_dir(opts.base_dir or util.basepath(path))
  opts.name = opts.name or workspace_spec_name(spec, util.basename(util.basepath(path) or path))
  return M.bootstrap(spec, opts)
end

function M.export_current()
  local workspace = hollow.term.current_workspace()
  local tabs = {}
  for _, tab in ipairs(hollow.term.tabs()) do
    local panes = {}
    for _, pane in ipairs(tab.panes or {}) do
      panes[#panes + 1] = {
        cwd = pane.cwd ~= "" and pane.cwd or nil,
        domain = pane.domain,
        command = pane.foreground_process,
        tags = pane.tags ~= nil and #pane.tags > 0 and util.clone_value(pane.tags) or nil,
        main = pane.is_focused == true or nil,
      }
    end
    tabs[#tabs + 1] = {
      name = tab.title,
      panes = panes,
    }
  end
  return {
    name = workspace and workspace.name or nil,
    tabs = tabs,
  }
end

function M.export_to(path)
  if type(path) ~= "string" or path == "" then
    error("hollow.workspace.export_to(path) expects a path string")
  end
  local encoded = json.encode(M.export_current())
  host_api.write_file(path, encoded .. "\n")
  return path
end

function M.project_local_path(dir)
  dir = trim_string(dir)
  if dir == "" then
    local pane = hollow.term.current_pane()
    dir = trim_string(pane and pane.cwd)
  end
  if dir == "" then
    return nil
  end
  local path = util.join_path(dir, ".hollow", "workspace.json")
  local pane = hollow.term.current_pane()
  if pane and pane.domain ~= nil then
    local domain_name = pane.domain
    local config = hollow.config.snapshot()
    local domains = type(config.domains) == "table" and config.domains or {}
    local domain_cfg = domains[domain_name]
    local distro = (type(domain_cfg) == "table" and domain_cfg.wsl_distro) or domain_name
    if distro then
      return util.linux_to_wsl_unc_path(path, distro) or path
    end
  end
  return path
end

local function default_layout_path(name)
  name = trim_string(name)
  if name == "" then
    return nil
  end

  if name:sub(-5) == ".json" or name:find("/", 1, true) or name:find("\\", 1, true) then
    return name
  end

  local config_path = host_api.default_config_path()
  if type(config_path) ~= "string" or config_path == "" then
    return nil
  end
  local config_dir = util.basepath(config_path)
  if config_dir == nil then
    return nil
  end
  local default_path = util.join_path(config_dir, "layouts", name .. ".json")
  hollow.log("Resolving default layout path: " .. default_path)
  return default_path
end

function M.resolve_auto_bootstrap_path()
  local config = hollow.config.snapshot()
  local workspace_cfg = type(config.workspace) == "table" and config.workspace or {}
  local mode = trim_string(workspace_cfg.auto_bootstrap)
  if mode == "never" then
    return nil
  end

  local project_path = M.project_local_path()
  if project_path ~= nil and host_api.path_exists(project_path) then
    return project_path
  end

  local default_layout = trim_string(workspace_cfg.default_layout)
  if default_layout ~= "" then
    local resolved = default_layout_path(default_layout)
    if resolved ~= nil and host_api.path_exists(resolved) then
      hollow.log("Auto-bootstrap default layout found: " .. resolved)
      return resolved
    end
  end

  return nil
end

function M.auto_bootstrap()
  local path = M.resolve_auto_bootstrap_path()
  if path == nil then
    return false
  end

  M.load_and_bootstrap(path, { replace_current = true })
  return true
end

function M.auto_bootstrap_deferred()
  host_api.defer(function()
    M.auto_bootstrap()
  end)
end

return M
