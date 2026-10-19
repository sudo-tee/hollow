-- Option checks shared by the host adapters, and the deploy target handed to
-- native code: the adapter's connector plus where the agent comes from.
-- Native code (src/host/deploy.zig) installs and runs the agent.
local M = {}

local ADAPTERS = {
  wsl = "hollow.host.wsl",
  ssh = "hollow.host.ssh",
  podman = "hollow.host.podman",
  docker = "hollow.host.docker",
}

function M.string(value, name)
  if type(value) ~= "string" or value == "" or value:find("\0", 1, true) then
    error(name .. " must be a non-empty string without NUL", 3)
  end
  return value
end

--- Client-native absolute path (POSIX, `C:\` or UNC).
function M.absolute(path)
  return type(path) == "string"
    and (path:sub(1, 1) == "/" or path:match("^[A-Za-z]:[/\\]") ~= nil or path:sub(1, 2) == "\\\\")
end

local function agent(opts)
  local result = { timeout_ms = opts.timeout_ms or 60000 }
  local timeout = result.timeout_ms
  if type(timeout) ~= "number" or timeout ~= timeout or timeout % 1 ~= 0 or timeout < 1 or timeout > 300000 then
    error("timeout_ms must be an integer from 1 to 300000", 3)
  end
  if opts.agent_path ~= nil then
    result.path = M.string(opts.agent_path, "agent_path")
    if result.path:sub(1, 1) ~= "/" then error("agent_path must be an absolute Linux path", 3) end
  end
  if opts.agent_dir ~= nil then
    result.dir = M.string(opts.agent_dir, "agent_dir")
    if not M.absolute(result.dir) then error("agent_dir must be a client-native absolute path", 3) end
  end
  if opts.artifacts ~= nil then
    if type(opts.artifacts) ~= "table" then error("artifacts must be a table", 3) end
    result.artifacts = {}
    for arch, item in pairs(opts.artifacts) do
      if arch ~= "x86_64" and arch ~= "aarch64" then error("unsupported artifact architecture", 3) end
      if type(item) ~= "table" then error("artifact must be a table", 3) end
      local path = M.string(item.path, "artifact path")
      if not M.absolute(path) then error("artifact path must be client-native absolute", 3) end
      local digest = M.string(item.sha256, "artifact sha256")
      if #digest ~= 64 or not digest:match("^%x+$") then error("artifact sha256 must be 64 hex digits", 3) end
      result.artifacts[arch] = { path = path, sha256 = digest:lower() }
    end
  end
  return result
end

--- `{ connector = { argv, remote_shell? }, agent = { path?, dir?, artifacts?,
--- timeout_ms } }` for a host of `kind` ("wsl", "ssh", "podman", "docker").
function M.target(kind, opts)
  local module = ADAPTERS[kind]
  if not module then error("unsupported host type: " .. tostring(kind), 2) end
  if type(opts) ~= "table" then error(kind .. " host expects an options table", 2) end
  return { connector = require(module).connector(opts), agent = agent(opts) }
end

return M
