local M = {}

local function ensure_channel(channel, fn_name)
  if type(channel) ~= "string" or channel == "" then
    error(fn_name .. " expects a non-empty string channel")
  end
end

local function ensure_handler(handler, fn_name)
  if type(handler) ~= "function" then
    error(fn_name .. " expects a function handler")
  end
end

local function serializable_error(value, path, seen)
  local value_type = type(value)
  if
    value == nil
    or value_type == "boolean"
    or value_type == "number"
    or value_type == "string"
  then
    return nil
  end
  if value_type ~= "table" then
    return path .. " contains unsupported " .. value_type
  end

  seen = seen or {}
  if seen[value] then
    return path .. " contains a circular reference"
  end
  seen[value] = true

  for key, child in pairs(value) do
    local key_type = type(key)
    if key_type ~= "string" and key_type ~= "number" then
      seen[value] = nil
      return path .. " contains unsupported table key type " .. key_type
    end
    local child_path = path .. "." .. tostring(key)
    local err = serializable_error(child, child_path, seen)
    if err ~= nil then
      seen[value] = nil
      return err
    end
  end

  seen[value] = nil
  return nil
end

---@param hollow Hollow
function M.setup(hollow, _host_api, _state, util, term_helpers)
  local query_handlers = {}
  local emit_handlers = {}

  local function pane_ctx(pane_id)
    if type(pane_id) ~= "number" or pane_id == 0 then
      return hollow.term.current_pane()
    end
    return term_helpers.pane_snapshot(pane_id) or hollow.term.current_pane()
  end

  local function sanitize_result(value)
    local err = serializable_error(value, "result")
    if err ~= nil then
      return nil, err
    end
    return util.clone_value(value)
  end

  local function event_payload(ctx)
    if type(ctx.payload) == "table" then
      return ctx.payload
    end
    return {}
  end

  local function target_pane_id(ctx, payload)
    if type(payload.pane_id) == "number" then
      return payload.pane_id
    end
    if type(payload.id) == "number" then
      return payload.id
    end
    return ctx.pane and ctx.pane.id or nil
  end

  function hollow.htp.on_query(channel, handler)
    ensure_channel(channel, "hollow.htp.on_query(channel, handler)")
    ensure_handler(handler, "hollow.htp.on_query(channel, handler)")
    query_handlers[channel] = handler
  end

  function hollow.htp.on_emit(channel, handler)
    ensure_channel(channel, "hollow.htp.on_emit(channel, handler)")
    ensure_handler(handler, "hollow.htp.on_emit(channel, handler)")
    emit_handlers[channel] = handler
  end

  function hollow.htp.off_query(channel)
    ensure_channel(channel, "hollow.htp.off_query(channel)")
    query_handlers[channel] = nil
  end

  function hollow.htp.off_emit(channel)
    ensure_channel(channel, "hollow.htp.off_emit(channel)")
    emit_handlers[channel] = nil
  end

  function hollow.htp._handle_query(channel, params, pane_id)
    local handler = query_handlers[channel]
    if handler == nil then
      return false, "unknown htp query: " .. tostring(channel)
    end

    local ctx = {
      pane = pane_ctx(pane_id),
      params = type(params) == "table" and params or {},
    }

    local ok, result = pcall(handler, ctx)
    if not ok then
      return false, tostring(result)
    end

    local cloned, err = sanitize_result(result)
    if err ~= nil then
      return false, err
    end

    return true, cloned
  end

  function hollow.htp._handle_emit(channel, payload, pane_id)
    local handler = emit_handlers[channel]
    if handler == nil then
      return false, "unknown htp event: " .. tostring(channel)
    end

    local ctx = {
      pane = pane_ctx(pane_id),
      payload = util.clone_value(payload),
    }

    local ok, err = pcall(handler, ctx)
    if not ok then
      return false, tostring(err)
    end

    return true
  end

  hollow.htp.on_query("pane", function(ctx)
    local pane_id = ctx.params and ctx.params.id or nil
    if type(pane_id) == "number" then
      return term_helpers.pane_snapshot(pane_id)
    end
    return ctx.pane
  end)

  hollow.htp.on_query("pane_text", function(ctx)
    local pane_id = ctx.params and ctx.params.id or nil
    if type(pane_id) ~= "number" then
      pane_id = ctx.pane and ctx.pane.id or nil
    end
    if pane_id == nil then
      return ""
    end
    return hollow.term.get_pane_text(pane_id) or ""
  end)

  hollow.htp.on_query("current_pane", function()
    return hollow.term.current_pane()
  end)

  hollow.htp.on_query("current_tab", function()
    return hollow.term.current_tab()
  end)

  hollow.htp.on_query("tabs", function()
    return hollow.term.tabs()
  end)

  hollow.htp.on_query("tab", function(ctx)
    local tab_id = ctx.params and ctx.params.id or nil
    if type(tab_id) ~= "number" then
      return hollow.term.current_tab()
    end
    return hollow.term.tab_by_id(tab_id)
  end)

  hollow.htp.on_query("panes", function()
    local panes = {}
    for _, tab in ipairs(hollow.term.tabs()) do
      for _, pane in ipairs(tab.panes) do
        panes[#panes + 1] = pane
      end
    end
    return panes
  end)

  hollow.htp.on_query("workspaces", function()
    return hollow.term.workspaces()
  end)

  hollow.htp.on_query("current_workspace", function()
    return hollow.term.current_workspace()
  end)

  hollow.htp.on_query("workspace", function(ctx)
    local workspace_id = ctx.params and ctx.params.id or nil
    if type(workspace_id) ~= "number" then
      return hollow.term.current_workspace()
    end
    return hollow.term.workspace_by_id(workspace_id)
  end)

  hollow.htp.on_query("current_domain", function()
    return hollow.term.current_domain()
  end)

  hollow.htp.on_query("echo", function(ctx)
    return ctx.params
  end)

  hollow.htp.on_emit("split_pane", function(ctx)
    local payload = event_payload(ctx)
    hollow.term.split_pane({
      direction = payload.direction,
      ratio = payload.ratio,
      domain = payload.domain,
      cwd = payload.cwd,
      floating = payload.floating,
      fullscreen = payload.fullscreen,
      x = payload.x,
      y = payload.y,
      width = payload.width,
      height = payload.height,
      -- accept either `command` or shorthand `cmd` from HTP payloads
      command = payload.command or payload.cmd,
    })
  end)

  hollow.htp.on_emit("new_tab", function(ctx)
    local payload = event_payload(ctx)
    -- support opening a new tab and running a command (useful for floating panes)
    hollow.term.new_tab({
      domain = payload.domain,
      -- accept either `command` or shorthand `cmd`
      command = payload.command or payload.cmd,
    })
  end)

  hollow.htp.on_emit("close_tab", function(ctx)
    local payload = event_payload(ctx)
    local tab_id = payload.tab_id or payload.id
    if type(tab_id) == "number" then
      hollow.term.close_tab(tab_id)
      return
    end
    local current = hollow.term.current_tab()
    if current ~= nil then
      hollow.term.close_tab(current.id)
    end
  end)

  hollow.htp.on_emit("focus_tab", function(ctx)
    local payload = event_payload(ctx)
    local tab_id = payload.tab_id or payload.id
    if type(tab_id) ~= "number" then
      error("focus_tab requires a tab id")
    end
    hollow.term.focus_tab(tab_id)
  end)

  hollow.htp.on_emit("next_tab", function()
    hollow.term.next_tab()
  end)

  hollow.htp.on_emit("prev_tab", function()
    hollow.term.prev_tab()
  end)

  hollow.htp.on_emit("set_tab_title", function(ctx)
    local payload = event_payload(ctx)
    if type(payload.title) ~= "string" then
      error("set_tab_title requires a string title")
    end
    hollow.term.set_title(payload.title, payload.tab_id or payload.id)
  end)

  hollow.htp.on_emit("new_workspace", function(ctx)
    local payload = event_payload(ctx)
    hollow.term.new_workspace({
      cwd = payload.cwd,
      domain = payload.domain,
      command = payload.command or payload.cmd,
      name = payload.name,
    })
  end)

  hollow.htp.on_emit("close_workspace", function(ctx)
    local payload = event_payload(ctx)
    hollow.term.close_workspace(payload.workspace_id or payload.id)
  end)

  hollow.htp.on_emit("next_workspace", function()
    hollow.term.next_workspace()
  end)

  hollow.htp.on_emit("prev_workspace", function()
    hollow.term.prev_workspace()
  end)

  hollow.htp.on_emit("switch_workspace", function(ctx)
    local payload = event_payload(ctx)
    if type(payload.index) ~= "number" then
      error("switch_workspace requires an index")
    end
    hollow.term.switch_workspace(payload.index)
  end)

  hollow.htp.on_emit("set_workspace_name", function(ctx)
    local payload = event_payload(ctx)
    if type(payload.name) ~= "string" then
      error("set_workspace_name requires a string name")
    end
    local workspace_id = payload.workspace_id or payload.id
    if workspace_id ~= nil then
      local workspace = hollow.term.workspace_by_id(workspace_id)
      local current = hollow.term.current_workspace()
      if workspace == nil then
        error("unknown workspace id: " .. tostring(workspace_id))
      end
      if current == nil or current.id ~= workspace.id then
        error("set_workspace_name only supports the active workspace")
      end
    end
    hollow.term.set_workspace_name(payload.name)
  end)

  hollow.htp.on_emit("toggle_pane_maximized", function(ctx)
    local payload = event_payload(ctx)
    hollow.term.toggle_pane_maximized(target_pane_id(ctx, payload), {
      show_background = payload.show_background == true,
    })
  end)

  hollow.htp.on_emit("close_pane", function(ctx)
    local payload = event_payload(ctx)
    hollow.term.close_pane(target_pane_id(ctx, payload))
  end)

  hollow.htp.on_emit("focus_pane", function(ctx)
    local payload = event_payload(ctx)
    if type(payload.direction) ~= "string" then
      error("focus_pane requires a direction")
    end
    hollow.term.focus_pane(payload.direction)
  end)

  hollow.htp.on_emit("set_pane_floating", function(ctx)
    local payload = event_payload(ctx)
    hollow.term.set_pane_floating(target_pane_id(ctx, payload), payload.floating ~= false)
  end)

  hollow.htp.on_emit("set_floating_pane_bounds", function(ctx)
    local payload = event_payload(ctx)
    local pane_id = target_pane_id(ctx, payload)
    if type(pane_id) ~= "number" then
      error("set_floating_pane_bounds requires a pane id")
    end
    hollow.term.set_floating_pane_bounds(pane_id, {
      x = payload.x,
      y = payload.y,
      width = payload.width,
      height = payload.height,
    })
  end)

  hollow.htp.on_emit("move_pane", function(ctx)
    local payload = event_payload(ctx)
    hollow.term.move_pane({
      pane_id = target_pane_id(ctx, payload),
      direction = payload.direction,
      amount = payload.amount,
    })
  end)

  hollow.htp.on_emit("resize_pane", function(ctx)
    local payload = event_payload(ctx)
    if type(payload.direction) == "string" and type(payload.delta) == "number" then
      hollow.term.resize_pane(payload.direction, payload.delta)
      return
    end
    if type(payload.axis) == "string" and type(payload.delta) == "number" then
      hollow.term.resize_pane(payload.axis, payload.delta)
      return
    end
    error("resize_pane requires direction/axis and delta")
  end)

  hollow.htp.on_emit("send_text", function(ctx)
    local payload = event_payload(ctx)
    if type(payload.text) ~= "string" then
      error("send_text requires a string text")
    end
    hollow.term.send_text(payload.text, target_pane_id(ctx, payload))
  end)

  hollow.htp.on_emit("reload_config", function()
    hollow.term.reload_config()
  end)

  hollow.htp.on_emit("set_theme", function(ctx)
    local payload = event_payload(ctx)
    local name = payload.name or payload.theme
    if type(name) ~= "string" then
      error("set_theme requires a string name")
    end
    hollow.term.set_theme(name)
  end)

  hollow.htp.on_emit("scroll", function(ctx)
    local payload = event_payload(ctx)
    local where = payload.to or payload.direction
    if type(where) ~= "string" then
      error("scroll requires a target")
    end
    hollow.term.scroll(where)
  end)

  hollow.htp.on_emit("command_started", function(ctx)
    local payload = event_payload(ctx)
    hollow.term.set_pane_foreground_process(target_pane_id(ctx, payload), payload.command)
  end)

  hollow.htp.on_emit("command_ended", function(ctx)
    local payload = event_payload(ctx)
    hollow.term.set_pane_foreground_process(target_pane_id(ctx, payload), nil)
  end)
end

return M
