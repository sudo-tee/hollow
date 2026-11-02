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
    state = { renders = 0, mounted = false, key = "Press F6", focused = false, clicks = 0 },
    on_mount = function(ctx)
      ctx.state.mounted = true
    end,
    on_focus = function(ctx, focused)
      ctx.state.focused = focused
    end,
    on_key = function(key, mods, ctx)
      if key == "f6" and mods == "" then
        ctx.state.key = "F6 handled by Lua pane"
        return true
      end
      return false
    end,
    render = function(ctx)
      ctx.state.renders = ctx.state.renders + 1
      return c.column({
        c.text("Lua pane / Tasks", { bold = true }),
        c.text("Native split. No PTY. Retained Clay surface."),
        c.text(string.format("Grid: %d x %d | pane: %d", ctx.cols, ctx.rows, ctx.pane_id)),
        c.text("Mounted: " .. tostring(ctx.state.mounted)),
        c.text("Render calls: " .. ctx.state.renders),
        c.text("Focused: " .. tostring(ctx.state.focused) .. " | " .. ctx.state.key),
        c.text("Hovered node: " .. (ctx.hovered_id or "none")),
        c.button({
          id = "increment",
          text = "Clicks: " .. ctx.state.clicks,
          on_click = function()
            ctx.state.clicks = ctx.state.clicks + 1
          end,
        }),
        c.text("[done] Pane-owned surface and isolated IDs"),
        c.text("[done] Mount, resize and unmount lifecycle"),
        c.text("[done] Keyboard and focus routing"),
        c.text("[done] Isolated click and hover routing"),
      }, { width = "grow", height = "grow", padding = 16, gap = 10 })
    end,
  })
end)
