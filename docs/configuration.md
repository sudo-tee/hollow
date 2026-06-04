# Configuration

Hollow is configured in Lua.
The runtime loads a base config, then an override config on top, then
calls any `hollow.plugins.setup(...)` declarations.
You normally only need a small personal `init.lua` that overrides what you
care about.

This page describes the model and the most common knobs.
For per-key exhaustive reference, see
[`hollow.config`](reference/lua/config.md) and [Themes](themes.md).

## Config layers

Hollow resolves two files in this order:

1. **Base config** — `conf/init.lua` next to the executable, if present;
   otherwise the project copy at `./conf/init.lua`; otherwise the embedded
   fallback compiled into the binary.
2. **Override config** — `--config path` if passed; otherwise the default
   personal location:
   - Windows: `%APPDATA%\hollow\init.lua`
   - Non-Windows: `$XDG_CONFIG_HOME/hollow/init.lua` or
     `$HOME/.config/hollow/init.lua`

The base is loaded first; the override merges on top with the same semantics
as `hollow.config.set(opts)`. Last writer wins for scalars; tables merge
key by key.

That is the key rule: do not copy the whole shipped config into your
personal config. Start with a few lines and override only what you change.

## Minimal override

```lua
local hollow = require("hollow")

hollow.config.set({
  fonts = { size = 16, family = "Cascadia Mono" },
  scrollback = 128_000_000,
  window_titlebar_show = false,
})
```

Reload at runtime with `<leader>uu` (binds `hollow.config.reload()`).

## Common knobs

### Window

```lua
hollow.config.set({
  window_title = "hollow",
  window_width = 1600,
  window_height = 1000,
  window_titlebar_show = false, -- hide the OS title bar
  padding = 5,
})
```

### Fonts

```lua
hollow.config.set({
  fonts = {
    family = "Cascadia Mono",
    size = 14,
    line_height = 0.95,
    smoothing = "grayscale",   -- or "subpixel"
    hinting = "light",        -- or "none", "normal"
    ligatures = true,
    embolden = 0.33,          -- global default
    italic_embolden = 0.5,
    fallbacks = { "Segoe UI Symbol", "Noto Sans Symbols 2" },
  },
})
```

Per-face embolden values override the global `embolden` for one face only:
`regular_embolden`, `bold_embolden`, `italic_embolden`, `bold_italic_embolden`.

List installed families:

```bash
./hollow.exe --list-fonts
./hollow.exe --match-font mono
./hollow.exe --list-fonts --json
```

From Lua:

```lua
local preferred = hollow.fonts.pick({
  "Cascadia Mono",
  "Consolas",
  "DejaVu Sans Mono",
})

if preferred then
  hollow.config.set({ fonts = { family = preferred } })
end
```

### Top bar, scrollbar, hyperlinks

```lua
hollow.config.set({
  top_bar_mode = "always",     -- or "tabs"
  top_bar_height = 24,
  scrollbar = { enabled = false, width = 12, min_thumb_size = 24 },
  hyperlinks = {
    enabled = true,
    shift_click_only = true,
    match_www = true,
    prefixes = "https:// http:// file:// ftp:// mailto:",
  },
})
```

### Performance and debugging

```lua
hollow.config.set({
  max_fps = 120,
  idle_max_fps = 15,
  vsync = false,
  backend = "sokol",           -- primary renderer backend
  command_timing = false,
  debug_overlay = false,
  debug_terminal_trace = false,
})
```

### Domains and shells

A *domain* is a named shell that Hollow knows how to spawn.
The shipped base config defines `pwsh`, `powershell`, `cmd`, and `wsl` on
Windows, and a `unix` domain that uses `hollow.platform.default_shell` on
non-Windows hosts.

```lua
hollow.config.set({
  default_domain = "wsl",      -- default for new tabs/panes
  domains = {
    pwsh = { shell = "pwsh.exe" },
    wsl  = { shell = "C:\\Windows\\System32\\wsl.exe" },
    cmd  = { shell = "cmd.exe" },
  },
})
```

Each domain entry is either a string (the shell) or a table with
`shell`, `default_cwd`, `wsl_distro`, or an `ssh` sub-table.
SSH-backed domains are described in [domains](reference/lua/config.md#domains).

`hollow.config.populate_wsl_domains()` (called by the shipped base config
on Windows) lists your installed WSL distros and adds a domain for each
one in the form `{distro}WSL`.

### Bell

```lua
hollow.config.set({
  bell = {
    visual = true,
    visual_duration_ms = 150,
    visual_color = "#ffcc88",
    visual_alpha = 80,        -- peak opacity 0..255
  },
})
```

`pane.has_bell` is exposed on every pane snapshot, so the shipped top bar
can render an attention marker. The flag clears on focus.

### Workspace bootstrap

```lua
hollow.config.set({
  workspace = {
    auto_bootstrap = "always",     -- or "never"
    default_layout = "default",    -- ~/.config/hollow/layouts/default.json
  },
})
```

When `auto_bootstrap = "always"`, Hollow checks for a project-local
`.hollow/workspace.json` rooted at the active pane cwd first, then falls
back to `workspace.default_layout`. See
[`hollow.workspace`](reference/lua/workspace-api.md).

## Reloading

The shipped config binds `<leader>uu` to `hollow.config.reload()`.
Programmatic reload:

```lua
hollow.config.reload()
```

Reloading re-runs base + override and reapplies the merged result, so
behaviour matches startup.

## Source of truth

The default keys and values shown above come from
[`conf/init.lua`](../conf/init.lua).
The exhaustive schema is in
[`hollow.config`](reference/lua/config.md) and
[`types/hollow.lua`](../types/hollow.lua).
