-- Docker connector: see hollow.host.container.
local M = {}
local container = require("hollow.host.container")

function M.connector(opts)
  return container.connector(opts, "docker")
end

return M
