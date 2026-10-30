local M = {}

--- Fires a function if it's a function, otherwise does nothing.
---@param fn function|nil
---@param value any
function M.fire(fn, value)
  if fn and type(fn) == "function" then
    fn(value)
  end
end

return M
