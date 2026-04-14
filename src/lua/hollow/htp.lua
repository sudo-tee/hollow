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
  if value == nil or value_type == "boolean" or value_type == "number" or value_type == "string" then
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

function M.setup(hollow, host_api, state, util, term_helpers)
  local _ = host_api
  local __ = state

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
    return ctx.pane
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

  hollow.htp.on_query("workspaces", function()
    return hollow.term.workspaces()
  end)

  hollow.htp.on_query("current_workspace", function()
    return hollow.term.current_workspace()
  end)

  hollow.htp.on_query("echo", function(ctx)
    return ctx.params
  end)
end

return M
