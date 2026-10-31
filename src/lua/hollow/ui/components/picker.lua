-- A divided stack of header, optional filter, list and optional hints.
-- Node cost is one stack plus the costs of those child components.
local c = require("hollow.ui.components")
local props = require("hollow.ui.components.props")

return function(value)
  local options = props.split(value)
  assert(type(options.id) == "string" and options.id ~= "", "picker requires an id")
  assert(type(options.list) == "table", "picker requires list props")
  local theme = props.theme(options)
  local list = props.copy(options.list)
  list.id = list.id or (options.id .. ":list")
  list.theme = list.theme or theme
  list.width = list.width or "grow"
  list.height = list.height or "grow"
  local children = {
    options._header or c.header({
      title = options.title or "Select",
      meta = options.counter,
      prompt = options.prompt,
      theme = theme,
      width = "grow",
    }),
  }
  if options._filter then
    children[#children + 1] = options._filter
  elseif options.filter then
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
  if options._hints then
    children[#children + 1] = options._hints
  elseif options.hints then
    local hints = props.copy(options.hints)
    hints.theme = hints.theme or theme
    children[#children + 1] = c.hints(hints)
  end
  local root = options
  if options._legacy then
    root.id = nil
  end
  root.theme = theme
  root.divided = true
  root.width = root.width or "grow"
  root.height = root.height or "grow"
  root.gap = root.gap or "1lh"
  root[1] = children
  return c.stack(root)
end
