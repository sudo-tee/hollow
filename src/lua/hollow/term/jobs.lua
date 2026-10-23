-- Owned terminal jobs share the CLI backend; native work is frame-queued.
local shape = require("hollow.shape")

local M = {}

---@param value string
---@return boolean
local function without_nul(value)
  return not value:find("%z")
end

---@param args string[]
---@return boolean
local function valid_argv(args)
  if #args == 0 or #args > 256 or args[1] == "" then
    return false
  end

  local bytes = 0
  for _, arg in ipairs(args) do
    bytes = bytes + #arg
  end

  return bytes <= 128 * 1024
end

local argument = shape.string():constraint(without_nul, "string without NUL")
local text = argument:constraint(function(value)
  return value ~= ""
end, "nonempty string")

-- Runtime validation belongs at the public boundary, not throughout job logic.
local spawn_options = shape.strict_object({
  argv = shape.array(argument):constraint(valid_argv, "1 to 256 arguments within 128 KiB"):optional(),
  cmd = text:optional(),
  cwd = text:optional(),
  domain = text:optional(),
  user_shell = shape.boolean():optional(),
}):constraint(function(opts)
  return (opts.argv ~= nil) ~= (opts.cmd ~= nil)
end, "exactly one of argv or cmd")

local wait_options = shape.strict_object({
  timeout_ms = shape.integer():min(0):optional(),
  auto_close = shape.boolean():optional(),
})

---@generic T: table
---@param value T
---@return T
local function copy(value)
  local result = {}
  for key, entry in pairs(value) do
    result[key] = entry
  end
  return result
end

---@param code string
---@param message string
---@param handle? HollowTermJobHandle
---@return HollowTermJobError
local function failure(code, message, handle)
  return { code = code, message = message, handle = handle }
end

-- Use coroutines to keep sequential workflows readable. Protected calls may
-- yield in LuaJIT; errors become promise rejections, including structured errors.
---@generic T
---@param async HollowAsyncNamespace
---@param work fun(): T
---@return HollowPromise<T>
local function run(async, work)
  return async.promise(function(resolve, reject)
    async.run(function()
      local ok, result = pcall(work)
      if ok then
        resolve(result)
      else
        reject(result)
      end
    end)
  end)
end

---@class HollowTermJobImpl: HollowTermJob
---@field private _host HollowHostBridge
---@field private _async HollowAsyncNamespace
---@field private _ready HollowPromise<HollowTermJobHandle>
---@field private _metadata? HollowTermJobHandle
local Job = {}
Job.__index = Job

---@param fields table
---@return HollowPromise<any>
function Job:_request(fields)
  return self._async.promise(function(resolve, reject)
    local function complete(response)
      if not response.success then
        reject(failure(response.status, response.error or "job request failed"))
        return
      end

      resolve(response.payload == nil and true or response.payload)
    end

    local ok, queued, err = pcall(self._host.term_job_request, fields, complete)
    if not ok then
      reject(failure("bridge_error", queued))
    elseif not queued then
      reject(failure("request_failed", err or "job request not queued"))
    end
  end)
end

---@return HollowPromise<HollowTermJobHandle>
function Job:ready()
  return self._ready
end

---@return HollowTermJobHandle|nil
function Job:handle()
  return self._metadata and copy(self._metadata) or nil
end

---@param kind "job_get"|"job_output"|"job_cleanup"
---@return HollowPromise<any>
function Job:_operation(kind)
  return run(self._async, function()
    self:ready():await()

    local handle = self._metadata
    ---@cast handle HollowTermJobHandle
    return self:_request({ kind = kind, id = handle.pane_id, token = handle.token }):await()
  end)
end

---@return HollowPromise<HollowTermJobState>
function Job:get()
  return self:_operation("job_get")
end

---@return HollowPromise<HollowTermJobOutput>
function Job:output()
  return self:_operation("job_output")
end

---@return HollowPromise<boolean>
function Job:cleanup()
  return self:_operation("job_cleanup")
end

---@param state HollowTermJobState
---@return HollowTermJobResult
function Job:_result(state)
  local result = copy(state)
  ---@cast result HollowTermJobResult
  local handle = self._metadata
  ---@cast handle HollowTermJobHandle

  result.tab_id = handle.tab_id
  result.workspace_id = handle.workspace_id
  result.token = handle.token

  return result
end

---@param opts? HollowTermJobWaitOptions
---@return HollowPromise<HollowTermJobResult>
function Job:wait(opts)
  opts = wait_options:parse(opts or {})
  local deadline = opts.timeout_ms and (self._host.now_ms() + opts.timeout_ms)
  local auto_close = opts.auto_close

  return run(self._async, function()
    while true do
      local state = self:get():await()

      if state.state == "exited" then
        local result = self:_result(state)
        if auto_close then
          self:cleanup():await()
          result.closed = true
        end
        return result
      end

      if deadline and self._host.now_ms() >= deadline then
        error(failure("timeout", "timed out waiting for job; job retained", self:handle()))
      end

      self._async.await(function(resume)
        self._host.defer(resume, 25)
      end)
    end
  end)
end

---@param opts HollowTermJobOptions
---@param async HollowAsyncNamespace
---@param host HollowHostBridge
---@return HollowTermJobImpl
local function spawn(opts, async, host)
  opts = spawn_options:parse(opts)

  ---@type HollowTermJobImpl
  local job = setmetatable({ _async = async, _host = host }, Job)
  job._ready = run(async, function()
    local handle = job:_request({
      kind = "job_spawn",
      argv = opts.argv and copy(opts.argv),
      cmd = opts.cmd,
      cwd = opts.cwd,
      domain = opts.domain,
      user_shell = opts.user_shell,
    }):await()

    job._metadata = copy(handle)
    return copy(handle)
  end)

  return job
end

---@param hollow Hollow
---@param host HollowHostBridge
function M.setup(hollow, host)
  hollow.term.jobs = {
    ---@param opts HollowTermJobOptions
    ---@return HollowTermJob
    spawn = function(opts)
      return spawn(opts, hollow.async, host)
    end,
  }
end

return M
