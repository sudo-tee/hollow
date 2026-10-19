-- Pane PTY host selection. Native code asks `hollow._pty_host` whether a new
-- pane runs on an agent host and gets back a deploy target; it then installs
-- `hollow-agent` and runs `hollow-agent pty` itself, off the UI thread.
local M = {}
local options = require("hollow.host.options")

local function message(err)
  if type(err) == "table" then return tostring(err.message or err.code or "host unavailable") end
  return (tostring(err):gsub("^.-:%d+: ", ""))
end

local function words(command)
  local result, current, quote, in_word = {}, {}, nil, false
  for ch in command:gmatch(".") do
    if quote then
      if ch == quote then quote = nil else current[#current + 1] = ch end
    elseif ch == '"' or ch == "'" then
      quote, in_word = ch, true
    elseif ch:match("%s") then
      if in_word then result[#result + 1] = table.concat(current); current = {} end
      in_word = false
    else
      current[#current + 1] = ch
      in_word = true
    end
  end
  if in_word then result[#result + 1] = table.concat(current) end
  return result
end

--- Distro named by a `wsl.exe -d X ...` launcher, if any.
function M.wsl_distro(shell)
  if type(shell) ~= "string" then return nil end
  local argv = words(shell)
  local program = (argv[1] or ""):match("[^/\\]*$"):lower()
  if program ~= "wsl" and program ~= "wsl.exe" then return nil end
  local i = 2
  while argv[i] do
    local arg = argv[i]
    if arg == "-d" or arg == "--distribution" then return argv[i + 1] ~= "" and argv[i + 1] or nil end
    if arg ~= "~" and (arg == "-e" or arg == "--exec" or arg == "--" or arg:sub(1, 1) ~= "-") then return nil end
    if arg == "-u" or arg == "--user" or arg == "--cd" or arg == "--shell-type" then i = i + 1 end
    i = i + 1
  end
  return nil
end

--- Host descriptor and mode ("explicit" | "implicit") for a new pane, or nil
--- to run it natively. `domains.<name>.host = false` opts a domain out.
function M.descriptor(domain, shell)
  local get = _G.hollow.config.get
  local domains = get("domains") or {}
  domain = domain or get("default_domain")
  local config = domain and domains[domain]
  if type(config) ~= "table" then config = {} end
  if config.host == false then return nil end
  if type(config.host) == "table" and config.host.type ~= nil then return config.host, "explicit" end
  if not (_G.hollow.platform or {}).is_windows then return nil end
  local distro = type(config.wsl_distro) == "string" and config.wsl_distro ~= "" and config.wsl_distro
    or M.wsl_distro(shell)
  if distro then return { type = "wsl", distro = distro }, "implicit" end
  return nil
end

local function path_style(spec)
  if spec.path_style ~= nil then return spec.path_style end
  return spec.type == "wsl" and "wsl" or "posix"
end

--- PTY host for a new pane, or nil to run it natively: the deploy target
--- (`hollow.host.options.target`) plus `mode` and `path_style`, or
--- `{ mode, error }` when the host config is invalid (reported in the pane).
function M.request(domain, shell)
  local ok, spec, mode = pcall(M.descriptor, domain, shell)
  if not ok then
    _G.hollow.log("pty host descriptor failed", spec)
    return nil
  end
  if not spec then return nil end
  local built, host = pcall(options.target, spec.type, spec)
  if not built then return { mode = mode, error = message(host) } end
  host.mode = mode
  host.path_style = path_style(spec)
  return host
end

function M.setup(hollow)
  function hollow._pty_host(domain, shell)
    return M.request(domain, shell)
  end
end

return M
