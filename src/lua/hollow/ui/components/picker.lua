-- A divided stack of header, optional filter, list and optional hints. `header`,
-- `filter` and `hints` also accept prebuilt layout nodes.
-- Node cost is one stack plus the costs of those child components.
local c = require("hollow.ui.components")
local props = require("hollow.ui.components.props")

local function is_node(value)
  return type(value) == "table" and value.kind ~= nil
end

return function(value)
  local options = props.split(value)
  assert(type(options.id) == "string" and options.id ~= "", "picker requires an id")
  assert(type(options.list) == "table", "picker requires list props")
  local theme = props.theme(options)
  local children = {}
  if is_node(options.header) then
    children[1] = options.header
  else
    children[1] = c.header({
      title = options.title or "Select",
      meta = options.counter,
      prompt = options.prompt,
      theme = theme,
      width = "grow",
    })
  end
  if is_node(options.filter) then
    children[#children + 1] = options.filter
  elseif options.filter then
    children[#children + 1] = c.row({
      c.title({ text = "Filter: ", theme = theme }),
      c.input({
        id = options.id .. ":filter",
        behavior = options.filter,
        theme = theme,
        boxed = false,
        -- Picker widgets route every key to their filter themselves.
        focusable = options.filter_focusable == true,
      }),
    }, { width = "grow" })
  end
  local list = props.copy(options.list)
  list.id = list.id or (options.id .. ":list")
  list.theme = list.theme or theme
  list.width = list.width or "grow"
  list.height = list.height or "grow"
  children[#children + 1] = c.list(list)
  if is_node(options.hints) then
    children[#children + 1] = options.hints
  elseif options.hints then
    local hints = props.copy(options.hints)
    hints.theme = hints.theme or theme
    children[#children + 1] = c.hints(hints)
  end
  options.theme = theme
  options.divided = true
  options.width = options.width or "grow"
  options.height = options.height or "grow"
  options.gap = options.gap or "1lh"
  options[1] = children
  return c.stack(options)
end
