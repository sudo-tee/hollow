-- One row plus a title, an optional spacer and meta. Meta nodes are user
-- children; `meta_align = "inline"` drops the spacer.
local c = require("hollow.ui.components")
local props = require("hollow.ui.components.props")

return function(value)
  local options = props.split(value)
  local meta = options.meta
  return c.row({
    c.title({
      text = tostring(options.title or "") .. (options.prompt and ":" or ""),
      theme = options.theme,
      style = options.title_style,
    }),
    c.when(meta ~= nil and options.meta_align ~= "inline", c.spacer),
    c.when(meta ~= nil, function()
      return type(meta) == "table" and meta
        or c.label({
          text = meta,
          tone = "counter",
          theme = options.theme,
          style = options.meta_style,
        })
    end),
  }, options)
end
