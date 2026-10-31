-- One row plus two text nodes per hint; plain mode uses one column and one text node.
local c = require("hollow.ui.components")
local common = require("hollow.ui.recipes.common")
local shared = require("hollow.ui.shared")

return function(opts)
  opts = opts or {}
  local children = {}
  local separator = opts.separator == nil and "  " or opts.separator
  local function paint(style)
    return opts.theme and shared.resolve_tokens(style, opts.theme) or style
  end
  if opts.plain then
    local parts = {}
    for _, hint in ipairs(opts) do
      parts[#parts + 1] = tostring(hint[1]) .. " " .. tostring(hint[2] or "")
    end
    local value = table.concat(parts, separator)
    if opts.trailing_separator and #parts > 0 then
      value = value .. separator
    end
    local root = {}
    for key, item in pairs(opts) do
      if type(key) ~= "number" then
        root[key] = item
      end
    end
    if opts.disabled then
      root.on_click = nil
    end
    root.style = root.style and paint(root.style)
    return c.column({ c.text(value, paint(opts.description_style), { wrap = "none" }) }, root)
  end
  for index, hint in ipairs(opts) do
    if index > 1 and opts.separator_style then
      children[#children + 1] = c.text(separator, paint(opts.separator_style), { wrap = "none" })
    end
    children[#children + 1] =
      c.text(hint[1], paint(opts.key_style or common.key_hint), { wrap = "none" })
    local suffix = ""
    if (index < #opts or opts.trailing_separator) and not opts.separator_style then
      suffix = separator
    end
    children[#children + 1] = c.text(
      " " .. tostring(hint[2] or "") .. suffix,
      paint(opts.description_style or common.muted),
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
  root.style = root.style and paint(root.style)
  return c.row(children, root)
end
