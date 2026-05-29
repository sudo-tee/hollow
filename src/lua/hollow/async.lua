local M = {}
local host_api = assert(rawget(_G, "host_api"), "global host_api bridge is missing")

function M.run(fn)
  if type(fn) ~= "function" then
    error("hollow.async.run(fn) expects a function")
  end

  local thread = coroutine.create(fn)
  local ok, err = coroutine.resume(thread)
  if not ok then
    error(err)
  end
  return thread
end

function M.await(register)
  if type(register) ~= "function" then
    error("hollow.async.await(register) expects a function")
  end

  local thread = coroutine.running()
  if thread == nil then
    error("hollow.async.await(...) must run inside hollow.async.run(...) or a coroutine")
  end

  local settled = false
  local ok_result = false
  local value_result = nil
  local waiting = false

  local function settle(ok, value)
    if settled then
      return
    end
    settled = true
    ok_result = ok
    value_result = value
    if waiting and coroutine.status(thread) == "suspended" then
      local resumed, err = coroutine.resume(thread, ok, value)
      if not resumed then
        return
      end
    end
  end

  register(function(value)
    settle(true, value)
  end, function(err)
    settle(false, err)
  end)

  if not settled then
    waiting = true
    ok_result, value_result = coroutine.yield()
  end

  if ok_result then
    return value_result
  end

  error(value_result)
end

function M.next_tick()
  return M.await(function(resolve)
    host_api.defer(resolve)
  end)
end

function M.promise(register)
  if type(register) ~= "function" then
    error("hollow.async.promise(register) expects a function")
  end

  local state = {
    status = "pending",
    value = nil,
    error = nil,
    listeners = {},
  }

  local promise = {}

  local function flush()
    local listeners = state.listeners
    state.listeners = {}
    for _, listener in ipairs(listeners) do
      if state.status == "fulfilled" then
        listener.resolve(state.value)
      else
        listener.reject(state.error)
      end
    end
  end

  local function resolve(value)
    if state.status ~= "pending" then
      return
    end
    state.status = "fulfilled"
    state.value = value
    flush()
  end

  local function reject(err)
    if state.status ~= "pending" then
      return
    end
    state.status = "rejected"
    state.error = err
    flush()
  end

  register(resolve, reject)

  function promise:status()
    return state.status
  end

  function promise:value()
    return state.value
  end

  function promise:error()
    return state.error
  end

  function promise:next(on_resolve, on_reject)
    if on_resolve ~= nil and type(on_resolve) ~= "function" then
      error("promise:next(on_resolve, on_reject) expects on_resolve to be a function or nil")
    end
    if on_reject ~= nil and type(on_reject) ~= "function" then
      error("promise:next(on_resolve, on_reject) expects on_reject to be a function or nil")
    end

    local function forward(resolve_next, reject_next)
      local function handle_resolve(value)
        if on_resolve == nil then
          resolve_next(value)
          return
        end
        local ok, result = pcall(on_resolve, value)
        if ok then
          resolve_next(result)
        else
          reject_next(result)
        end
      end

      local function handle_reject(err)
        if on_reject == nil then
          reject_next(err)
          return
        end
        local ok, result = pcall(on_reject, err)
        if ok then
          resolve_next(result)
        else
          reject_next(result)
        end
      end

      if state.status == "fulfilled" then
        handle_resolve(state.value)
      elseif state.status == "rejected" then
        handle_reject(state.error)
      else
        state.listeners[#state.listeners + 1] = {
          resolve = handle_resolve,
          reject = handle_reject,
        }
      end
    end

    return M.promise(forward)
  end

  function promise:catch(on_reject)
    return self:next(nil, on_reject)
  end

  function promise:await()
    return M.await(function(resolve_next, reject_next)
      if state.status == "fulfilled" then
        resolve_next(state.value)
      elseif state.status == "rejected" then
        reject_next(state.error)
      else
        state.listeners[#state.listeners + 1] = {
          resolve = resolve_next,
          reject = reject_next,
        }
      end
    end)
  end

  return promise
end

return M
