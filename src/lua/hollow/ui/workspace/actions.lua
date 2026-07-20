local source = require("hollow.ui.workspace.source")

---@type Hollow
local hollow = _G.hollow
---@type HollowUi
local ui = hollow.ui

local M = {}

local function trim_string(value)
  return source.trim_string(value)
end

local function notify_warn(message, ttl)
  local notify = ui.notify
  local warn = notify and notify.warn
  if type(warn) == "function" then
    warn(message, { ttl = ttl or 1400 })
  end
end

local function shell_quote(value)
  value = trim_string(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function current_pane_cwd()
  local pane = hollow.term.current_pane()
  local cwd = trim_string(pane and pane.cwd)
  return cwd ~= "" and cwd or nil
end

local function active_workspace_name()
  local workspace = hollow.term.current_workspace()
  local name = trim_string(workspace and workspace.name)
  return name ~= "" and name or nil
end

local function workspace_name(workspace)
  return trim_string(type(workspace) == "table" and workspace.name or nil)
end

local function send_cwd_to_active_workspace(cwd)
  cwd = trim_string(cwd)
  if cwd ~= "" then
    hollow.term.send_text("cd -- " .. shell_quote(cwd) .. "\r")
  end
end

local function ssh_workspace_command(cwd)
  cwd = trim_string(cwd)
  return cwd ~= "" and ("cd -- " .. shell_quote(cwd) .. "\r") or nil
end

local function open_new_workspace_from_item(item)
  item = type(item) == "table" and item or {}
  local source_name = item.source
  local cwd = item.cwd

  local name = trim_string(item.name)

  hollow.term.new_workspace({
    name = name ~= "" and name or nil,
    cwd = source_name == "ssh" and nil or cwd,
    domain = item.domain,
    command = source_name == "ssh" and ssh_workspace_command(cwd) or nil,
    on_complete = item.on_complete,
  })

  if name ~= "" then
    source.remember_workspace_cwd(name, cwd, item.domain)
    source.ensure_last_opened(name)
    return
  end

  local current_name = active_workspace_name()
  if current_name then
    source.ensure_last_opened(current_name)
  end
end

local function switch_to_workspace(workspace)
  if type(workspace) ~= "table" then
    return
  end

  if workspace.is_open and workspace.open_index ~= nil then
    local prev_name = active_workspace_name()
    hollow.term.switch_workspace(workspace.open_index)
    if prev_name then
      source.ensure_last_opened(prev_name)
    end
    if workspace.source == "user" and workspace.cwd ~= nil then
      send_cwd_to_active_workspace(workspace.cwd)
    end
    source.ensure_last_opened(workspace.name)
    return
  end

  open_new_workspace_from_item({
    name = workspace.name,
    cwd = workspace.cwd or current_pane_cwd(),
    domain = workspace.domain,
    source = workspace.source,
    on_complete = function(result)
      if result ~= nil and result.success == true and workspace.cwd ~= nil then
        hollow.workspace.bootstrap_project(workspace.cwd)
      end
    end,
  })
end

local function open_create_input(opts)
  opts = opts or {}
  ui.input.open({
    prompt = opts.prompt or "New workspace name",
    on_confirm = function(value)
      local name = trim_string(value)
      if name == "" then
        notify_warn("Workspace name cannot be empty")
        return
      end

      open_new_workspace_from_item({ name = name, cwd = "" })
      if type(opts.on_confirm) == "function" then
        opts.on_confirm(name)
      end
    end,
  })
end

local function open_rename_input(workspace, opts)
  opts = opts or {}
  local target = workspace or hollow.term.current_workspace()
  local target_name = workspace_name(target)
  if target_name == "" then
    return
  end

  local current_name = active_workspace_name()
  if target_name ~= current_name then
    notify_warn("Rename works on the active workspace")
    return
  end

  ui.input.open({
    prompt = opts.prompt or "Rename workspace",
    default = target_name,
    on_confirm = function(value)
      local name = trim_string(value)
      if name == "" then
        notify_warn("Workspace name cannot be empty")
        return
      end

      hollow.term.set_workspace_name(name)
      source.ensure_last_opened(name)
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

  if target.workspace_id ~= nil then
    hollow.term.close_workspace(target.workspace_id)
    return
  end

  hollow.term.close_workspace(target.id)
end

local function open_workspace(opts)
  opts = opts or {}
  local source_name = trim_string(opts.source)
  if source_name == "" then
    opts = type(opts) == "table" and opts or {}
    open_new_workspace_from_item(opts)
    return
  end

  local configured_source = source.find_source(source_name)
  if configured_source == nil then
    notify_warn("Workspace source not found: " .. source_name, 1800)
    return
  end

  local item = source.source_workspace_item(
    opts.item or opts,
    configured_source,
    source.source_domain_name(configured_source)
  )

  if item == nil then
    notify_warn("Could not resolve workspace from source: " .. source_name, 1800)
    return
  end

  open_new_workspace_from_item(item)
end

function M.switch_to_workspace(workspace)
  switch_to_workspace(workspace)
end

function M.open_new_workspace_from_item(item)
  open_new_workspace_from_item(item)
end

function M.open_create_input(opts)
  open_create_input(opts)
end

function M.open_rename_input(workspace, opts)
  open_rename_input(workspace, opts)
end

function M.close_workspace(workspace)
  close_workspace(workspace)
end

function M.open_workspace(opts)
  open_workspace(opts)
end

return M
