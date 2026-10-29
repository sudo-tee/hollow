-- Compare this with the same confirm.open call without `layout = "clay"`.
local hollow = require("hollow")
hollow.config.set({
  default_domain = "demo",
  domains = {
    demo = {
      shell = hollow.platform.is_windows and "powershell.exe" or hollow.platform.default_shell,
    },
  },
  window_title = "Hollow - Clay confirmation",
  window_width = 1100,
  window_height = 720,
})

hollow.ui.confirm.open({
  layout = "clay",
  title = "Delete archived tasks?",
  prompt = "This is the existing confirmation dialog using Clay geometry. Tab or arrow keys change the selected action. Enter confirms; Escape cancels. The same callbacks and overlay shell are retained.",
  width = 65,
  buttons = {
    { text = "Keep tasks", value = false },
    { text = "Delete tasks", kind = "destructive", value = true },
  },
  on_confirm = function(value)
    hollow.log("Clay confirmation: " .. tostring(value))
  end,
  on_cancel = function()
    hollow.log("Clay confirmation cancelled")
  end,
})
