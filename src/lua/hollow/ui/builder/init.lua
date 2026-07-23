--- Hollow UI Builder
---
--- Compositional widget builder API layered on top of ui.overlay.new and the tag system.
---
--- Usage:
---   local w = require("hollow.ui.builder")
---
--- Concepts:
---   modal   — overlay shell
---   behaviors — state + handlers (selection, text_input)
---   components — rendering (dialog, button, text)

local M = {}

M.modal = require("hollow.ui.builder.modal").modal
M.keys = require("hollow.ui.builder.keys").keys
M.fire = require("hollow.ui.builder.fire").fire
M.list_nav = require("hollow.ui.builder.behaviors.list_nav").list_nav
M.scroll_nav = require("hollow.ui.builder.behaviors.scroll_nav").scroll_nav
M.selectable_list = require("hollow.ui.builder.behaviors.selectable_list").selectable_list
M.text_input = require("hollow.ui.builder.behaviors.text_input").text_input
M.dialog = require("hollow.ui.builder.components.dialog").dialog
M.button = require("hollow.ui.builder.components.button").button
M.buttons = require("hollow.ui.builder.components.button").buttons
M.text = require("hollow.ui.builder.components.text").text

return M
