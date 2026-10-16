local hollow = _G.hollow
local ui = hollow.ui
local icons = require("hollow.ui.icons")
local program_status = require("hollow.program_status")
local theme_api = require("hollow.theme")

local M = {}

local function attention_level_anywhere()
  local panes = {}
  local workspaces = hollow.term.mux_tree() or {}
  for _, ws in ipairs(workspaces) do
    for _, tab in ipairs(ws.tabs or {}) do
      for _, pane in ipairs(tab.panes or {}) do
        if not pane.is_focused then
          panes[#panes + 1] = pane
        end
      end
    end
  end
  return program_status.attention_level(panes)
end

function M.topbar_button()
  return ui.bar.custom({
    id = "attention-button",
    render = function()
      local level = attention_level_anywhere()
      if level then
        return ui.span(icons.bell .. " ", {
          fg = theme_api.resolve_widget("select").notify_levels[level],
          bold = true,
        })
      end
      return nil
    end,
    on_click = function()
      ui.mux_navigator.open({
        filter = "pane_bell",
        title = "Attention",
      })
    end,
    cache_ttl_ms = 300,
  })
end

return M
