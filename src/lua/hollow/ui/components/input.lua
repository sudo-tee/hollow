-- Two nodes plus two per run. The `behavior` (a `ui.text_input`) owns editing;
-- these are ordinary layout boxes with a caret reveal target.
---@type HollowUiComponents
local c = require("hollow.ui.components")
local props = require("hollow.ui.components.props")
local shared = require("hollow.ui.shared")
local sheet = require("hollow.ui.style.sheet")

---@param value HollowUiInputProps
---@return HollowUiLayoutNode
return function(value)
  local options = props.split(value)
  local input = options.behavior
  assert(type(input) == "table" and type(input.render) == "function", "input requires a behavior")
  local explicit = options.theme ~= nil
  local theme, ctx = props.theme(options), props.ctx(options)
  local boxed = options.boxed ~= false
  local prefix = options.id or "input"
  local cell_h = props.cell_h(ctx)
  local runs = {}
  for index, span in ipairs(input.render(theme)) do
    local style = explicit and shared.resolve_tokens(span.style, theme) or span.style
    runs[index] = c.column({ c.text(span.text, style, { wrap = "none" }) }, {
      id = index == 2 and (prefix .. ":caret") or nil,
      height = cell_h,
      style = style,
    })
  end
  options.width = options.width or "grow"
  options.padding = options.padding or (boxed and { x = props.cell_w(ctx) * 0.5, y = 2 } or nil)
  local default_style = boxed and { bg = theme.input_bg } or nil
  options.style = options.style and sheet.merge(default_style, options.style) or default_style
  if explicit and options.style then
    options.style = shared.resolve_tokens(options.style, theme)
  end
  -- Tab focuses the field; a focused field receives keys before its widget.
  if options.focusable ~= false then
    options.id, options.focusable = prefix, true
    options.on_key = options.on_key or require("hollow.ui.keys").keys(input)
  end
  return c.column({
    c.row(runs, {
      id = prefix .. ":viewport",
      width = "grow",
      height = cell_h,
      scroll_x = true,
      reveal = prefix .. ":caret",
    }),
  }, options)
end
