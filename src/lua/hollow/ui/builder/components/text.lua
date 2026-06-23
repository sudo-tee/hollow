--- Text component.
---
--- Thin wrapper around ui.text / ui.span.
--- Prefer w.text for consistency in builder compositions.

local ui = _G.hollow.ui

local M = {}

---@param value HollowUiInlineNode
---@param style? HollowUiNodeStyle|HollowHexColor
---@return HollowUiRenderableNode
function M.text(value, style)
  if style == nil and type(value) == "table" then
    local shared = require("hollow.ui.shared")
    if shared.is_text_shorthand(value) or shared.is_span_node(value) then
      return value
    end
  end
  return ui.text(value, style)
end

return M
