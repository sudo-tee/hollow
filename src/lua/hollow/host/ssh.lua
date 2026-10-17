-- OpenSSH bootstrap only. All connected operations use the shared agent RPCs.
local M = {}
local bootstrap = require("hollow.host.bootstrap")
local artifacts = require("hollow.host.artifacts")

-- SSH concatenates command arguments for a remote shell. Keep that extra quoting
-- boundary explicit; never confuse local argv safety with remote shell safety.
local function quote(value) return "'" .. value:gsub("'", "'\"'\"'") .. "'" end
local function remote_command(args)
  local words = { "exec" }
  for _, value in ipairs(args) do words[#words + 1] = quote(value) end
  return table.concat(words, " ")
end

local function config_path(value, name)
  bootstrap.string(value, name)
  if not artifacts.absolute(value) or value:find("[%c]") then error(name .. " must be an absolute native path without control characters", 3) end
  return value
end

local function config_quote(value)
  -- UserKnownHostsFile has a second, SSH-config tokenization/expansion boundary.
  return '"' .. value:gsub("%%", "%%%%"):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

function M.connect(hosts, options)
  local opts = bootstrap.configuration(options, "ssh", "ssh")
  opts.destination = bootstrap.string(options.destination, "destination")
  if #opts.destination > 256 or opts.destination:sub(1, 1) == "-"
      or not opts.destination:match("^[A-Za-z0-9_.:%-%[%]]+$") then
    error("destination must be an SSH alias, hostname or IP address; supply user/port separately", 2)
  end
  if options.user ~= nil then
    opts.user = bootstrap.string(options.user, "user")
    if #opts.user > 256 or opts.user:sub(1, 1) == "-" or not opts.user:match("^[A-Za-z0-9_.%-]+$") then error("invalid SSH user", 2) end
  end
  if options.port ~= nil then
    local port = options.port
    if type(port) ~= "number" or port ~= port or port % 1 ~= 0 or port < 1 or port > 65535 then error("port must be an integer from 1 to 65535", 2) end
    opts.port = tostring(port)
  end
  opts.scp = bootstrap.string(options.scp or "scp", "scp")
  for _, key in ipairs({ "identity_file", "known_hosts", "config_file" }) do
    if options[key] ~= nil then opts[key] = config_path(options[key], key) end
  end
  local function base(copy)
    local argv = {}
    if copy then
      argv = { "-q", "-B", "-s", "-S", opts.executable } -- Force SFTP, never legacy remote-shell SCP.
    else argv = { "-T" } end
    for _, policy in ipairs({ "BatchMode=yes", "StrictHostKeyChecking=yes", "ControlMaster=no", "ControlPath=none",
        "ControlPersist=no", "RemoteCommand=none", "RequestTTY=no", "PermitLocalCommand=no",
        "ClearAllForwardings=yes", "ForwardAgent=no", "ForwardX11=no", "EscapeChar=none" }) do
      argv[#argv + 1] = "-o"; argv[#argv + 1] = policy
    end
    if opts.config_file then argv[#argv + 1] = "-F"; argv[#argv + 1] = opts.config_file end
    if opts.identity_file then
      argv[#argv + 1] = "-i"; argv[#argv + 1] = opts.identity_file
      argv[#argv + 1] = "-o"; argv[#argv + 1] = "IdentitiesOnly=yes"
    end
    if opts.known_hosts then argv[#argv + 1] = "-o"; argv[#argv + 1] = "UserKnownHostsFile=" .. config_quote(opts.known_hosts) end
    if opts.port then argv[#argv + 1] = copy and "-P" or "-p"; argv[#argv + 1] = opts.port end
    if opts.user and not copy then argv[#argv + 1] = "-l"; argv[#argv + 1] = opts.user end
    return argv
  end
  local function remote(args)
    local argv = base(false)
    argv[#argv + 1] = opts.destination
    argv[#argv + 1] = remote_command(args)
    return argv
  end
  return bootstrap.connect(hosts, opts, {
    label = "SSH",
    unavailable = "ssh_unavailable",
    prepare = function(_, ready) ready() end,
    remote = remote,
    transport = function(path) return remote({ path, "stdio" }) end,
    upload = function(ctx, path, target, done)
      local argv = { opts.scp }
      for _, value in ipairs(base(true)) do argv[#argv + 1] = value end
      local destination = opts.destination
      if destination:find(":", 1, true) and destination:sub(1, 1) ~= "[" then destination = "[" .. destination .. "]" end
      if opts.user then destination = opts.user .. "@" .. destination end
      argv[#argv + 1] = "--"
      argv[#argv + 1] = path
      argv[#argv + 1] = destination .. ":" .. target
      ctx.exec(argv, "agent_install_unavailable", function() done() end)
    end,
  })
end

return M
