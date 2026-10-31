-- One row plus a title, an optional spacer and meta. Meta nodes are user
-- children; `meta_align = "inline"` drops the spacer.
local c = require("hollow.ui.components")
local props = require("hollow.ui.components.props")

return function(value)
  local options = props.split(value)
  local children = {
    c.title({
      text = tostring(options.title or "") .. (options.prompt and ":" or ""),
      theme = options.theme,
      style = options.title_style,
    }),
  }
  if options.meta ~= nil then
    if options.meta_align ~= "inline" then
      children[#children + 1] = c.spacer()
    end
    if type(options.meta) == "table" then
      children[#children + 1] = options.meta
    else
      children[#children + 1] = c.label({
        text = options.meta,
        tone = "counter",
        theme = options.theme,
        style = options.meta_style,
      })
    end
  end
  return c.row(children, options)
end
