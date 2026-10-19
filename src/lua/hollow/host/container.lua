-- Connector into an existing Docker or Podman container, optionally with the
-- container CLI running inside WSL. No container lifecycle policy.
local M = {}
local options = require("hollow.host.options")

--- `[wsl.exe ... --exec] <engine> [--context <context>] exec -i <container>`
function M.connector(opts, engine)
  local container = options.string(opts.container, "container")
  if not container:match("^[A-Za-z0-9][A-Za-z0-9_.%-]*$") then error("invalid container name or ID", 2) end
  local argv = {}
  if opts.via ~= nil then
    if type(opts.via) ~= "table" or opts.via.type ~= "wsl" then error("container via must be a WSL descriptor", 2) end
    for key in pairs(opts.via) do
      if key ~= "type" and key ~= "distro" and key ~= "user" and key ~= "wsl" then
        error("unsupported container via option: " .. tostring(key), 2)
      end
    end
    argv = require("hollow.host.wsl").connector(opts.via).argv
  end
  -- With `via`, the CLI path is a Linux path inside the distro.
  argv[#argv + 1] = options.string(opts[engine] or engine, engine)
  if engine == "docker" and opts.context ~= nil then
    local context = options.string(opts.context, "context")
    if #context > 256 or context:sub(1, 1) == "-" then error("invalid Docker context", 2) end
    argv[#argv + 1] = "--context"
    argv[#argv + 1] = context
  end
  argv[#argv + 1] = "exec"
  argv[#argv + 1] = "-i"
  argv[#argv + 1] = container
  return { argv = argv }
end

return M
