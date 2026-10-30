-- One row plus two text nodes per hint; separators share the description node.
local c = require("hollow.ui.components")
local common = require("hollow.ui.recipes.common")

return function(opts)
  opts = opts or {}
  local children = {}
  local separator = opts.separator == nil and "  " or opts.separator
  for index, hint in ipairs(opts) do
    if index > 1 and opts.separator_style then
      children[#children + 1] = c.text(separator, opts.separator_style, { wrap = "none" })
    end
    children[#children + 1] = c.text(hint[1], opts.key_style or common.key_hint, { wrap = "none" })
    children[#children + 1] = c.text(
      " "
        .. tostring(hint[2] or "")
        .. (index < #opts and not opts.separator_style and separator or ""),
      opts.description_style or common.muted,
      { wrap = "none" }
    )
  end
  local root = {}
  for key, value in pairs(opts) do
    if type(key) ~= "number" then
      root[key] = value
    end
  end
  if opts.disabled then
    root.on_click = nil
  end
  return c.row(children, root)
end
