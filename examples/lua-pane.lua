-- Launch with: hollow --config /path/to/examples/lua-pane.lua
local hollow = require("hollow")
local c = hollow.ui.components

hollow.config.set({
  window_width = 1100,
  window_height = 720,
  default_domain = "shell",
  domains = {
    shell = { shell = hollow.platform.is_windows and "powershell.exe -NoLogo -NoExit" or "/bin/sh" },
  },
})

hollow.events.on("gui:ready", function()
  hollow.ui.pane.split({
    title = "Lua tasks",
    ratio = 0.45,
    state = { renders = 0, mounted = false },
    on_mount = function(ctx)
      ctx.state.mounted = true
    end,
    render = function(ctx)
      ctx.state.renders = ctx.state.renders + 1
      return c.column({
        c.text("Lua pane / Tasks", { bold = true }),
        c.text("Native split. No PTY. Retained Clay surface."),
        c.text(string.format("Grid: %d x %d | pane: %d", ctx.cols, ctx.rows, ctx.pane_id)),
        c.text("Mounted: " .. tostring(ctx.state.mounted)),
        c.text("Render calls: " .. ctx.state.renders),
        c.text("[done] Pane-owned surface and isolated IDs"),
        c.text("[done] Mount, resize and unmount lifecycle"),
        c.text("[next] Keyboard and mouse routing"),
      }, { width = "grow", height = "grow", padding = 16, gap = 10 })
    end,
  })
end)
