-- Existing text_input behavior owns editing; these are ordinary layout boxes.
---@type HollowUiLayout
local layout = _G.hollow.ui.layout

---@param input HollowUiTextInput
---@param theme HollowUiTheme
---@param ctx HollowUiLayoutContext
---@param inline boolean|nil
---@return HollowUiLayoutNode
return function(input, theme, ctx, inline)
  local cell_h = ctx.cell_h or 19
  local runs = {}
  for index, span in ipairs(input.render(theme)) do
    runs[index] = layout.column({ layout.text(span.text, span.style, { wrap = "none" }) }, {
      id = index == 2 and "input:caret" or nil,
      height = cell_h,
      style = span.style,
    })
  end
  return layout.column({
    layout.row(runs, {
      id = "input:viewport",
      width = "grow",
      height = cell_h,
      scroll_x = true,
      reveal = "input:caret",
    }),
  }, {
    width = "grow",
    padding = not inline and { x = (ctx.cell_w or 8) * 0.5, y = 2 } or nil,
    style = not inline and { bg = theme.input_bg } or nil,
  })
end
