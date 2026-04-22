# Hollow Term

<div align="center">
    <img src="assets/banner.png" alt="Hollow demo" width="600"/>
</div>

Hollow is a Zig terminal emulator with a LuaJIT runtime and Ghostty's VT core.
The project is still early, but the current direction is already clear: native
rendering, Lua-configured behavior, and a widget-driven UI layer.

## What works now

- native build and launch via `./launch.sh`
- Lua config loading from `conf/init.lua` or the user config path
- tabs, split panes, workspaces, scrollback, selection, clipboard, and hyperlinks
- namespaced Lua API: `hollow.config`, `hollow.term`, `hollow.events`, `hollow.keymap`, `hollow.ui`
- widget surfaces for topbar, sidebar, and overlay stacks
- optional sidebar reservation so the terminal can shrink around the sidebar instead of drawing under it
- LuaLS typings in `types/hollow.lua`

## Build

```bash
./launch.sh
./launch.sh --build-only
```

The Windows executable is emitted at `zig-out/bin/hollow-native.exe`.

## Config model

Hollow now uses the namespaced API directly:

```lua
local hollow = require("hollow")

hollow.config.set({
    backend = "sokol",
    shell = "pwsh.exe",
    cols = 120,
    rows = 34,
    scrollback = 64_000_000,
})

hollow.ui.topbar.mount(hollow.ui.topbar.new({
    render = function(ctx)
        return {
            hollow.ui.span(ctx.term.pane.cwd or "", { fg = "#dcd7ba" }),
            hollow.ui.spacer(),
            hollow.ui.span(hollow.strftime("%H:%M:%S"), { fg = "#7e9cd8" }),
        }
    end,
}))

hollow.keymap.set("<C-S-n>", hollow.term.new_tab)
```

## SSH Domains

Hollow supports first-class SSH domains in addition to plain shell domains.

Example:

```lua
hollow.config.set({
    default_domain = "wsl",
    domains = {
        wsl = {
            shell = "C:\\Windows\\System32\\wsl.exe",
            default_cwd = "/home/me",
        },
        tower = {
            ssh = {
                host = "10.0.0.8",
                user = "root",
                backend = "wsl", -- "native" or "wsl"
                reuse = "auto", -- "none" or "auto"
            },
        },
    },
})
```

Fields:

- `host`: remote hostname or IP
- `user`: optional SSH user
- `alias`: optional SSH config host alias; used when `host` is omitted
- `backend`: `"native"` uses the host SSH client, `"wsl"` uses `wsl.exe ssh ...` on Windows
- `reuse`: `"auto"` enables OpenSSH multiplexing where supported

Behavior:

- New tabs and split panes inherit the current domain, including SSH domains.
- When `host` is set, Hollow prefers `user@host` over `alias`.
- `backend = "wsl"` is the best choice on Windows if you want Linux-side SSH config and connection reuse.

Connection reuse:

- `reuse = "auto"` enables OpenSSH multiplexing flags for WSL-backed SSH domains on Windows and for native SSH on Linux/macOS.
- Native Windows `ssh.exe` does not reliably support the same multiplexing flow, so Hollow intentionally falls back to normal SSH launches there.
- If you want passwordless repeated connections on native Windows, use SSH keys and `ssh-agent`.

SSH workspace sources:

```lua
hollow.ui.workspace.configure({
    sources = {
        {
            domain = "tower",
            resolver = "ssh",
            roots = {
                "/home/root/projects",
            },
        },
    },
})
```

This scans the listed remote roots by running a non-interactive `find` command through the configured SSH domain. In practice that means the domain must already support non-interactive auth, such as SSH keys, `ssh-agent`, or WSL-backed multiplexing.

## UI widgets

Widgets use shared primitives:

- `hollow.ui.span(text, style?)`
- `hollow.ui.spacer()`
- `hollow.ui.icon(name, style?)`
- `hollow.ui.group(children, style?)`

Available surfaces:

- `hollow.ui.topbar`
- `hollow.ui.sidebar`
- `hollow.ui.overlay`
- `hollow.ui.notify`
- `hollow.ui.input`
- `hollow.ui.select`

Sidebar reservation is opt-in:

```lua
hollow.ui.sidebar.mount(hollow.ui.sidebar.new({
    side = "left",
    width = 28,
    reserve = true,
    render = function(ctx)
        return {
            { hollow.ui.span("tabs", { bold = true }) },
            { hollow.ui.span("active: " .. ctx.term.tab.title) },
        }
    end,
}))
```

When `reserve = true`, Hollow reduces the terminal layout width to make room for
the sidebar. When the sidebar is hidden or unmounted, that space is released.

## Docs and typings

- API reference: `hollow-lua-api.md`
- LuaLS typings: `types/hollow.lua`
- default example config: `conf/init.lua`

## Notes

- `require("hollow")` returns the injected global runtime table.
- The old flat Lua API has been removed from the default config surface.
- `hollow.htp` and `hollow.process` still exist as planned namespaces, but are not fully implemented yet.
