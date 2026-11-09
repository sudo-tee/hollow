local hollow = _G.hollow
local ui = hollow.ui
local icons = require("hollow.ui.icons")
local program_status = require("hollow.program_status")
local shared = require("hollow.ui.shared")
local styles = require("hollow.ui.recipes.topbar")

local M = {}

---@param panes HollowPane[]|nil
---@return HollowPane[]
function M.list(panes)
  local hidden = {}
  for _, pane in ipairs(panes or {}) do
    if pane.is_hidden == true then
      hidden[#hidden + 1] = pane
    end
  end
  return hidden
end

--- Badge for the active tab's hidden panes; absent when nothing is hidden.
--- Colored by the highest attention level among the hidden panes.
---@param ctx HollowWidgetCtx
---@return HollowUiBarCustomNode|false
function M.topbar_button(ctx)
  local tab = ctx and ctx.term and ctx.term.tab
  local hidden = M.list(tab and tab.panes)
  if #hidden == 0 then
    return false
  end

  local id = "hidden-panes-button"
  local style = styles(shared.bar_palette()).hidden_panes_button
  style.id = id
  local level = program_status.attention_level(hidden)
  return ui.bar.custom({
    id = id,
    style = style,
    render = function()
      return ui.span(
        icons.pane_hidden .. " " .. #hidden,
        styles(shared.palette("select"), { variant = level }).attention
      )
    end,
    on_click = function()
      ui.mux_navigator.open({ filter = "hidden" })
    end,
  })
end

return M
