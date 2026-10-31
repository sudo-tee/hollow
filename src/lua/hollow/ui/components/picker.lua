-- A divided stack of header, optional filter, list and optional hints.
-- Node cost is one stack plus the costs of those child components.
local c = require("hollow.ui.components")
local props = require("hollow.ui.components.props")

local function copy(source)
  local result = {}
  for key, value in pairs(source or {}) do
    result[key] = value
  end
  return result
end

return function(options)
  options = options or {}
  assert(type(options.id) == "string" and options.id ~= "", "picker requires an id")
  assert(type(options.list) == "table", "picker requires list props")
  local scope = props.scope()
  local theme = options.theme or scope.theme
  local list = copy(options.list)
  list.id = list.id or (options.id .. ":list")
  list.theme = list.theme or theme
  list.width = list.width or "grow"
  list.height = list.height or "grow"
  local children = {
    c.header({
      title = options.title or "Select",
      meta = options.counter,
      prompt = options.prompt,
      theme = theme,
      width = "grow",
    }),
  }
  if options.filter then
    children[#children + 1] = c.row({
      c.title({ text = "Filter: ", theme = theme }),
      c.input({
        id = options.id .. ":filter",
        behavior = options.filter,
        theme = theme,
        boxed = false,
      }),
    }, { width = "grow" })
  end
  children[#children + 1] = c.list(list)
  if options.hints then
    local hints = copy(options.hints)
    hints.theme = hints.theme or theme
    children[#children + 1] = c.hints(hints)
  end
  local root = copy(options)
  root.theme = theme
  root.divided = true
  root.width = root.width or "grow"
  root.height = root.height or "grow"
  root.gap = root.gap or "1lh"
  root[1] = children
  return c.stack(root)
end
