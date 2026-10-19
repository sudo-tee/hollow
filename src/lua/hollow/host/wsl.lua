-- WSL connector: runs commands in a distro, optionally as a given user.
local M = {}
local options = require("hollow.host.options")

--- `wsl.exe --distribution <distro> [--user <user>] --cd / --exec`
function M.connector(opts)
  local distro = options.string(opts.distro, "distro")
  if #distro > 256 or distro:sub(1, 1) == "-" then error("invalid WSL distro name", 2) end
  local argv = { options.string(opts.wsl or "wsl.exe", "wsl"), "--distribution", distro }
  if opts.user ~= nil then
    local user = options.string(opts.user, "user")
    if #user > 256 or user:sub(1, 1) == "-" then error("invalid WSL user", 2) end
    argv[#argv + 1] = "--user"
    argv[#argv + 1] = user
  end
  argv[#argv + 1] = "--cd"
  argv[#argv + 1] = "/"
  argv[#argv + 1] = "--exec"
  return { argv = argv }
end

return M
