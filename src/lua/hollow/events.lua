local M = {}

---@param hollow Hollow
---@param state HollowState
---@param term_helpers table
function M.setup(hollow, state, term_helpers)
  local event_handles = state.events.handles
  local event_listeners = state.events.listeners

  local function remove_event_handle(handle)
    local listener = event_handles[handle]
    if listener == nil then
      return false
    end

    event_handles[handle] = nil
    local listeners = event_listeners[listener.name]
    if listeners ~= nil then
      for i, item in ipairs(listeners) do
        if item == handle then
          table.remove(listeners, i)
          break
        end
      end
      if #listeners == 0 then
        event_listeners[listener.name] = nil
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
  local function adapt_title_changed(payload)
    return { pane = pane(payload.pane_id), old_title = payload.old_title, new_title = payload.new_title }
  end
  local function adapt_cwd_changed(payload)
    return { pane = pane(payload.pane_id), old_cwd = payload.old_cwd, new_cwd = payload.new_cwd }
  end
  local function adapt_foreground_changed(payload)
    return { pane = pane(payload.pane_id), old_process = payload.old_process, new_process = payload.new_process }
  end
  local function adapt_window_resized(payload)
    return { size = payload }
  end
  local function adapt_copy_mode_changed(payload)
    local cm = payload.copy_mode or payload
    return { active = cm.active == true, query = cm.query or "", match_count = cm.match_count or 0, match_index = cm.match_index, selecting = cm.selecting == true, block = cm.block == true }
  end
  local function adapt_key_unhandled(payload)
    return { key = payload.key, mods = hollow.keymap.format_mods(payload.mods) }
  end

  local adapters = {
    ["term:tab_activated"] = adapt_tab_activated,
    ["workspace:new"] = adapt_workspace_new,
    ["workspace:changed"] = adapt_workspace_new,
    ["workspace:closed"] = adapt_workspace_closed,
    ["term:tab_closed"] = adapt_tab_closed,
    ["term:pane_focused"] = adapt_pane_focused,
    ["term:pane_layout_changed"] = adapt_pane_focused,
    ["term:title_changed"] = adapt_title_changed,
    ["term:cwd_changed"] = adapt_cwd_changed,
    ["term:foreground_process_changed"] = adapt_foreground_changed,
    ["term:bell"] = adapt_pane_focused,
    ["window:resized"] = adapt_window_resized,
    ["copy_mode:changed"] = adapt_copy_mode_changed,
    ["key:unhandled"] = adapt_key_unhandled,
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

  return {
    remove_event_handle = remove_event_handle,
    emit_event = emit_event,
    adapt_builtin_payload = adapt_builtin_payload,
  }
end

return M
