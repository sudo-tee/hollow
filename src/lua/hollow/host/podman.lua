-- Podman-specific discovery and transport policy.
local M = {}
local bootstrap = require("hollow.host.bootstrap")

function M.connect(hosts, options)
  local opts = bootstrap.configuration(options, "podman", "podman")
  local container = bootstrap.string(options.container, "container")
  if not container:match("^[A-Za-z0-9][A-Za-z0-9_.%-]*$") then error("invalid container name or ID", 2) end
  local container_id
  local adapter = {
    label = "Podman",
    unavailable = "container_unavailable",
    prepare = function(ctx, ready)
      ctx.command({ "container", "inspect", "--format", "{{.Id}} {{.State.Running}}", container }, "container_unavailable", function(result)
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
      local result = { "exec", container_id }
      for _, value in ipairs(args) do result[#result + 1] = value end
      return result
    end,
    transport = function(path) return { "exec", "-i", container_id, path, "stdio" } end,
    upload = function(ctx, artifact_path, temp_path, done)
      ctx.command({ "cp", artifact_path, container_id .. ":" .. temp_path }, "agent_install_unavailable", function()
        done()
      end)
    end,
  }
  return bootstrap.connect(hosts, opts, adapter)
end

return M
