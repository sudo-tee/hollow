local M = {}

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

  local function adapt_builtin_payload(name, payload)
    if type(payload) ~= "table" then
      return payload
    end

    if name == "term:tab_activated" then
      return { tab = hollow.term.tab_by_id(payload.tab_id) }
    end
    if name == "term:tab_closed" then
      return { tab_id = payload.tab_id }
    end
    if name == "term:pane_focused" then
      return { pane = term_helpers.pane_snapshot(payload.pane_id) }
    end
    if name == "term:title_changed" then
      return {
        pane = term_helpers.pane_snapshot(payload.pane_id),
        old_title = payload.old_title,
        new_title = payload.new_title,
      }
    end
    if name == "term:cwd_changed" then
      return {
        pane = term_helpers.pane_snapshot(payload.pane_id),
        old_cwd = payload.old_cwd,
        new_cwd = payload.new_cwd,
      }
    end
    if name == "window:resized" then
      return { size = payload }
    end
    if name == "key:unhandled" then
      return {
        key = payload.key,
        mods = hollow.keymap._format_mods(payload.mods),
      }
    end
    if
      name == "topbar:hover"
      or name == "topbar:leave"
      or name == "topbar:click"
      or name == "bottombar:hover"
      or name == "bottombar:leave"
      or name == "bottombar:click"
    then
      return payload
    end
    return payload
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
