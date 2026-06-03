local hollow = _G.hollow


local M = {}

M.name = "Hollow Spirit"

function M.setup(opts)
	hollow.log("Setting up Hollow Spirit")
	opts = opts or {}
	M.name = opts.name or "Hollow Spirit"
end

return M
