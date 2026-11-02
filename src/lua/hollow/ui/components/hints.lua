-- One row plus two text nodes per hint; plain mode uses one column and one text node.
local c = require("hollow.ui.components")
local common = require("hollow.ui.recipes.common")
local props = require("hollow.ui.components.props")
local shared = require("hollow.ui.shared")

return function(value)
  local opts, list = props.split(value)
  local separator = opts.separator == nil and "  " or opts.separator
  local function paint(style)
    return opts.theme and shared.resolve_tokens(style, opts.theme) or style
  end
  if opts.plain then
    local parts = c.each(list, function(hint)
      return tostring(hint[1]) .. " " .. tostring(hint[2] or "")
    end)
    local text = table.concat(parts, separator)
    if opts.trailing_separator and #parts > 0 then
      text = text .. separator
    end
    opts.style = opts.style and paint(opts.style)
    return c.column({ c.text(text, paint(opts.description_style), { wrap = "none" }) }, opts)
  end
  local trailing = not opts.separator_style
  local children = c.each(list, function(hint, index)
    local suffix = trailing and (index < #list or opts.trailing_separator) and separator or ""
    return {
      c.when(index > 1 and opts.separator_style, function()
        return c.text(separator, paint(opts.separator_style), { wrap = "none" })
      end),
      c.text(hint[1], paint(opts.key_style or common.key_hint), { wrap = "none" }),
      c.text(
        " " .. tostring(hint[2] or "") .. suffix,
        paint(opts.description_style or common.muted),
        { wrap = "none" }
      ),
    }
  end)
  opts.style = opts.style and paint(opts.style)
  return c.row(children, opts)
end
