-- Search temporarily exposes collapsed groups without changing user choices.
local M = {}

---@return {is_collapsed: fun(key: string, query: string): boolean, toggle: fun(key: string, query: string)}
function M.new()
  local collapsed = {}
  return {
    is_collapsed = function(key, query)
      return query == "" and collapsed[key] == true
    end,
    toggle = function(key, query)
      if query == "" then
        collapsed[key] = not collapsed[key]
      end
    end,
  }
end

return M
