-- Bootstrap policy only. Once connected, all operations use the common agent.
local M = {}
local async = require("hollow.async")
local artifact_bundle = require("hollow.host.artifacts")
local host_api = assert(rawget(_G, "host_api"), "global host_api bridge is missing")
local LIMIT = 16384

local function failure(code, message) return { code = code, message = tostring(message):sub(1, LIMIT) } end
local function string_value(value, name)
  if type(value) ~= "string" or value == "" or value:find("\0", 1, true) then
    error(name .. " must be a non-empty string without NUL", 3)
  end
  return value
end

local function configuration(opts)
  if type(opts) ~= "table" then error("podman expects an options table", 3) end
  local copy = { id = string_value(opts.id, "id"), container = string_value(opts.container, "container"),
    podman = string_value(opts.podman or "podman", "podman"), timeout_ms = opts.timeout_ms or 60000 }
  if #copy.id > 256 then error("id must be at most 256 bytes", 3) end
  if not copy.container:match("^[A-Za-z0-9][A-Za-z0-9_.%-]*$") then error("invalid container name or ID", 3) end
  local timeout = copy.timeout_ms
  if type(timeout) ~= "number" or timeout ~= timeout or timeout % 1 ~= 0 or timeout < 1 or timeout > 300000 then
    error("timeout_ms must be an integer from 1 to 300000", 3)
  end
  if opts.agent_dir ~= nil then
    if not artifact_bundle.absolute(opts.agent_dir) then error("agent_dir must be a client-native absolute path", 3) end
    copy.agent_dir = opts.agent_dir
  end
  if opts.agent_path ~= nil then
    copy.agent_path = string_value(opts.agent_path, "agent_path")
    if copy.agent_path:sub(1, 1) ~= "/" then error("agent_path must be an absolute Linux path", 3) end
  elseif opts.artifacts ~= nil then
    if type(opts.artifacts) ~= "table" then error("artifacts must be a table", 3) end
    copy.artifacts = {}
    for arch, item in pairs(opts.artifacts) do
      if arch ~= "x86_64" and arch ~= "aarch64" then error("unsupported artifact architecture", 3) end
      if type(item) ~= "table" then error("artifact must be a table", 3) end
      local path = string_value(item.path, "artifact path")
      if path:sub(1, 1) ~= "/" and not path:match("^[A-Za-z]:[/\\]") and not path:match("^\\\\") then
        error("artifact path must be client-native absolute", 3)
      end
      local digest = string_value(item.sha256, "artifact sha256")
      if #digest ~= 64 or not digest:match("^%x+$") then error("artifact sha256 must be 64 hex digits", 3) end
      copy.artifacts[arch] = { path = path, sha256 = digest:lower() }
    end
  end
  return copy
end

local VERIFY = 'set -eu; [ ! -L "$1" ] && [ -x "$1" ] || exit 1; got=$(sha256sum < "$1"); [ "${got%% *}" = "$2" ]'
local INSTALL = 'set -eu; [ ! -L "$1" ] || exit 44; got=$(sha256sum < "$1"); [ "${got%% *}" = "$2" ] || exit 43; chmod 700 -- "$1"; mv -fT -- "$1" "$3"; test -x "$3"'

function M.connect(hosts, options)
  local opts = configuration(options)
  local resolve, reject
  local promise = async.promise(function(r, j) resolve, reject = r, j end)
  local deadline = host_api.now_ms() + opts.timeout_ms
  local settled, active, cancel_active = false, nil, false
  local native_host, container_id, temp_path
  local cleanup_started = false

  local function cleanup()
    -- A cancelled cp may still be writing. Drain it before deleting its owned
    -- pathname, otherwise a late copy could recreate an orphan upload.
    if not settled or active or not temp_path or not native_host or cleanup_started then return end
    cleanup_started = true
    local ok, p = pcall(native_host.exec, native_host, {
      argv = { opts.podman, "exec", container_id, "rm", "-f", "--", temp_path },
      timeout_ms = 5000, output_limit = LIMIT,
    })
    if ok then p:next(function() end, function() end) end -- best effort; never delete a container/cache tree
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
  local function command(args, code, next_step, allow_failure, track_result)
    if settled then cleanup(); return end
    local left = remaining()
    if left <= 0 then stop(failure("timeout", "Podman bootstrap deadline exceeded")); return end
    local argv = { opts.podman }
    for _, value in ipairs(args) do argv[#argv + 1] = value end
    local ok, p = pcall(native_host.exec, native_host, { argv = argv, timeout_ms = left, output_limit = LIMIT })
    if not ok then stop(native_error(p, code)); return end
    active, cancel_active = p, true
    p:next(function(result)
      if active == p then active = nil end
      if track_result then guarded(track_result, result) end
      if settled then cleanup(); return end
      if remaining() <= 0 then stop(failure("timeout", "Podman bootstrap deadline exceeded")); return end
      if type(result) ~= "table" or type(result.exit_code) ~= "number" then stop(failure(code, "invalid process result")); return end
      if result.exit_code ~= 0 and not allow_failure then stop(failure(code, result.stderr or "Podman command failed")); return end
      guarded(next_step, result)
    end, function(err)
      if active == p then active = nil end
      if settled then cleanup() else stop(native_error(err, code)) end
    end)
  end
  local function remote(args)
    local result = { "exec", container_id }
    for _, value in ipairs(args) do result[#result + 1] = value end
    return result
  end
  local function connect(path)
    command(remote({ "test", "-x", path }), "agent_install_unavailable", function()
      local ok, p = pcall(hosts.connect, { id = opts.id, argv = { opts.podman, "exec", "-i", container_id, path, "stdio" } })
      if not ok then stop(native_error(p, "agent_install_unavailable")); return end
      active, cancel_active = p, true
      p:next(function(host)
        if active == p then active = nil end
        if not settled and remaining() <= 0 then stop(failure("timeout", "Podman bootstrap deadline exceeded")) end
        if settled then if host and host.close then pcall(host.close, host) end; cleanup(); return end
        settled = true
        resolve(host)
      end, function(err)
        if active == p then active = nil end
        if settled then cleanup() else stop(native_error(err, "agent_install_unavailable")) end
      end)
    end)
  end
  local function deploy(arch)
    if opts.agent_path then connect(opts.agent_path); return end
    local artifact = opts.artifacts[arch]
    if not artifact then stop(failure("agent_install_unavailable", "no configured artifact for " .. arch)); return end
    command(remote({ "/bin/sh", "-c", 'printf "%s" "$HOME"' }), "agent_install_unavailable", function(result)
      local home = result.stdout
      if type(home) ~= "string" or home:sub(1, 1) ~= "/" or home:find("\0", 1, true) then
        stop(failure("agent_install_unavailable", "container has no absolute HOME; configure agent_path")); return
      end
      local parent = home .. "/.cache/hollow/agents/linux-" .. arch .. "/" .. artifact.sha256
      local target = parent .. "/hollow-agent"
      command(remote({ "/bin/sh", "-c", VERIFY, "hollow-bootstrap", target, artifact.sha256 }), "agent_install_unavailable", function(verified)
        if verified.exit_code == 0 then connect(target); return end
        command(remote({ "mkdir", "-p", "--", parent }), "agent_install_unavailable", function()
          command(remote({ "mktemp", parent .. "/.upload-XXXXXXXXXXXX" }), "agent_install_unavailable", function()
            if not temp_path then stop(failure("agent_install_unavailable", "invalid mktemp response")); return end
            command({ "cp", artifact.path, container_id .. ":" .. temp_path }, "agent_install_unavailable", function()
              command(remote({ "/bin/sh", "-c", INSTALL, "hollow-bootstrap", temp_path, artifact.sha256, target }), "agent_install_unavailable", function(installed)
                if installed.exit_code ~= 0 then
                  stop(failure(installed.exit_code == 43 and "checksum_mismatch" or "agent_install_unavailable", installed.stderr or "agent installation failed")); return
                end
                temp_path = nil
                connect(target)
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
  local function inspect()
    command({ "container", "inspect", "--format", "{{.Id}} {{.State.Running}}", opts.container }, "container_unavailable", function(result)
      local id, running = tostring(result.stdout):match("^(%x+)%s+(%S+)%s*$")
      if not id or #id ~= 64 or running ~= "true" then stop(failure("container_unavailable", "container is not running or inspect response is invalid")); return end
      container_id = id:lower()
      command(remote({ "uname", "-m" }), "container_unavailable", function(info)
        local raw = tostring(info.stdout):match("^%s*(.-)%s*$")
        local arch = ({ x86_64 = "x86_64", amd64 = "x86_64", aarch64 = "aarch64", arm64 = "aarch64" })[raw]
        if not arch then stop(failure("unsupported_arch", "unsupported container architecture: " .. raw)); return end
        deploy(arch)
      end)
    end)
  end
  local function begin(host)
    native_host = host
    if opts.agent_path or opts.artifacts then inspect(); return end
    local p = artifact_bundle.discover(host, opts.agent_dir)
    active, cancel_active = p, true
    p:next(function(artifacts)
      if active == p then active = nil end
      if settled then return end
      opts.artifacts = artifacts
      guarded(inspect)
    end, function(err)
      if active == p then active = nil end
      if not settled then stop(native_error(err, "agent_install_unavailable")) end
    end)
  end
  function promise:cancel()
    if settled then return false end
    stop(failure("cancelled", "Podman bootstrap cancelled"))
    return true
  end
  local function watchdog()
    if settled then return end
    local left = remaining()
    if left <= 0 then stop(failure("timeout", "Podman bootstrap deadline exceeded"))
    else host_api.defer(watchdog, math.min(100, left)) end
  end
  host_api.defer(watchdog, math.min(100, opts.timeout_ms))
  -- Do not cancel the runtime's shared native-local connection when one
  -- bootstrap is cancelled; it may serve other connectors/workspace requests.
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
