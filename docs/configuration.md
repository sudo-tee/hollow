# Configuration

Hollow is configured with Lua.

The shipped app loads a bundled base config first and then applies a user
override config on top. In practice that means users usually only need a small
`init.lua` with the settings they actually want to change.

This page describes the current product behavior, with `conf/init.lua` as the
shipped default.

## At A Glance

- Audience: users customizing Hollow and maintainers shaping the default config
- Source of truth: `conf/init.lua`
- Main ideas: base config, override config, domains, fonts, packaged defaults

## Use This Page To

- understand how Hollow resolves config files at startup
- override the shipped defaults without copying the whole config
- customize fonts, domains, UI, and keymaps
- package Hollow with a sensible editable default

## Config Model

At startup Hollow resolves one base config and one override config.

Base config resolution:

1. `conf/init.lua` next to the executable, when present
2. otherwise `conf/init.lua` in the current project directory
3. otherwise the embedded fallback compiled into the executable

Override config resolution:

1. the file passed through `--config path`, when provided
2. otherwise the default user config path, if that file exists

Default user config paths:

- Windows: `%APPDATA%\hollow\init.lua`
- Non-Windows hosts: `$XDG_CONFIG_HOME/hollow/init.lua` or `$HOME/.config/hollow/init.lua`

Load order is always base first, override second.

That is the key rule: do not copy the whole shipped config into your personal
config unless you actually want to fork it. Start small and override only what
you care about.

## Minimal User Config

```lua
local hollow = require("hollow")

hollow.config.set({
  fonts = {
    size = 16,
  },
  scrollback = 128_000_000,
  window_titlebar_show = false,
})
```

## Shipped Defaults

The shipped `conf/init.lua` sets up a usable default product experience rather
than a personal setup.

| Area | Current default |
|---|---|
| Backend | `sokol` |
| Theme | dark terminal theme with matching widget/top-bar colors |
| Fonts | `Consolas` on Windows, `Menlo` on macOS, `DejaVu Sans Mono` elsewhere |
| Font size | `14.5` |
| Window | `1440x900`, `120x34` |
| Top bar | workspace, tabs, cwd, leader legend, and time |
| Scrollbar | enabled |
| Hyperlinks | enabled, with shift-click opening |
| Windows domains | `pwsh`, `powershell`, `cmd`, `wsl` |
| Default domain on Windows | `pwsh` |
| Default domain elsewhere | `unix`, using `hollow.platform.default_shell` |
| Reload UX | `<leader>uu` reloads config and shows a notification |

The bundled config also installs a default keymap for tabs, panes, workspaces,
clipboard, scrolling, floating panes, and pane movement.

It intentionally does not include:

- personal SSH hosts
- local project paths
- machine-specific automation
- debug logging or demo-only UI

## Common Overrides

Font size:

```lua
hollow.config.set({
  fonts = {
    size = 16,
  },
})
```

Pick a font family by name:

```lua
hollow.config.set({
  fonts = {
    family = "Cascadia Mono",
  },
})
```

Override one style and add fallbacks:

```lua
hollow.config.set({
  fonts = {
    family = "Cascadia Mono",
    bold = "Cascadia Code",
    fallbacks = {
      "Segoe UI Symbol",
      "Noto Sans Symbols 2",
    },
  },
})
```

Window size:

```lua
hollow.config.set({
  window_width = 1600,
  window_height = 1000,
})
```

Turn off the scrollbar:

```lua
hollow.config.set({
  scrollbar = {
    enabled = false,
  },
})
```

Adjust the top bar:

```lua
hollow.config.set({
  top_bar_show_when_single_tab = false,
  top_bar_height = 22,
})
```

Switch the default shell on Windows to WSL:

```lua
hollow.config.set({
  default_domain = "wsl",
})
```

## Fonts

From a development checkout, inspect discoverable fonts with the wrapper:

```bash
./launch.sh --list-fonts
```

Filter likely matches:

```bash
./launch.sh --match-font mono
```

Emit structured JSON:

```bash
./launch.sh --list-fonts --json
```

From a packaged build, run the same flags on `hollow-native.exe` directly.

From Lua, inspect the same inventory:

```lua
for _, font in ipairs(hollow.fonts.list()) do
  if font.family == "Cascadia Mono" then
    print(font.family, table.concat(font.styles, ", "))
  end
end
```

Pick the first installed font from a preference list:

```lua
local preferred = hollow.fonts.pick({
  "Cascadia Mono",
  "Consolas",
  "DejaVu Sans Mono",
})

if preferred then
  hollow.config.set({
    fonts = {
      family = preferred,
    },
  })
end
```

## Domains And Shells

The bundled config keeps the domain model explicit.

Current default domains:

- Windows: `pwsh`
- Non-Windows hosts: `unix`

Bundled Windows domains:

- `pwsh`
- `powershell`
- `cmd`
- `wsl`

Use WSL as the default shell instead:

```lua
local hollow = require("hollow")

hollow.config.set({
  default_domain = "wsl",
})
```

Customize the shipped WSL domain:

```lua
local hollow = require("hollow")

hollow.config.set({
  domains = {
    wsl = {
      shell = "C:\\Windows\\System32\\wsl.exe",
    },
  },
})
```

Example SSH domain:

```lua
local hollow = require("hollow")

hollow.config.set({
  domains = {
    devbox = {
      ssh = {
        alias = "devbox",
        backend = "wsl",
        reuse = "auto",
      },
    },
  },
})
```

`backend = "wsl"` is the practical choice on Windows when you want Linux-side
SSH config, agent behavior, and multiplexing.

## Widgets And Keymaps

Hollow exposes widgets and keymaps directly from Lua.

```lua
local hollow = require("hollow")

hollow.ui.topbar.mount(hollow.ui.topbar.new({
  render = function(ctx)
    return {
      hollow.ui.span(" " .. (ctx.term.pane and ctx.term.pane.cwd or "") .. " "),
      hollow.ui.spacer(),
      hollow.ui.bar.time("%H:%M:%S"),
    }
  end,
}))

hollow.keymap.set("<leader>uu", function()
  hollow.config.reload()
end, { desc = "reload config" })
```

Advanced workspace launchers can be configured through
`hollow.ui.workspace.configure(...)`, including WSL and SSH-backed sources.

## Reloading Config

The shipped config defines:

```lua
<leader>uu
```

to reload config.

You can also call:

```lua
hollow.config.reload()
```

Reloading reapplies the resolved base config first and then the active override
config, so it behaves the same way as startup.

## Packaging

For a packaged Windows release, ship at least:

- `hollow-native.exe`

Optional but recommended:

- `conf/init.lua`, if you want the packaged default to stay editable without rebuilding

That gives users a working default experience even before they create a personal
config.

## Related Docs

- [windows-wsl.md](windows-wsl.md) for the primary Windows/WSL workflow
- [hollow-lua-api.md](hollow-lua-api.md) for the runtime API reference
- `types/hollow.lua` for LuaLS typings
