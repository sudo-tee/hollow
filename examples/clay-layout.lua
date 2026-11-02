-- Standalone opt-in demo: launch Hollow with --config pointing to this file.
-- This replaces the window config; from a running session (e.g. the Lua REPL)
-- call `hollow.ui.components.demo()` instead.
local hollow = require("hollow")
local windows = hollow.platform.is_windows
hollow.config.set({
  default_domain = "demo",
  domains = { demo = { shell = windows and "powershell.exe" or hollow.platform.default_shell } },
  window_title = "Hollow - Clay layout experiment",
  window_width = 1100,
  window_height = 720,
  top_bar_mode = "never",
  fonts = { family = "JetBrains Mono", size = 14 },
})
hollow.ui.components.demo()
