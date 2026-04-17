local M = {}

function M.setup(hollow, host_api)
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
    return {
      index = index + 1,
      name = host_api.get_workspace_name and host_api.get_workspace_name(index)
        or ("ws " .. tostring(index + 1)),
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

  function hollow.term.set_workspace_name(name)
    if type(name) ~= "string" then
      error("hollow.term.set_workspace_name(name) expects a string")
    end
    host_api.set_workspace_name(name)
  end

  function hollow.term.new_workspace(opts)
    if opts ~= nil and type(opts) ~= "table" then
      error("hollow.term.new_workspace(opts) expects a table or nil")
    end
    if opts ~= nil and opts.cwd ~= nil and type(opts.cwd) ~= "string" then
      error("hollow.term.new_workspace(opts) expects opts.cwd to be a string")
    end
    host_api.new_workspace(opts)
  end

  function hollow.term.close_workspace()
    host_api.close_workspace()
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
    host_api.new_tab(opts)
    return nil
  end

  function hollow.term.split_pane(direction, opts)
    if type(direction) == "table" then
      if direction.ratio ~= nil and type(direction.ratio) ~= "number" then
        error("hollow.term.split_pane(opts) expects opts.ratio to be a number")
      end
      if direction.domain ~= nil and type(direction.domain) ~= "string" then
        error("hollow.term.split_pane(opts) expects opts.domain to be a string")
      end
      if direction.cwd ~= nil and type(direction.cwd) ~= "string" then
        error("hollow.term.split_pane(opts) expects opts.cwd to be a string")
      end
      if direction.floating ~= nil and type(direction.floating) ~= "boolean" then
        error("hollow.term.split_pane(opts) expects opts.floating to be a boolean")
      end
      if direction.fullscreen ~= nil and type(direction.fullscreen) ~= "boolean" then
        error("hollow.term.split_pane(opts) expects opts.fullscreen to be a boolean")
      end
      if direction.x ~= nil and type(direction.x) ~= "number" then
        error("hollow.term.split_pane(opts) expects opts.x to be a number")
      end
      if direction.y ~= nil and type(direction.y) ~= "number" then
        error("hollow.term.split_pane(opts) expects opts.y to be a number")
      end
      if direction.width ~= nil and type(direction.width) ~= "number" then
        error("hollow.term.split_pane(opts) expects opts.width to be a number")
      end
      if direction.height ~= nil and type(direction.height) ~= "number" then
        error("hollow.term.split_pane(opts) expects opts.height to be a number")
      end
      host_api.split_pane(direction)
      return nil
    end

    if direction ~= nil and type(direction) ~= "string" then
      error("hollow.term.split_pane(direction, opts) expects a string or table")
    end

    if opts ~= nil and type(opts) ~= "table" then
      error("hollow.term.split_pane(direction, opts) expects opts to be a table")
    end

    local payload = { direction = direction }
    if opts ~= nil then
      if opts.ratio ~= nil and type(opts.ratio) ~= "number" then
        error("hollow.term.split_pane(direction, opts) expects opts.ratio to be a number")
      end
      if opts.domain ~= nil and type(opts.domain) ~= "string" then
        error("hollow.term.split_pane(direction, opts) expects opts.domain to be a string")
      end
      if opts.cwd ~= nil and type(opts.cwd) ~= "string" then
        error("hollow.term.split_pane(direction, opts) expects opts.cwd to be a string")
      end
      if opts.floating ~= nil and type(opts.floating) ~= "boolean" then
        error("hollow.term.split_pane(direction, opts) expects opts.floating to be a boolean")
      end
      if opts.fullscreen ~= nil and type(opts.fullscreen) ~= "boolean" then
        error("hollow.term.split_pane(direction, opts) expects opts.fullscreen to be a boolean")
      end
      if opts.x ~= nil and type(opts.x) ~= "number" then
        error("hollow.term.split_pane(direction, opts) expects opts.x to be a number")
      end
      if opts.y ~= nil and type(opts.y) ~= "number" then
        error("hollow.term.split_pane(direction, opts) expects opts.y to be a number")
      end
      if opts.width ~= nil and type(opts.width) ~= "number" then
        error("hollow.term.split_pane(direction, opts) expects opts.width to be a number")
      end
      if opts.height ~= nil and type(opts.height) ~= "number" then
        error("hollow.term.split_pane(direction, opts) expects opts.height to be a number")
      end
      payload.ratio = opts.ratio
      payload.domain = opts.domain
      payload.cwd = opts.cwd
      payload.floating = opts.floating
      payload.fullscreen = opts.fullscreen
      payload.x = opts.x
      payload.y = opts.y
      payload.width = opts.width
      payload.height = opts.height
    end

    host_api.split_pane(payload)
    return nil
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

  function hollow.term.set_title(title, tab_id)
    if type(title) ~= "string" then
      error("hollow.term.set_title(title) expects a string")
    end
    if tab_id ~= nil then
      if not host_api.set_tab_title_by_id(tab_id, title) then
        error("unknown tab id: " .. tostring(tab_id))
      end
      return
    end
    host_api.set_tab_title(title)
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
    local direction = nil
    local amount = nil

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

  return {
    pane_snapshot = pane_snapshot,
    workspace_snapshot = workspace_snapshot,
    tab_snapshot = tab_snapshot,
  }
end

return M
