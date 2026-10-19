-- Podman connector: see hollow.host.container.
local M = {}
local container = require("hollow.host.container")

function M.connector(opts)
  return container.connector(opts, "podman")
end

return M
