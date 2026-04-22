local M = {}

---@param hollow Hollow
---@param host_api HollowHostBridge
---@param state HollowState
function M.setup(hollow, host_api, state)
  function hollow.config.set(opts)
    if type(opts) ~= "table" then
      error("hollow.config.set(opts) expects a table")
    end
    hollow.util.merge_tables(state.config.values, hollow.util.clone_value(opts))
    host_api.set_config(opts)
  end

  function hollow.config.get(key)
    return state.config.values[key]
  end

  function hollow.config.snapshot()
    return hollow.util.clone_value(state.config.values)
  end

  function hollow.config.reload()
    if not host_api.reload_config() then
      error("hollow.config.reload() failed")
    end
  end
end

return M
