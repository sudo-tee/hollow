local hollow = _G.hollow
local ui = hollow.ui
local icons = require("hollow.ui.icons")
local shared = require("hollow.ui.shared")
local theme_api = require("hollow.theme")

local M = {}

function M.topbar_button()
  return ui.bar.custom({
    id = "attention-button",
    style = {
      id = "attention-button",
      padding = { left = 6, right = 6 },
      margin = { right = 6 },
      radius = 4,
      hover = { bg = shared.resolve_theme().ui.tab_bar.hover_tab.bg },
    },
    render = function()
      local summary = hollow.activity.summary()
      local pending = summary.count > 0
      local theme = theme_api.resolve_widget("select")
      return ui.span(
        pending and (icons.bell .. " " .. summary.count .. " ") or (icons.bell_outline .. " "),
        {
          fg = pending and theme.notify_levels[summary.level] or theme.muted,
          bold = pending,
        }
      )
    end,
    on_click = function()
      ui.activity.open()
    end,
  })
end

return M
