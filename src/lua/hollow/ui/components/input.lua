-- Existing text_input behavior owns editing; these are ordinary layout boxes.
---@type HollowUiComponents
local c = require("hollow.ui.components")
local props = require("hollow.ui.components.props")
local shared = require("hollow.ui.shared")
local sheet = require("hollow.ui.style.sheet")

---@param input HollowUiTextInput
---@param theme HollowUiTheme
---@param ctx HollowUiLayoutContext
---@param inline boolean|nil
---@return HollowUiLayoutNode
return function(input, theme, ctx, inline)
  local options
  if input.behavior ~= nil then
    options = input
    local scope = props.scope()
    input, theme, ctx = options.behavior, options.theme or scope.theme, options.ctx or scope.ctx
    inline = options.boxed == false
  else
    options = {}
  end
  assert(type(input) == "table" and type(input.render) == "function", "input requires a behavior")
  ctx = ctx or {}
  local prefix = options.id or "input"
  local cell_h = props.cell_h(ctx)
  local runs = {}
  for index, span in ipairs(input.render(theme)) do
    local style = options.theme and shared.resolve_tokens(span.style, theme) or span.style
    runs[index] = c.column({ c.text(span.text, style, { wrap = "none" }) }, {
      id = index == 2 and (prefix .. ":caret") or nil,
      height = cell_h,
      style = style,
    })
  end
  local root = {}
  for key, value in pairs(options) do
    root[key] = value
  end
  root.width = options.width or "grow"
  root.padding = options.padding or (not inline and { x = props.cell_w(ctx) * 0.5, y = 2 } or nil)
  local default_style = not inline and { bg = theme.input_bg } or nil
  root.style = options.style and sheet.merge(default_style, options.style) or default_style
  if options.theme and root.style then
    root.style = shared.resolve_tokens(root.style, theme)
  end
  if options.disabled then
    root.on_click = nil
  end
  return c.column({
    c.row(runs, {
      id = prefix .. ":viewport",
      width = "grow",
      height = cell_h,
      scroll_x = true,
      reveal = prefix .. ":caret",
    }),
  }, root)
end
