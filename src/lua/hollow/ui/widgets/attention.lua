local hollow = _G.hollow
local ui = hollow.ui
local theme_api = require("hollow.theme")

local M = {}

local function has_attention_anywhere()
  local workspaces = hollow.term.mux_tree() or {}
  for _, ws in ipairs(workspaces) do
    for _, tab in ipairs(ws.tabs or {}) do
      for _, pane in ipairs(tab.panes or {}) do
        if pane.has_bell and not pane.is_focused then
          return true
        end
      end
    end
  end
  return false
end

function M.topbar_button()
  return ui.bar.custom({
    id = "attention-button",
    render = function()
      if has_attention_anywhere() then
        return ui.span("● ", {
          fg = theme_api.resolve_widget("select").notify_levels.warn,
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
