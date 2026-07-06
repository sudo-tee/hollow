local util = require("hollow.util")

local hollow = _G.hollow
local ui = hollow.ui

local M = {}

---@param specs HollowUiFormatColumnSpec[]
function M.columns(specs)
  return hollow.tbl(specs or {}):map(function(col)
    local text = tostring(col.text or "")
    local style = col.style
    if col.width then
      local w = col.width
      if col.align == "right" then
        text = util.pad_left(util.truncate_start(text, w), w)
      else
        text = util.pad_right(util.truncate_end(text, w), w)
      end
    end
    return ui.span(text, style)
  end):get()
end

return M
