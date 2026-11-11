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

--- Docks on screen in the current context: global ones and the workspace's own.
---@param term table|nil
---@return HollowPane[]
local function context_docks(term)
  local workspace_id = term and term.workspace and term.workspace.id
  local result = {}
  for _, pane in ipairs(term and term.docks or {}) do
    local dock = pane.dock
    if dock and (dock.scope == "global" or dock.workspace_id == workspace_id) then
      result[#result + 1] = pane
    end
  end
  return result
end

--- Badge for hidden panes of the active tab and its docks; absent when
--- nothing is hidden. Colored by the highest attention level among them.
---@param ctx HollowWidgetCtx
---@return HollowUiBarCustomNode|false
function M.topbar_button(ctx)
  local term = ctx and ctx.term
  local hidden = M.list(term and term.tab and term.tab.panes)
  for _, pane in ipairs(M.list(context_docks(term))) do
    hidden[#hidden + 1] = pane
  end
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
