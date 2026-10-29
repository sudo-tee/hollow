local hollow = _G.hollow
local ui = hollow.ui
local icons = require("hollow.ui.icons")
local shared = require("hollow.ui.shared")
local styles = require("hollow.ui.styles.topbar")

local M = {}
local LEVELS = styles.slots.attention.variants

function M.topbar_button()
  local style = styles(shared.bar_palette()).attention_button
  style.id = "attention-button"
  return ui.bar.custom({
    id = "attention-button",
    style = style,
    render = function()
      local summary = hollow.activity.summary()
      local pending = summary.count > 0
      local level = pending and LEVELS[summary.level] and summary.level or nil
      return ui.span(
        pending and (icons.bell .. " " .. summary.count .. " ") or (icons.bell_outline .. " "),
        styles(shared.palette("select"), { variant = level }).attention
      )
    end,
    on_click = function()
      ui.activity.open()
    end,
  })
end

return M
