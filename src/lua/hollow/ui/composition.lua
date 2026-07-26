local ui = _G.hollow.ui

ui.modal = require("hollow.ui.builder.modal").modal
ui.keys = require("hollow.ui.builder.keys").keys
ui.fire = require("hollow.ui.builder.fire").fire
ui.list_nav = require("hollow.ui.builder.behaviors.list_nav").list_nav
ui.scroll_nav = require("hollow.ui.builder.behaviors.scroll_nav").scroll_nav
ui.selectable_list = require("hollow.ui.builder.behaviors.selectable_list").selectable_list
ui.text_input = require("hollow.ui.builder.behaviors.text_input").text_input
ui.dialog = require("hollow.ui.builder.components.dialog").dialog

return true
