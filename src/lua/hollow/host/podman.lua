-- Podman-specific discovery and transport policy.
local M = {}
local container = require("hollow.host.container")

function M.connect(hosts, options)
  return container.connect(hosts, options, "podman", "Podman")
end

return M
