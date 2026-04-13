-- hollow/ui.lua: load all UI sub-modules, then return event dispatch handles.
require("hollow.ui.runtime")

---@type HollowUiModuleExports
return {
  dispatch_widget_event = hollow.ui.dispatch_widget_event,
  dispatch_overlay_key  = hollow.ui.dispatch_overlay_key,
  handle_bar_node_event = hollow.ui.handle_bar_node_event,
}
