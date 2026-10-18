-- Shared existing-container selection and transport; no container lifecycle policy.
local M = {}
local bootstrap = require("hollow.host.bootstrap")
-- Docker cp may replace a user-owned mktemp with a root-owned archive entry.
-- Open its readable inode, unlink only the reserved name, then recreate that
-- name as the configured user. noclobber refuses a replacement/symlink race.
-- No extra named temporary or privileged exec is needed. SHA verification and
-- chmod happen afterwards in the shared engine; copied setuid bits never run.
local RESTAGE = 'set -eu; [ ! -L "$1" ] && [ -f "$1" ]; exec 3< "$1"; rm -f -- "$1"; set -C; umask 077; cat <&3 > "$1"'

function M.connect(hosts, options, engine, label)
  local opts = bootstrap.configuration(options, engine, engine)
  local container = bootstrap.string(options.container, "container")
  if not container:match("^[A-Za-z0-9][A-Za-z0-9_.%-]*$") then error("invalid container name or ID", 2) end
  local context
  if engine == "docker" and options.context ~= nil then
    context = bootstrap.string(options.context, "context")
    if #context > 256 or context:sub(1, 1) == "-" then error("invalid Docker context", 2) end
  end
  local function command(args)
    if not context then return args end
    local argv = { "--context", context }
    for _, value in ipairs(args) do argv[#argv + 1] = value end
    return argv
  end
  local container_id
  return bootstrap.connect(hosts, opts, {
    label = label,
    unavailable = "container_unavailable",
    prepare = function(ctx, ready)
      ctx.command(command({ "container", "inspect", "--format", "{{.Id}} {{.State.Running}}", container }), "container_unavailable", function(result)
        local id, running = tostring(result.stdout):match("^(%x+)%s+(%S+)%s*$")
        if not id or #id ~= 64 or running ~= "true" then
          ctx.fail("container_unavailable", "container is not running or inspect response is invalid")
          return
        end
        container_id = id:lower()
        ready()
      end)
    end,
    remote = function(args)
      local argv = { "exec", container_id }
      for _, value in ipairs(args) do argv[#argv + 1] = value end
      return command(argv)
    end,
    transport = function(path) return command({ "exec", "-i", container_id, path, "stdio" }) end,
    upload = function(ctx, artifact_path, temp_path, done)
      ctx.command(command({ "cp", artifact_path, container_id .. ":" .. temp_path }), "agent_install_unavailable", function()
        if engine ~= "docker" then done(); return end
        ctx.command(command({ "exec", container_id, "/bin/sh", "-c", RESTAGE, "hollow-upload", temp_path }), "agent_install_unavailable", function() done() end)
      end)
    end,
  })
end

return M
