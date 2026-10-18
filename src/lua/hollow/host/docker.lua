-- Docker reuses existing-container policy and the universal Linux agent.
local M = {}
local container = require("hollow.host.container")

function M.connect(hosts, options)
  return container.connect(hosts, options, "docker", "Docker")
end

return M
