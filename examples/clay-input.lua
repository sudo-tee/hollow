local hollow = require("hollow")
hollow.config.set({
  default_domain = "demo",
  domains = {
    demo = {
      shell = hollow.platform.is_windows and "powershell.exe" or hollow.platform.default_shell,
    },
  },
  window_title = "Hollow - Clay text input",
  window_width = 1100,
  window_height = 720,
})

hollow.ui.input.open({
  prompt = "Rename workspace (arrows move; Enter confirms; Escape cancels)",
  default = "a-workspace-name-long-enough-to-exercise-horizontal-scrolling-and-caret-reveal",
  width = 65,
  on_confirm = function(value)
    hollow.log("Clay input: " .. value)
  end,
  on_cancel = function()
    hollow.log("Clay input cancelled")
  end,
})
