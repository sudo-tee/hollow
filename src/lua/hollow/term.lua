local M = {}

function M.setup(hollow, host_api)
  local pane_tags = {}

  local function normalize_tag(tag, fn_name)
    if type(tag) ~= "string" then
      error(fn_name .. " expects a string tag")
    end
    local trimmed = tag:match("^%s*(.-)%s*$") or ""
    if trimmed == "" then
      error(fn_name .. " expects a non-empty tag")
    end
    return trimmed
  end

  local function pane_tag_set(pane_id)
    local tags = pane_tags[pane_id]
    if tags == nil then
      tags = {}
      pane_tags[pane_id] = tags
    end
    return tags
  end

  local function snapshot_tags(pane_id)
    local set = pane_tags[pane_id]
    if set == nil then
      return {}
    end
    local tags = {}
    for tag, enabled in pairs(set) do
      if enabled == true then
        tags[#tags + 1] = tag
      end
    end
    table.sort(tags)
    return tags
  end

  local function resolve_pane_id(pane_id, fn_name)
    if pane_id ~= nil and type(pane_id) ~= "number" then
      error(fn_name .. " expects pane_id to be a number or nil")
    end
    local target = pane_id
    if target == nil then
      target = host_api.current_pane_id and host_api.current_pane_id() or nil
    end
    if target == nil or not host_api.pane_exists(target) then
      error(fn_name .. " could not resolve a pane")
    end
    return target
  end

  local function set_pane_tags(tags, pane_id)
    local target = resolve_pane_id(pane_id, "hollow.term.set_pane_tags(tags, pane_id?)")
    if tags == nil then
      pane_tags[target] = nil
      return
    end
    if type(tags) ~= "table" then
      error("hollow.term.set_pane_tags(tags, pane_id?) expects tags to be a table or nil")
    end
    local set = {}
    for _, tag in ipairs(tags) do
      set[normalize_tag(tag, "hollow.term.set_pane_tags(tags, pane_id?)")] = true
    end
    pane_tags[target] = next(set) ~= nil and set or nil
  end

  local function domain_snapshot(name)
    if type(name) ~= "string" or name == "" then
      return nil
    end

    local default_domain = hollow.config.get("default_domain")
    local current_pane_id = host_api.current_pane_id and host_api.current_pane_id() or nil
    local current_name = current_pane_id ~= nil
        and host_api.get_pane_domain
        and host_api.get_pane_domain(current_pane_id)
      or nil
    local domains = hollow.config.get("domains")
    local configured = type(domains) == "table" and domains[name] or nil

    if type(configured) == "string" then
      configured = { shell = configured }
    elseif type(configured) ~= "table" then
      configured = nil
    end

    local snapshot = {
      name = name,
      is_active = name == current_name,
      is_default = name == default_domain,
    }

    if configured ~= nil then
      for key, value in pairs(configured) do
        snapshot[key] = value
      end
    end

    return snapshot
  end

  local function pane_snapshot(pane_id)
    if pane_id == nil or not host_api.pane_exists(pane_id) then
      return nil
    end
    return {
      id = pane_id,
      pid = host_api.get_pane_pid(pane_id),
      domain = host_api.get_pane_domain and host_api.get_pane_domain(pane_id) or nil,
      cwd = host_api.get_pane_cwd(pane_id),
      title = host_api.get_pane_title(pane_id),
      foreground_process = host_api.get_pane_foreground_process
          and host_api.get_pane_foreground_process(pane_id)
        or nil,
      tags = snapshot_tags(pane_id),
      is_focused = host_api.pane_is_focused(pane_id),
      is_floating = host_api.pane_is_floating and host_api.pane_is_floating(pane_id) or false,
      is_maximized = host_api.pane_is_maximized and host_api.pane_is_maximized(pane_id) or false,
      frame = {
        x = host_api.get_pane_x and host_api.get_pane_x(pane_id) or 0,
        y = host_api.get_pane_y and host_api.get_pane_y(pane_id) or 0,
        width = host_api.get_pane_width(pane_id),
        height = host_api.get_pane_height(pane_id),
      },
      size = {
        rows = host_api.get_pane_rows(pane_id),
        cols = host_api.get_pane_cols(pane_id),
        width = host_api.get_pane_width(pane_id),
        height = host_api.get_pane_height(pane_id),
      },
    }
  end

  local function workspace_snapshot(index)
    local count = host_api.get_workspace_count and host_api.get_workspace_count() or 0
    if type(index) ~= "number" or index < 0 or index >= count then
      return nil
    end
    local pane = pane_snapshot(host_api.current_pane_id())
    return {
      id = host_api.get_workspace_id and host_api.get_workspace_id(index) or (index + 1),
      index = index + 1,
      name = host_api.get_workspace_name and host_api.get_workspace_name(index)
        or ("ws " .. tostring(index + 1)),
      domain = pane and pane.domain or nil,
      is_active = index
        == (host_api.get_active_workspace_index and host_api.get_active_workspace_index() or 0),
    }
  end

  local function tab_snapshot(tab_id, index)
    if tab_id == nil then
      return nil
    end
    local panes = {}
    local pane_count = host_api.get_tab_pane_count(tab_id) or 0
    for i = 0, pane_count - 1 do
      local pane = pane_snapshot(host_api.get_tab_pane_id_at(tab_id, i))
      if pane ~= nil then
        panes[#panes + 1] = pane
      end
    end
    local pane = pane_snapshot(host_api.get_tab_active_pane_id(tab_id))
    return {
      id = tab_id,
      title = pane and pane.title or "",
      index = index + 1,
      is_active = tab_id == host_api.current_tab_id(),
      panes = panes,
      pane = pane,
    }
  end

  function hollow.term.current_tab()
    local tab_id = host_api.current_tab_id()
    if tab_id == nil then
      return nil
    end
    local index = host_api.get_tab_index_by_id(tab_id)
    if index == nil then
      return nil
    end
    return tab_snapshot(tab_id, index)
  end

  function hollow.term.current_pane()
    local pane_id = host_api.current_pane_id()
    return pane_snapshot(pane_id)
  end

  function hollow.term.pane_by_id(id)
    if type(id) ~= "number" then
      error("hollow.term.pane_by_id(id) expects a pane id")
    end
    return pane_snapshot(id)
  end

  function hollow.term.tabs()
    local tabs = {}
    local count = host_api.get_tab_count()
    for i = 0, count - 1 do
      local tab_id = host_api.get_tab_id_at(i)
      if tab_id ~= nil then
        tabs[#tabs + 1] = tab_snapshot(tab_id, i)
      end
    end
    return tabs
  end

  function hollow.term.workspaces()
    local workspaces = {}
    local count = host_api.get_workspace_count and host_api.get_workspace_count() or 0
    for i = 0, count - 1 do
      local ws = workspace_snapshot(i)
      if ws ~= nil then
        workspaces[#workspaces + 1] = ws
      end
    end
    return workspaces
  end

  function hollow.term.current_workspace()
    local index = host_api.get_active_workspace_index and host_api.get_active_workspace_index() or 0
    return workspace_snapshot(index)
  end

  function hollow.term.workspace_by_id(id)
    if type(id) ~= "number" then
      error("hollow.term.workspace_by_id(id) expects a workspace id")
    end
    for _, workspace in ipairs(hollow.term.workspaces()) do
      if workspace.id == id then
        return workspace
      end
    end
    return nil
  end

  function hollow.term.current_domain()
    local pane_id = host_api.current_pane_id and host_api.current_pane_id() or nil
    if pane_id == nil or host_api.get_pane_domain == nil then
      return nil
    end
    return domain_snapshot(host_api.get_pane_domain(pane_id))
  end

  function hollow.term.set_workspace_name(name)
    if type(name) ~= "string" then
      error("hollow.term.set_workspace_name(name) expects a string")
    end
    host_api.set_workspace_name(name)
  end

  function hollow.term.set_workspace_default_cwd(cwd)
    if type(cwd) ~= "string" then
      error("hollow.term.set_workspace_default_cwd(cwd) expects a string")
    end
    host_api.set_workspace_default_cwd(cwd)
  end

  function hollow.term.new_workspace(opts)
    if opts ~= nil and type(opts) ~= "table" then
      error("hollow.term.new_workspace(opts) expects a table or nil")
    end
    if opts ~= nil and opts.cwd ~= nil and type(opts.cwd) ~= "string" then
      error("hollow.term.new_workspace(opts) expects opts.cwd to be a string")
    end
    if opts ~= nil and opts.domain ~= nil and type(opts.domain) ~= "string" then
      error("hollow.term.new_workspace(opts) expects opts.domain to be a string")
    end
    if opts ~= nil and opts.command ~= nil and type(opts.command) ~= "string" then
      error("hollow.term.new_workspace(opts) expects opts.command to be a string")
    end
    if opts ~= nil and opts.name ~= nil and type(opts.name) ~= "string" then
      error("hollow.term.new_workspace(opts) expects opts.name to be a string")
    end
    if opts ~= nil and opts.on_complete ~= nil and type(opts.on_complete) ~= "function" then
      error("hollow.term.new_workspace(opts) expects opts.on_complete to be a function")
    end
    host_api.new_workspace(opts)
  end

  function hollow.term.close_workspace(id)
    if id ~= nil and type(id) ~= "number" then
      error("hollow.term.close_workspace(id) expects a number or nil")
    end
    host_api.close_workspace(id)
  end

  function hollow.term.next_workspace()
    host_api.next_workspace()
  end

  function hollow.term.prev_workspace()
    host_api.prev_workspace()
  end

  function hollow.term.switch_workspace(index)
    if type(index) ~= "number" then
      error("hollow.term.switch_workspace(index) expects a number")
    end
    host_api.switch_workspace(index - 1)
  end

  function hollow.term.tab_by_id(id)
    for _, tab in ipairs(hollow.term.tabs()) do
      if tab.id == id then
        return tab
      end
    end
    return nil
  end

  function hollow.term.new_tab(opts)
    if opts ~= nil and type(opts) ~= "table" then
      error("hollow.term.new_tab(opts) expects a table or nil")
    end
    if opts ~= nil and opts.domain ~= nil and type(opts.domain) ~= "string" then
      error("hollow.term.new_tab(opts) expects opts.domain to be a string")
    end
    if opts ~= nil and opts.command ~= nil and type(opts.command) ~= "string" then
      error("hollow.term.new_tab(opts) expects opts.command to be a string")
    end
    if opts ~= nil and opts.on_complete ~= nil and type(opts.on_complete) ~= "function" then
      error("hollow.term.new_tab(opts) expects opts.on_complete to be a function")
    end
    host_api.new_tab(opts)
    return nil
  end

  function hollow.term.get_pane_text(pane_id)
    if pane_id ~= nil and type(pane_id) ~= "number" then
      error("hollow.term.get_pane_text(pane_id) expects a number or nil")
    end
    local target = pane_id
    if target == nil then
      target = host_api.current_pane_id and host_api.current_pane_id() or nil
    end
    if target == nil or not host_api.get_pane_text then
      return ""
    end
    return host_api.get_pane_text(target)
  end

  function hollow.term.get_pane_tags(pane_id)
    return snapshot_tags(resolve_pane_id(pane_id, "hollow.term.get_pane_tags(pane_id?)"))
  end

  function hollow.term.set_pane_tags(tags, pane_id)
    set_pane_tags(tags, pane_id)
  end

  function hollow.term.add_pane_tag(tag, pane_id)
    local target = resolve_pane_id(pane_id, "hollow.term.add_pane_tag(tag, pane_id?)")
    pane_tag_set(target)[normalize_tag(tag, "hollow.term.add_pane_tag(tag, pane_id?)")] = true
  end

  function hollow.term.remove_pane_tag(tag, pane_id)
    local target = resolve_pane_id(pane_id, "hollow.term.remove_pane_tag(tag, pane_id?)")
    local set = pane_tags[target]
    if set == nil then
      return
    end
    set[normalize_tag(tag, "hollow.term.remove_pane_tag(tag, pane_id?)")] = nil
    if next(set) == nil then
      pane_tags[target] = nil
    end
  end

  function hollow.term.split_pane(direction, opts)
    if type(direction) == "table" then
      opts, direction = direction, direction.direction
    end

    if direction ~= nil and type(direction) ~= "string" then
      error("hollow.term.split_pane: direction must be a string")
    end
    if opts ~= nil and type(opts) ~= "table" then
      error("hollow.term.split_pane: opts must be a table")
    end

    local fields = {
      ratio = "number",
      domain = "string",
      cwd = "string",
      command_mode = "string",
      close_on_exit = "boolean",
      floating = "boolean",
      fullscreen = "boolean",
      x = "number",
      y = "number",
      width = "number",
      height = "number",
      command = "string",
    }

    local payload = { direction = direction }

    if opts ~= nil then
      for field, expected in pairs(fields) do
        if opts[field] ~= nil and type(opts[field]) ~= expected then
          error(("hollow.term.split_pane: opts.%s must be a %s"):format(field, expected))
        end
        payload[field] = opts[field]
      end
      if opts.on_complete ~= nil and type(opts.on_complete) ~= "function" then
        error("hollow.term.split_pane: opts.on_complete must be a function")
      end
      payload.on_complete = opts.on_complete
    end

    host_api.split_pane(payload)
  end

  function hollow.term.focus_tab(id)
    if type(id) ~= "number" then
      error("hollow.term.focus_tab(id) expects a tab id")
    end
    if not host_api.switch_tab_by_id(id) then
      error("unknown tab id: " .. tostring(id))
    end
  end

  function hollow.term.close_tab(id)
    if type(id) ~= "number" then
      error("hollow.term.close_tab(id) expects a tab id")
    end
    if not host_api.close_tab_by_id(id) then
      error("unknown tab id: " .. tostring(id))
    end
  end

  function hollow.term.next_tab()
    host_api.next_tab()
  end

  function hollow.term.prev_tab()
    host_api.prev_tab()
  end

  function hollow.term.set_title(title, tab_id)
    if type(title) ~= "string" then
      error("hollow.term.set_title(title) expects a string")
    end
    local pane_id = nil
    if tab_id ~= nil then
      local tab = hollow.term.tab_by_id(tab_id)
      pane_id = tab and tab.pane and tab.pane.id or nil
    else
      pane_id = host_api.current_pane_id and host_api.current_pane_id() or nil
    end
    local previous = pane_id ~= nil and pane_snapshot(pane_id) or nil
    if tab_id ~= nil then
      if not host_api.set_tab_title_by_id(tab_id, title) then
        error("unknown tab id: " .. tostring(tab_id))
      end
    else
      host_api.set_tab_title(title)
    end

    if previous ~= nil and previous.title ~= title then
      hollow._emit_builtin_event("term:title_changed", {
        pane_id = previous.id,
        old_title = previous.title,
        new_title = title,
      })
    end
  end

  function hollow.term.set_pane_foreground_process(pane_id, process)
    if pane_id ~= nil and type(pane_id) ~= "number" then
      error("hollow.term.set_pane_foreground_process(pane_id, process) expects pane_id to be a number or nil")
    end
    if process ~= nil and type(process) ~= "string" then
      error("hollow.term.set_pane_foreground_process(pane_id, process) expects process to be a string or nil")
    end

    local target = resolve_pane_id(pane_id, "hollow.term.set_pane_foreground_process(pane_id, process)")
    local previous = pane_snapshot(target)
    local old_process = previous and previous.foreground_process or ""
    local new_process = process or ""

    host_api.set_pane_foreground_process(target, process)

    if old_process ~= new_process then
      hollow._emit_builtin_event("term:foreground_process_changed", {
        pane_id = target,
        old_process = old_process,
        new_process = new_process,
      })
    end
  end

  function hollow.term.send_text(text, pane_id)
    if type(text) ~= "string" then
      error("hollow.term.send_text(text) expects a string")
    end
    if pane_id ~= nil then
      if not host_api.send_text_to_pane(pane_id, text) then
        error("unknown pane id: " .. tostring(pane_id))
      end
      return
    end
    host_api.send_text(text)
  end

  function hollow.term.toggle_pane_maximized(pane_id, opts)
    if pane_id ~= nil and type(pane_id) == "table" then
      opts = pane_id
      pane_id = nil
    end
    if pane_id ~= nil and type(pane_id) ~= "number" then
      error("hollow.term.toggle_pane_maximized(pane_id?, opts?) expects pane_id to be a number")
    end
    if opts ~= nil and type(opts) ~= "table" then
      error("hollow.term.toggle_pane_maximized(pane_id?, opts?) expects opts to be a table")
    end
    local show_background = opts ~= nil and opts.show_background == true or false
    host_api.toggle_pane_maximized(pane_id, show_background)
  end

  function hollow.term.set_pane_floating(pane_id, floating)
    if pane_id ~= nil and type(pane_id) == "table" then
      floating = pane_id.floating
      pane_id = pane_id.pane_id or pane_id.id
    end
    if pane_id ~= nil and type(pane_id) ~= "number" then
      error("hollow.term.set_pane_floating(pane_id, floating) expects pane_id to be a number")
    end
    if floating ~= nil and type(floating) ~= "boolean" then
      error("hollow.term.set_pane_floating(pane_id, floating) expects floating to be a boolean")
    end
    host_api.set_pane_floating(pane_id, floating ~= false)
  end

  function hollow.term.set_floating_pane_bounds(pane_id, opts)
    if type(pane_id) ~= "number" then
      error("hollow.term.set_floating_pane_bounds(pane_id, opts) expects pane_id to be a number")
    end
    if type(opts) ~= "table" then
      error("hollow.term.set_floating_pane_bounds(pane_id, opts) expects opts to be a table")
    end
    host_api.set_floating_pane_bounds(
      pane_id,
      opts.x or 0.15,
      opts.y or 0.1,
      opts.width or 0.7,
      opts.height or 0.75
    )
  end

  function hollow.term.move_pane(direction_or_opts, opts)
    local pane_id = nil
    local amount = nil
    local direction

    if type(direction_or_opts) == "table" then
      pane_id = direction_or_opts.pane_id or direction_or_opts.id
      direction = direction_or_opts.direction
      amount = direction_or_opts.amount
    else
      direction = direction_or_opts
      if opts ~= nil then
        if type(opts) ~= "table" then
          error("hollow.term.move_pane(direction, opts) expects opts to be a table")
        end
        pane_id = opts.pane_id or opts.id
        amount = opts.amount
      end
    end

    if type(direction) ~= "string" then
      error("hollow.term.move_pane(...) expects a direction string")
    end
    if pane_id ~= nil and type(pane_id) ~= "number" then
      error("hollow.term.move_pane(...) expects pane_id to be a number")
    end
    if amount ~= nil and type(amount) ~= "number" then
      error("hollow.term.move_pane(...) expects amount to be a number")
    end

    host_api.move_pane(pane_id, direction, amount or 0.08)
  end

  function hollow.term.close_pane(pane_id)
    if pane_id ~= nil and type(pane_id) ~= "number" then
      error("hollow.term.close_pane(pane_id?) expects pane_id to be a number")
    end
    if pane_id ~= nil and host_api.close_pane_by_id ~= nil then
      if not host_api.close_pane_by_id(pane_id) then
        error("unknown pane id: " .. tostring(pane_id))
      end
      return
    end
    host_api.close_pane()
  end

  function hollow.term.focus_pane(direction)
    if type(direction) ~= "string" then
      error("hollow.term.focus_pane(direction) expects a direction string")
    end
    host_api.focus_pane(direction)
  end

  function hollow.term.focus_pane_by_id(pane_id)
    if type(pane_id) ~= "number" then
      error("hollow.term.focus_pane_by_id(pane_id) expects a pane id")
    end
    if host_api.focus_pane_by_id == nil or not host_api.focus_pane_by_id(pane_id) then
      error("unknown pane id: " .. tostring(pane_id))
    end
  end

  function hollow.term.resize_pane(axis_or_direction, delta)
    if type(axis_or_direction) ~= "string" then
      error("hollow.term.resize_pane(axis_or_direction, delta) expects a string axis or direction")
    end
    if type(delta) ~= "number" then
      error("hollow.term.resize_pane(axis_or_direction, delta) expects a number delta")
    end

    local axis = axis_or_direction
    if axis_or_direction == "left" or axis_or_direction == "right" then
      axis = "horizontal"
    elseif axis_or_direction == "up" or axis_or_direction == "down" then
      axis = "vertical"
    end

    host_api.resize_pane(axis, delta)
  end

  function hollow.term.reload_config()
    if not host_api.reload_config() then
      error("hollow.term.reload_config() failed")
    end
  end

  function hollow.term.scroll(where)
    if type(where) ~= "string" then
      error("hollow.term.scroll(where) expects a string")
    end
    if where == "top" then
      host_api.scroll_active_top()
      return
    end
    if where == "bottom" then
      host_api.scroll_active_bottom()
      return
    end
    if where == "page-up" then
      host_api.scroll_active_page(-1)
      return
    end
    if where == "page-down" then
      host_api.scroll_active_page(1)
      return
    end
    error("unknown scroll target: " .. tostring(where))
  end

  function hollow.term.set_theme(name)
    if type(name) ~= "string" then
      error("hollow.term.set_theme(name) expects a string")
    end
    hollow.config.set({ theme = name })
  end

  return {
    domain_snapshot = domain_snapshot,
    pane_snapshot = pane_snapshot,
    workspace_snapshot = workspace_snapshot,
    tab_snapshot = tab_snapshot,
  }
end

function hollow.term.run_domain_process(args, domain, opts)
  if type(args) ~= "table" then
    error("hollow.term.run_domain_process(args, domain?, opts?) expects args to be a table")
  end

  if domain == nil then
    local pane = hollow.term.current_pane()
    domain = pane and pane.domain or nil
  end

  if type(domain) ~= "string" or domain == "" then
    error("hollow.term.run_domain_process(args, domain?, opts?) could not resolve a domain")
  end

  return host_api.run_domain_process(domain, args, opts)
end

return M
