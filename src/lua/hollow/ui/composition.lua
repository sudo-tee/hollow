local ui = _G.hollow.ui

ui.modal = require("hollow.ui.modal").modal
ui.keys = require("hollow.ui.keys").keys
ui.fire = require("hollow.ui.fire").fire
ui.list_nav = require("hollow.ui.behaviors.list_nav").list_nav
ui.scroll_nav = require("hollow.ui.behaviors.scroll_nav").scroll_nav
ui.selectable_list = require("hollow.ui.behaviors.selectable_list").selectable_list
ui.text_input = require("hollow.ui.behaviors.text_input").text_input
ui.text_view = require("hollow.ui.behaviors.text_view").text_view

return true
