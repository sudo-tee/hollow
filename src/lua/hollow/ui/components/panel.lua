-- One painted container node, excluding children.
local box = require("hollow.ui.style.box")
local c = require("hollow.ui.components")
local props = require("hollow.ui.components.props")
local shared = require("hollow.ui.shared")
local sheet = require("hollow.ui.style.sheet")

local function resolve_padding(value, ctx)
  if type(value) == "string" then
    value = { top = value, right = value, bottom = value, left = value }
  elseif type(value) == "table" then
    value = box.parse(value)
  end
  if type(value) == "table" then
    local resolved = {}
    for side, item in pairs(value) do
      if type(item) == "string" then
        item = props.unit(item, "padding." .. side, ctx)
      end
      resolved[side] = item
    end
    value = resolved
  end
  return box.normalize(value)
end

return function(value)
  local options, children = props.split(value)
  local scope = props.scope()
  local theme, ctx = options.theme or scope.theme, options.ctx or scope.ctx
  local inset = options.inset or "overlay"
  assert(inset == "overlay" or inset == "modal" or inset == "none", "invalid panel inset")
  local chrome = options.chrome
  if chrome == nil then
    chrome = shared.theme_overlay_chrome(theme)
  end
  local style = shared.resolve_tokens(sheet.merge(chrome, options.style), theme)
  local padding = resolve_padding(options.padding ~= nil and options.padding or style.padding, ctx)
  if inset ~= "none" then
    local x = (ctx.cell_w or 8) * (inset == "modal" and 1.5 or 0.5)
    local h = ctx.cell_h or 19
    padding.left, padding.right = padding.left + x, padding.right + x
    padding.top, padding.bottom = padding.top + h, padding.bottom + h * 0.5
  end
  options.style, options.padding = style, padding
  if options.disabled then
    options.on_click = nil
  end
  return c.column(children, options)
end
