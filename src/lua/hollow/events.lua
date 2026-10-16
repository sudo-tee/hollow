local M = {}
local util = require("hollow.util")

---@param hollow Hollow
---@param state HollowState
---@param term_helpers table
function M.setup(hollow, state, term_helpers)
  local event_handles = state.events.handles
  local event_listeners = state.events.listeners
  local filter_listeners = {}
  local filtering = {}

  local function remove_event_handle(handle)
    local listener = event_handles[handle]
    if listener == nil then
      return false
    end

    event_handles[handle] = nil
    local registry = listener.filter and filter_listeners or event_listeners
    local listeners = registry[listener.name]
    if listeners ~= nil then
      for i, item in ipairs(listeners) do
        if item == handle then
          table.remove(listeners, i)
          break
        end
      end
      if #listeners == 0 then
        registry[listener.name] = nil
      end
    end
    return true
  end

  local function emit_event(name, payload, allow_builtin)
    if state.events.builtin_names[name] and not allow_builtin then
      error("cannot emit built-in event from Lua: " .. tostring(name))
    end

    local listeners = event_listeners[name]
    if listeners == nil then
      return
    end

    local e = payload
    if e == nil then
      e = {}
    elseif type(e) ~= "table" then
      e = { value = e }
    end

    local handles = {}
    for i, handle in ipairs(listeners) do
      handles[i] = handle
    end
    for _, handle in ipairs(handles) do
      local listener = event_handles[handle]
      if listener ~= nil then
        listener.handler(e)
        if listener.once then
          remove_event_handle(handle)
        end
      end
    end
  end

  local function pane(p)
    return term_helpers.pane_snapshot(p)
  end

  local function adapt_tab_activated(payload)
    return { tab = hollow.term.tab_by_id(payload.tab_id) }
  end
  local function adapt_workspace_new(payload)
    local w = hollow.term.workspaces()[payload.workspace_index + 1]
    return { workspace = w, index = payload.workspace_index + 1 }
  end
  local function adapt_workspace_closed(payload)
    return { name = payload.name }
  end
  local function adapt_tab_closed(payload)
    return { tab_id = payload.tab_id }
  end
  local function adapt_pane_focused(payload)
    return { pane = pane(payload.pane_id) }
  end
  local function adapt_pane_exited(payload)
    term_helpers.clear_running_command(payload.pane_id)
    return { pane = pane(payload.pane_id), status = payload.status }
  end
  local function adapt_pane_closed(payload)
    local snapshot = pane(payload.pane_id)
    term_helpers.forget_pane(payload.pane_id)
    return { pane = snapshot }
  end
  local function adapt_title_changed(payload)
    return {
      pane = pane(payload.pane_id),
      old_title = payload.old_title,
      new_title = payload.new_title,
    }
  end
  local function adapt_cwd_changed(payload)
    return { pane = pane(payload.pane_id), old_cwd = payload.old_cwd, new_cwd = payload.new_cwd }
  end
  local function adapt_foreground_changed(payload)
    return {
      pane = pane(payload.pane_id),
      old_process = payload.old_process,
      new_process = payload.new_process,
    }
  end
  local function adapt_command_started(payload)
    return {
      pane = pane(payload.pane_id),
      command = payload.command,
      cwd = payload.cwd,
    }
  end
  local function adapt_command_finished(payload)
    return {
      pane = pane(payload.pane_id),
      command = payload.command,
      status = payload.status,
      took_ms = payload.took_ms,
    }
  end
  local function adapt_term_notification(payload)
    return {
      pane = pane(payload.pane_id),
      title = payload.title,
      message = payload.message,
      level = payload.level,
      id = payload.id,
      ttl_ms = payload.ttl_ms,
      close = payload.close == true,
    }
  end
  local function adapt_window_resized(payload)
    return { size = payload }
  end
  local function adapt_copy_mode_changed(payload)
    local cm = payload.copy_mode or payload
    return {
      active = cm.active == true,
      query = cm.query or "",
      match_count = cm.match_count or 0,
      match_index = cm.match_index,
      selecting = cm.selecting == true,
      block = cm.block == true,
    }
  end
  local function adapt_key_unhandled(payload)
    return { key = payload.key, mods = hollow.keymap.format_mods(payload.mods) }
  end
  local function adapt_files_dropped(payload)
    return {
      paths = payload.paths,
      pane = pane(payload.pane_id),
      pane_id = payload.pane_id,
      x = payload.x,
      y = payload.y,
      text = payload.text,
    }
  end

  local function adapt_bar_node(payload)
    return {
      id = payload.id,
      mods = hollow.keymap.format_mods(payload.mods),
      shifted = payload.shifted == true,
    }
  end

  local adapters = {
    ["term:tab_activated"] = adapt_tab_activated,
    ["workspace:new"] = adapt_workspace_new,
    ["workspace:changed"] = adapt_workspace_new,
    ["workspace:closed"] = adapt_workspace_closed,
    ["term:tab_closed"] = adapt_tab_closed,
    ["term:pane_focused"] = adapt_pane_focused,
    ["term:pane_created"] = adapt_pane_focused,
    ["term:pane_exited"] = adapt_pane_exited,
    ["term:pane_closed"] = adapt_pane_closed,
    ["term:pane_layout_changed"] = adapt_pane_focused,
    ["term:title_changed"] = adapt_title_changed,
    ["term:cwd_changed"] = adapt_cwd_changed,
    ["term:foreground_process_changed"] = adapt_foreground_changed,
    ["term:command_started"] = adapt_command_started,
    ["term:command_finished"] = adapt_command_finished,
    ["term:program_status_changed"] = adapt_pane_focused,
    ["term:bell"] = adapt_pane_focused,
    ["term:notification"] = adapt_term_notification,
    ["window:resized"] = adapt_window_resized,
    ["copy_mode:changed"] = adapt_copy_mode_changed,
    ["key:unhandled"] = adapt_key_unhandled,
    ["window:files_dropped"] = adapt_files_dropped,
    ["topbar:hover"] = adapt_bar_node,
    ["topbar:click"] = adapt_bar_node,
    ["bottombar:hover"] = adapt_bar_node,
    ["bottombar:click"] = adapt_bar_node,
  }

  local function adapt_builtin_payload(name, payload)
    if type(payload) ~= "table" then
      return payload
    end
    local adapter = adapters[name]
    return adapter and adapter(payload) or payload
  end

  function hollow.events.on(name, handler)
    if type(name) ~= "string" then
      error("event name must be a string")
    end
    if type(handler) ~= "function" then
      error("event handler must be a function")
    end

    local handle = state.events.next_handle
    state.events.next_handle = state.events.next_handle + 1
    event_handles[handle] = { name = name, handler = handler, once = false }
    event_listeners[name] = event_listeners[name] or {}
    table.insert(event_listeners[name], handle)
    return handle
  end

  function hollow.events.off(handle)
    remove_event_handle(handle)
  end

  function hollow.events.once(name, handler)
    local handle = hollow.events.on(name, handler)
    event_handles[handle].once = true
    return handle
  end

  function hollow.events.emit(name, payload)
    emit_event(name, payload, false)
  end

  function hollow.events.filter(name, handler)
    if type(name) ~= "string" or name == "" then
      error("filter name must be a non-empty string")
    end
    if type(handler) ~= "function" then
      error("filter handler must be a function")
    end
    local handle = state.events.next_handle
    state.events.next_handle = handle + 1
    event_handles[handle] = { name = name, handler = handler, filter = true }
    filter_listeners[name] = filter_listeners[name] or {}
    table.insert(filter_listeners[name], handle)
    return handle
  end

  local function apply_filters(name, payload, validate, budget_ms)
    if type(name) ~= "string" or name == "" then
      error("filter name must be a non-empty string")
    end
    if type(payload) ~= "table" then
      error("filter payload must be a table")
    end
    -- A nested operation runs raw rather than recursively invoking its filters.
    if filtering[name] then
      return payload
    end
    local handles = {}
    for i, handle in ipairs(filter_listeners[name] or {}) do
      handles[i] = handle
    end
    filtering[name] = true
    local ok, result = pcall(function()
      local current = payload
      for _, handle in ipairs(handles) do
        local listener = event_handles[handle]
        if listener then
          local started = util.host_now_ms(state.host_api)
          local accepted, value = pcall(function()
            local candidate = listener.handler(util.clone_value(current))
            if candidate == nil then
              return current
            end
            if type(candidate) ~= "table" then
              error("filter must return a table or nil")
            end
            if validate then
              validate(candidate, current)
            end
            return util.clone_value(candidate)
          end)
          if budget_ms and util.host_now_ms(state.host_api) - started > budget_ms then
            accepted, value = false, "filter exceeded " .. budget_ms .. " ms budget"
          end
          if accepted then
            current = value
          else
            print("hollow.events.filter(" .. name .. "): " .. tostring(value))
          end
        end
      end
      return current
    end)
    filtering[name] = nil
    if not ok then
      error(result, 0)
    end
    return result
  end

  function hollow.events.apply_filters(name, payload)
    return apply_filters(name, payload)
  end

  -- Native producer owns the schema. Environment is an override map, not the
  -- inherited process environment. Transport/terminal identity stays intact.
  local function protected_env(key)
    local upper = key:upper()
    return upper:match("^HOLLOW_")
      or upper == "TERM"
      or upper == "COLORTERM"
      or upper == "TERM_PROGRAM"
  end

  function hollow._filter_spawn(spec)
    return apply_filters("term:spawn", spec, function(candidate, previous)
      for key in pairs(candidate) do
        if key ~= "shell" and key ~= "domain" and key ~= "cwd" and key ~= "env" then
          error("unknown spawn field: " .. tostring(key))
        end
      end
      if candidate.shell ~= previous.shell or candidate.domain ~= previous.domain then
        error("spawn shell and domain are read-only")
      end
      if
        candidate.cwd ~= nil
        and (
          type(candidate.cwd) ~= "string"
          or candidate.cwd == ""
          or candidate.cwd:find("\0", 1, true)
        )
      then
        error("spawn cwd must be a non-empty string or nil")
      end
      if type(candidate.env) ~= "table" then
        error("spawn env must be a table")
      end
      for key, value in pairs(candidate.env) do
        if
          type(key) ~= "string"
          or key == ""
          or key:find("=", 1, true)
          or key:find("\0", 1, true)
          or type(value) ~= "string"
          or value:find("\0", 1, true)
        then
          error("spawn env must contain valid string keys and values")
        end
      end
      for key, value in pairs(previous.env) do
        if protected_env(key) and candidate.env[key] ~= value then
          error("protected spawn environment variable: " .. key)
        end
      end
      for key, value in pairs(candidate.env) do
        if protected_env(key) and previous.env[key] ~= value then
          error("protected spawn environment variable: " .. key)
        end
      end
    end, 50)
  end

  return {
    remove_event_handle = remove_event_handle,
    emit_event = emit_event,
    adapt_builtin_payload = adapt_builtin_payload,
  }
end

return M
