local M = {}

local host_api = assert(rawget(_G, "host_api"), "global host_api bridge is missing")
local async = require("hollow.async")

local function error_value(value, fallback)
  if type(value) == "table" and type(value.code) == "string" and type(value.message) == "string" then
    return value
  end
  return { code = fallback or "io_error", message = tostring(value) }
end

local function native(fn, ...)
  local ok, value, err = pcall(fn, ...)
  if not ok then
    return nil, error_value(value)
  end
  if value == nil then
    return nil, error_value(err)
  end
  return value, err
end

local function reject_later(err)
  return async.promise(function(_, reject)
    reject(err)
  end)
end

local function check_string(value, name, nonempty)
  if type(value) ~= "string" or (nonempty and value == "") then
    error(name .. " must be " .. (nonempty and "a non-empty string" or "a string"), 3)
  end
  if value:find("\0", 1, true) then error(name .. " must not contain NUL", 3) end
end

local function check_integer(value, name, minimum, maximum)
  if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge
    or value % 1 ~= 0 or value < minimum or value > maximum then
    error(name .. " must be an integer >= " .. minimum, 3)
  end
end

local function dense_strings(value, name)
  if type(value) ~= "table" then error(name .. " must be a dense array of strings", 3) end
  local count, maximum = 0, 0
  for key in pairs(value) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > 4096 then
      error(name .. " must be a dense array of strings", 3)
    end
    count = count + 1
    maximum = math.max(maximum, key)
  end
  if count ~= maximum then error(name .. " must be a dense array of strings", 3) end
  for i = 1, maximum do check_string(value[i], name .. "[" .. i .. "]", i == 1) end
  return value
end

local function validate_env(env)
  if env == nil then return nil end
  if type(env) ~= "table" then error("env must be a table", 3) end
  for key, value in pairs(env) do
    check_string(key, "env key", true)
    check_string(value, "env value", false)
    if key:find("=", 1, true) then error("env key must not contain '='", 3) end
  end
  return env
end

local function request(host, handle, op, opts)
  if host.closed then return reject_later({ code = "transport_disconnected", message = "host is closed" }) end
  local status, err = host:status()
  if status ~= "ready" then
    return reject_later(err or { code = status == "disconnected" and "transport_disconnected" or "not_ready", message = "host is not ready" })
  end

  local ticket, start_err = native(host_api.host_start, handle, op, opts)
  if ticket == nil then return reject_later(start_err) end

  local resolve, reject
  local promise = async.promise(function(r, j) resolve, reject = r, j end)
  local settled, canceled = false, false
  function promise:cancel()
    if settled or canceled then return false end
    local ok, cancel_err = native(host_api.host_cancel, ticket)
    if ok == nil then return nil, cancel_err end
    canceled = true
    return true
  end

  local function poll()
    if settled then return end
    local ok, result = pcall(host_api.host_poll, ticket)
    if not ok then
      settled = true
      reject(error_value(result))
    elseif result == nil then
      host_api.defer(poll, 10)
    elseif type(result) == "table" and result.error ~= nil then
      settled = true
      reject(error_value(result.error))
    else
      settled = true
      resolve(result)
    end
  end
  host_api.defer(poll, 10)
  return promise
end

local function make_host(id, handle)
  local host = { id = id, generation = handle.generation, closed = false }
  local function get_status()
    local status, err = native(host_api.host_status, handle)
    if status == nil then return nil, err end
    if status ~= "connecting" and status ~= "ready" and status ~= "disconnected" then
      return nil, { code = "io_error", message = "invalid native host status" }
    end
    return status, err and error_value(err) or nil
  end
  function host:status()
    return get_status()
  end
  function host:info()
    return request(self, handle, "info", {})
  end
  function host:exec(opts)
    if type(opts) ~= "table" then error("exec expects an options table", 2) end
    local argv = dense_strings(opts.argv, "argv")
    if #argv == 0 then error("argv must not be empty", 2) end
    local result = { argv = argv }
    if opts.cwd ~= nil then check_string(opts.cwd, "cwd", true); result.cwd = opts.cwd end
    if opts.env ~= nil then result.env = validate_env(opts.env) end
    if opts.timeout_ms ~= nil then check_integer(opts.timeout_ms, "timeout_ms", 1, 86400000); result.timeout_ms = opts.timeout_ms end
    if opts.output_limit ~= nil then check_integer(opts.output_limit, "output_limit", 0, 1048576); result.output_limit = opts.output_limit end
    return request(self, handle, "exec", result)
  end
  host.fs = {}
  function host.fs.stat(path)
    check_string(path, "path", true)
    return request(host, handle, "stat", { path = path })
  end
  function host.fs.list(path, opts)
    check_string(path, "path", true)
    opts = opts or {}
    if type(opts) ~= "table" then error("list options must be a table", 2) end
    local args = { path = path }
    if opts.offset ~= nil then check_integer(opts.offset, "offset", 0, 1000000); args.offset = opts.offset end
    if opts.limit ~= nil then check_integer(opts.limit, "limit", 1, 256); args.limit = opts.limit end
    return request(host, handle, "list", args)
  end
  function host.fs.read(path, opts)
    check_string(path, "path", true)
    opts = opts or {}
    if type(opts) ~= "table" then error("read options must be a table", 2) end
    local args = { path = path }
    if opts.offset ~= nil then check_integer(opts.offset, "offset", 0, 9007199254740991); args.offset = opts.offset end
    if opts.limit ~= nil then check_integer(opts.limit, "limit", 0, 16384); args.limit = opts.limit end
    return request(host, handle, "read", args)
  end
  function host:close()
    if self.closed then return true end
    local ok, err = native(host_api.host_close, handle)
    if ok ~= nil then self.closed = true; return true end
    return nil, err
  end
  return host
end

function M.connect(opts)
  if type(opts) ~= "table" then error("connect expects an options table", 2) end
  check_string(opts.id, "id", true)
  local id = opts.id
  local options = { id = id }
  if opts.backend == "local" then
    if opts.argv ~= nil then error("native-local hosts do not accept connector argv", 2) end
    options.backend = "local"
  elseif opts.connector ~= nil then
    -- Native code installs the agent through the connector, then runs it.
    if type(opts.connector) ~= "table" then error("connector must be a table", 2) end
    local argv = dense_strings(opts.connector.argv, "connector.argv")
    if #argv == 0 then error("connector.argv must not be empty", 2) end
    options.connector = { argv = { unpack(argv) }, remote_shell = opts.connector.remote_shell == true }
    if opts.agent ~= nil and type(opts.agent) ~= "table" then error("agent must be a table", 2) end
    options.agent = opts.agent
  else
    if opts.backend ~= nil and opts.backend ~= "agent" then error("unsupported host backend", 2) end
    local argv = dense_strings(opts.argv, "argv")
    if #argv == 0 then error("argv must not be empty", 2) end
    options.argv = { unpack(argv) }
  end
  local handle, err = native(host_api.host_connect, options)
  if handle == nil then return reject_later(err) end

  local resolve, reject
  local promise = async.promise(function(r, j) resolve, reject = r, j end)
  local done = false
  function promise:cancel()
    if done then return false end
    local closed, close_err = native(host_api.host_close, handle)
    if closed == nil then return nil, close_err end
    done = true
    reject({ code = "cancelled", message = "host connection cancelled" })
    return true
  end
  local function poll()
    if done then return end
    local status, status_err = native(host_api.host_status, handle)
    if status_err then done = true; reject(status_err); return end
    if status == "ready" then done = true; resolve(make_host(id, handle)); return end
    if status == "disconnected" then
      done = true
      reject(error_value(status_err or { code = "transport_disconnected", message = "host disconnected before becoming ready" }))
      return
    end
    if status ~= "connecting" then done = true; reject({ code = "io_error", message = "invalid native host status" }); return end
    host_api.defer(poll, 10)
  end
  host_api.defer(poll, 10)
  return promise
end

local local_connection

-- Explicit native-local counterpart; does not change hollow.process defaults.
function M.local_host()
  if local_connection then
    if local_connection:status() == "pending" then return local_connection end
    local value = local_connection:value()
    if value and not value.closed and value:status() == "ready" then return local_connection end
  end
  local_connection = M.connect({ id = "local", backend = "local" })
  return local_connection
end

-- Hosts reached through a connector; see hollow.host.options.target.
local function deployed(kind, opts)
  local target = require("hollow.host.options").target(kind, opts)
  check_string(opts.id, "id", true)
  if #opts.id > 256 then error("id must be at most 256 bytes", 2) end
  return M.connect({ id = opts.id, connector = target.connector, agent = target.agent })
end

function M.podman(opts) return deployed("podman", opts) end
function M.wsl(opts) return deployed("wsl", opts) end
function M.ssh(opts) return deployed("ssh", opts) end
function M.docker(opts) return deployed("docker", opts) end

return M
