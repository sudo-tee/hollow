-- One row plus title, optional spacer and meta; meta nodes are user children.
local c = require("hollow.ui.components")

return function(options)
  options = options or {}
  local title = tostring(options.title or "") .. (options.prompt and ":" or "")
  local children = { c.title({ text = title, theme = options.theme }) }
  if options.meta ~= nil then
    children[#children + 1] = c.spacer()
    if type(options.meta) == "table" then
      children[#children + 1] = options.meta
    else
      children[#children + 1] =
        c.label({ text = options.meta, tone = "counter", theme = options.theme })
    end
  end
  local root = {}
  for key, value in pairs(options) do
    root[key] = value
  end
  if options.disabled then
    root.on_click = nil
  end
  return c.row(children, root)
end
