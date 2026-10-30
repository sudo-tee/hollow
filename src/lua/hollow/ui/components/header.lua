-- One row plus title, optional spacer and meta; meta nodes are user children.
local c = require("hollow.ui.components")

return function(options)
  options = options or {}
  local title = tostring(options.title or "") .. (options.prompt and ":" or "")
  local children = {
    options._legacy_style and c.text(title, options.title_style, { wrap = "none" })
      or c.title({ text = title, theme = options.theme, style = options.title_style }),
  }
  if options.meta ~= nil then
    if options.meta_align ~= "inline" then
      children[#children + 1] = c.spacer()
    end
    if type(options.meta) == "table" then
      children[#children + 1] = options.meta
    else
      children[#children + 1] = options._legacy_style
          and c.text(options.meta, options.meta_style, { wrap = "none" })
        or c.label({
          text = options.meta,
          tone = "counter",
          theme = options.theme,
          style = options.meta_style,
        })
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
