-- OpenSSH connector. SSH joins the remote command into one string for the
-- remote shell, so native code passes it as a single quoted `exec ...` word.
local M = {}
local options = require("hollow.host.options")

local POLICY = {
  "BatchMode=yes", "StrictHostKeyChecking=yes", "ControlMaster=no", "ControlPath=none",
  "ControlPersist=no", "RemoteCommand=none", "RequestTTY=no", "PermitLocalCommand=no",
  "ClearAllForwardings=yes", "ForwardAgent=no", "ForwardX11=no", "EscapeChar=none",
}

local function config_path(value, name)
  options.string(value, name)
  if not options.absolute(value) or value:find("%c") then
    error(name .. " must be an absolute native path without control characters", 3)
  end
  return value
end

-- UserKnownHostsFile goes through SSH-config tokenization and expansion.
local function config_quote(value)
  return '"' .. value:gsub("%%", "%%%%"):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

--- `ssh -T -o <policy>... [-F config] [-i identity] [-p port] [-l user] <destination>`
function M.connector(opts)
  local destination = options.string(opts.destination, "destination")
  if #destination > 256 or destination:sub(1, 1) == "-" or not destination:match("^[A-Za-z0-9_.:%-%[%]]+$") then
    error("destination must be an SSH alias, hostname or IP address; supply user/port separately", 2)
  end
  local argv = { options.string(opts.ssh or "ssh", "ssh"), "-T" }
  local function add(...)
    for _, value in ipairs({ ... }) do argv[#argv + 1] = value end
  end
  for _, policy in ipairs(POLICY) do add("-o", policy) end
  if opts.config_file ~= nil then add("-F", config_path(opts.config_file, "config_file")) end
  if opts.identity_file ~= nil then
    add("-i", config_path(opts.identity_file, "identity_file"), "-o", "IdentitiesOnly=yes")
  end
  if opts.known_hosts ~= nil then
    add("-o", "UserKnownHostsFile=" .. config_quote(config_path(opts.known_hosts, "known_hosts")))
  end
  if opts.port ~= nil then
    local port = opts.port
    if type(port) ~= "number" or port ~= port or port % 1 ~= 0 or port < 1 or port > 65535 then
      error("port must be an integer from 1 to 65535", 2)
    end
    add("-p", tostring(port))
  end
  if opts.user ~= nil then
    local user = options.string(opts.user, "user")
    if #user > 256 or user:sub(1, 1) == "-" or not user:match("^[A-Za-z0-9_.%-]+$") then error("invalid SSH user", 2) end
    add("-l", user)
  end
  add(destination)
  return { argv = argv, remote_shell = true }
end

return M
