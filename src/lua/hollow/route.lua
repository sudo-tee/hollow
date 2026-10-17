local M = {}

---@param hollow Hollow
---@param host_api HollowHostBridge
---@return HollowRouteNamespace
function M.setup(hollow, host_api)
  local handlers = {}
  local dispatch_depth = 0
  local namespace = {}

  local function compact_handlers()
    local active = {}
    for _, entry in ipairs(handlers) do
      if entry.active then
        active[#active + 1] = entry
      end
    end
    handlers = active
  end

  local function dispatch(payload)
    if type(payload) ~= "table" then
      error("link route request must be a table")
    end

    local pane_id = payload.pane_id
    local request = {
      url = payload.url,
      text = payload.text or payload.url,
      pane_id = pane_id,
      pane = type(pane_id) == "number" and hollow.term.pane_by_id(pane_id) or nil,
      mods = hollow.keymap.format_mods(payload.mods),
      source = payload.source,
      kind = payload.kind,
      pattern_index = payload.pattern_index,
    }

    local handler_limit = #handlers
    dispatch_depth = dispatch_depth + 1
    local ok, result = pcall(function()
      for index = 1, handler_limit do
        local entry = handlers[index]
        if entry ~= nil and entry.active then
          local handler_result = entry.handler(request)
          if handler_result ~= nil and handler_result ~= false then
            return handler_result
          end
        end
      end
      return nil
    end)
    dispatch_depth = dispatch_depth - 1
    if dispatch_depth == 0 then
      compact_handlers()
    end
    if not ok then
      error(result, 0)
    end
    return result
  end

  host_api.link_route_handler(dispatch)

  ---Register synchronous handler for clickable links and quick-select opens.
  ---@param handler fun(request: HollowLinkRouteRequest): HollowLinkRouteResult|false|nil
  ---@return fun(): boolean unsubscribe
  function namespace.link(handler)
    if type(handler) ~= "function" then
      error("hollow.route.link(handler) expects a function")
    end

    local entry = {
      handler = handler,
      active = true,
    }
    handlers[#handlers + 1] = entry

    return function()
      if not entry.active then
        return false
      end
      entry.active = false
      if dispatch_depth == 0 then
        compact_handlers()
      end
      return true
    end
  end

  return namespace
end

return M
