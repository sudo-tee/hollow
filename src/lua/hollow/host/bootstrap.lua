-- Shared Linux-agent bootstrap engine for native container and distro hosts.
local M = {}
local async = require("hollow.async")
local artifact_bundle = require("hollow.host.artifacts")
local host_api = assert(rawget(_G, "host_api"), "global host_api bridge is missing")
local LIMIT = 16384

local VERIFY = 'set -eu; [ ! -L "$1" ] && [ -x "$1" ] || exit 1; got=$(sha256sum < "$1"); [ "${got%% *}" = "$2" ]'
local INSTALL = 'set -eu; [ ! -L "$1" ] || exit 44; got=$(sha256sum < "$1"); [ "${got%% *}" = "$2" ] || exit 43; chmod 700 -- "$1"; mv -fT -- "$1" "$3"; test -x "$3"'

function M.string(value, name)
  if type(value) ~= "string" or value == "" or value:find("\0", 1, true) then
    error(name .. " must be a non-empty string without NUL", 3)
  end
  return value
end

function M.configuration(options, executable_key, default_executable)
  if type(options) ~= "table" then error("host expects an options table", 3) end
  local copy = {
    id = M.string(options.id, "id"),
    executable = M.string(options[executable_key] or default_executable, executable_key),
    timeout_ms = options.timeout_ms or 60000,
  }
  if #copy.id > 256 then error("id must be at most 256 bytes", 3) end
  if type(copy.timeout_ms) ~= "number" or copy.timeout_ms ~= copy.timeout_ms or copy.timeout_ms % 1 ~= 0
      or copy.timeout_ms < 1 or copy.timeout_ms > 300000 then
    error("timeout_ms must be an integer from 1 to 300000", 3)
  end
  if options.agent_dir ~= nil then
    if not artifact_bundle.absolute(options.agent_dir) then error("agent_dir must be a client-native absolute path", 3) end
    copy.agent_dir = options.agent_dir
  end
  if options.agent_path ~= nil then
    copy.agent_path = M.string(options.agent_path, "agent_path")
    if copy.agent_path:sub(1, 1) ~= "/" then error("agent_path must be an absolute Linux path", 3) end
  elseif options.artifacts ~= nil then
    if type(options.artifacts) ~= "table" then error("artifacts must be a table", 3) end
    copy.artifacts = {}
    for arch, item in pairs(options.artifacts) do
      if arch ~= "x86_64" and arch ~= "aarch64" then error("unsupported artifact architecture", 3) end
      if type(item) ~= "table" then error("artifact must be a table", 3) end
      local path = M.string(item.path, "artifact path")
      if path:sub(1, 1) ~= "/" and not path:match("^[A-Za-z]:[/\\]") and not path:match("^\\\\") then
        error("artifact path must be client-native absolute", 3)
      end
      local digest = M.string(item.sha256, "artifact sha256")
      if #digest ~= 64 or not digest:match("^%x+$") then error("artifact sha256 must be 64 hex digits", 3) end
      copy.artifacts[arch] = { path = path, sha256 = digest:lower() }
    end
  end
  return copy
end

function M.connect(hosts, opts, adapter)
  local resolve, reject
  local promise = async.promise(function(r, j) resolve, reject = r, j end)
  local deadline = host_api.now_ms() + opts.timeout_ms
  local settled, active, cancel_active = false, nil, false
  local native_host, temp_path
  local cleanup_started = false
  local function failure(code, message) return { code = code, message = tostring(message):sub(1, LIMIT) } end
  local function cleanup()
    if not settled or active or not temp_path or not native_host or cleanup_started then return end
    cleanup_started = true
    local argv = { opts.executable }
    for _, value in ipairs(adapter.remote({ "rm", "-f", "--", temp_path })) do argv[#argv + 1] = value end
    local ok, p = pcall(native_host.exec, native_host, { argv = argv, timeout_ms = 5000, output_limit = LIMIT })
    if ok then p:next(function() end, function() end) end
  end
  local function stop(err)
    if settled then return end
    settled = true
    if active and cancel_active and active.cancel then pcall(active.cancel, active) end
    cleanup()
    reject(err)
  end
  local function guarded(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then stop(failure("io_error", type(err) == "table" and err.message or err)) end
  end
  local function remaining() return math.floor(deadline - host_api.now_ms()) end
  local function native_error(err, fallback)
    local code = type(err) == "table" and err.code
    if code == "not_found" then code = "connector_unavailable"
    elseif code ~= "timeout" and code ~= "cancelled" and code ~= "resource_exhausted" and code ~= "permission_denied" then code = fallback end
    return failure(code, type(err) == "table" and err.message or err)
  end
  local function execute(argv, code, next_step, allow_failure, track_result)
    if settled then cleanup(); return end
    local left = remaining()
    if left <= 0 then stop(failure("timeout", adapter.label .. " bootstrap deadline exceeded")); return end
    local ok, p = pcall(native_host.exec, native_host, { argv = argv, timeout_ms = left, output_limit = LIMIT })
    if not ok then stop(native_error(p, code)); return end
    active, cancel_active = p, true
    p:next(function(result)
      if active == p then active = nil end
      if track_result then guarded(track_result, result) end
      if settled then cleanup(); return end
      if remaining() <= 0 then stop(failure("timeout", adapter.label .. " bootstrap deadline exceeded")); return end
      if type(result) ~= "table" or type(result.exit_code) ~= "number" then stop(failure(code, "invalid process result")); return end
      if result.exit_code ~= 0 and not allow_failure then stop(failure(code, result.stderr or (adapter.label .. " command failed"))); return end
      guarded(next_step, result)
    end, function(err)
      if active == p then active = nil end
      if settled then cleanup() else stop(native_error(err, code)) end
    end)
  end
  local function command(args, code, next_step, allow_failure, track_result)
    local argv = { opts.executable }
    for _, value in ipairs(args) do argv[#argv + 1] = value end
    execute(argv, code, next_step, allow_failure, track_result)
  end
  local ctx = {
    command = command,
    exec = execute, -- Additional local tools share the same deadline/cancel slot.
    fail = function(code, message) stop(failure(code, message)) end,
  }
  local function transport(path)
    local argv = { opts.executable }
    for _, value in ipairs(adapter.transport(path)) do argv[#argv + 1] = value end
    local ok, p = pcall(hosts.connect, { id = opts.id, argv = argv })
    if not ok then stop(native_error(p, "agent_install_unavailable")); return end
    active, cancel_active = p, true
    p:next(function(host)
      if active == p then active = nil end
      if not settled and remaining() <= 0 then stop(failure("timeout", adapter.label .. " bootstrap deadline exceeded")) end
      if settled then if host and host.close then pcall(host.close, host) end; cleanup(); return end
      settled = true
      resolve(host)
    end, function(err)
      if active == p then active = nil end
      if settled then cleanup() else stop(native_error(err, "agent_install_unavailable")) end
    end)
  end
  local function deploy(arch)
    if opts.agent_path then command(adapter.remote({ "test", "-x", opts.agent_path }), "agent_install_unavailable", function() transport(opts.agent_path) end); return end
    local artifact = opts.artifacts[arch]
    if not artifact then stop(failure("agent_install_unavailable", "no configured artifact for " .. arch)); return end
    command(adapter.remote({ "/bin/sh", "-c", 'printf "%s" "$HOME"' }), "agent_install_unavailable", function(result)
      local home = result.stdout
      if type(home) ~= "string" or home:sub(1, 1) ~= "/" or home:find("\0", 1, true) then
        stop(failure("agent_install_unavailable", "Linux user has no absolute HOME; configure agent_path")); return
      end
      local parent = home .. "/.cache/hollow/agents/linux-" .. arch .. "/" .. artifact.sha256
      local target = parent .. "/hollow-agent"
      command(adapter.remote({ "/bin/sh", "-c", VERIFY, "hollow-bootstrap", target, artifact.sha256 }), "agent_install_unavailable", function(verified)
        if verified.exit_code == 0 then transport(target); return end
        command(adapter.remote({ "mkdir", "-p", "--", parent }), "agent_install_unavailable", function()
          command(adapter.remote({ "mktemp", parent .. "/.upload-XXXXXXXXXXXX" }), "agent_install_unavailable", function()
            if not temp_path then stop(failure("agent_install_unavailable", "invalid mktemp response")); return end
            adapter.upload(ctx, artifact.path, temp_path, function(err)
              if settled then cleanup(); return end
              if err then stop(native_error(err, "agent_install_unavailable")); return end
              command(adapter.remote({ "/bin/sh", "-c", INSTALL, "hollow-bootstrap", temp_path, artifact.sha256, target }), "agent_install_unavailable", function(installed)
                if installed.exit_code ~= 0 then
                  stop(failure(installed.exit_code == 43 and "checksum_mismatch" or "agent_install_unavailable", installed.stderr or "agent installation failed")); return
                end
                temp_path = nil
                transport(target)
              end, true)
            end)
          end, false, function(created)
            if type(created) ~= "table" or created.exit_code ~= 0 or type(created.stdout) ~= "string" then return end
            local output = created.stdout
            if output:sub(-1) ~= "\n" then return end
            local path = output:sub(1, -2)
            local prefix = parent .. "/.upload-"
            local suffix = path:sub(#prefix + 1)
            if path:sub(1, #prefix) == prefix and #suffix == 12 and suffix:match("^[A-Za-z0-9]+$") then temp_path = path end
          end)
        end)
      end, true)
    end)
  end
  local function ready()
    command(adapter.remote({ "uname", "-m" }), adapter.unavailable, function(info)
      local raw = tostring(info.stdout):match("^%s*(.-)%s*$")
      local arch = ({ x86_64 = "x86_64", amd64 = "x86_64", aarch64 = "aarch64", arm64 = "aarch64" })[raw]
      if not arch then stop(failure("unsupported_arch", "unsupported " .. adapter.label:lower() .. " architecture: " .. raw)); return end
      deploy(arch)
    end)
  end
  ctx.remote = adapter.remote
  local function begin(host)
    native_host = host
    ctx.command = command
    local function prepared() guarded(ready) end
    local function prepare()
      local ok, err = pcall(adapter.prepare, ctx, prepared)
      if not ok then stop(failure("io_error", type(err) == "table" and err.message or err)) end
    end
    if opts.agent_path or opts.artifacts then prepare(); return end
    local p = artifact_bundle.discover(host, opts.agent_dir)
    active, cancel_active = p, true
    p:next(function(artifacts)
      if active == p then active = nil end
      if settled then return end
      opts.artifacts = artifacts
      guarded(prepare)
    end, function(err)
      if active == p then active = nil end
      if not settled then stop(native_error(err, "agent_install_unavailable")) end
    end)
  end
  function promise:cancel()
    if settled then return false end
    stop(failure("cancelled", adapter.label .. " bootstrap cancelled"))
    return true
  end
  local function watchdog()
    if settled then return end
    local left = remaining()
    if left <= 0 then stop(failure("timeout", adapter.label .. " bootstrap deadline exceeded"))
    else host_api.defer(watchdog, math.min(100, left)) end
  end
  host_api.defer(watchdog, math.min(100, opts.timeout_ms))
  local ok, p = pcall(hosts.local_host)
  if not ok then stop(native_error(p, "connector_unavailable")) else
    active, cancel_active = p, false
    p:next(function(host)
      if active == p then active = nil end
      if not settled then guarded(begin, host) end
    end, function(err)
      if active == p then active = nil end
      if not settled then stop(native_error(err, "connector_unavailable")) end
    end)
  end
  return promise
end

return M
