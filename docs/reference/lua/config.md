# `hollow.config`

Read, write, and reload configuration. The runtime resolves a base
config (the shipped `conf/init.lua`) and an override config
(`%APPDATA%\hollow\init.lua` on Windows,
`$XDG_CONFIG_HOME/hollow/init.lua` elsewhere) at startup and on reload.

For the conceptual model see [Configuration](../../configuration.md).
For the LuaLS schema see
[`types/hollow.lua`](../../../types/hollow.lua) (`HollowConfig`,
`HollowDomainConfig`, `HollowSshDomainConfig`).

## Functions

```lua
hollow.config.set(opts)        -- merge opts into the current config
hollow.config.get(key)         -- read a value
hollow.config.snapshot()       -- a deep copy of the merged config
hollow.config.reload()         -- re-run base + override and reapply

hollow.config.populate_wsl_domains()  -- Windows: add a domain per installed WSL distro
```

`set` is a merge, not a replace: nested tables merge key-by-key, last
writer wins for scalars. `reload()` is what `<leader>uu` is bound to
in the shipped base config.

## Top-level keys

| Key | Type | Notes |
| --- | --- | --- |
| `fonts` | table | Font family, size, hinting, smoothing, embolden, fallbacks |
| `theme` | string or table | Built-in theme name or inline spec |
| `scrollback` | integer | Lines of history |
| `cols`, `rows` | integer | Initial grid size |
| `padding` | integer | Cell padding in pixels |
| `window_title`, `window_width`, `window_height` | string, integer | Window geometry |
| `window_titlebar_show` | boolean | Show the OS title bar |
| `top_bar_mode` | `"always"` \| `"tabs"` | When to show the top bar |
| `top_bar_height`, `top_bar_bg` | integer, color | Top bar geometry |
| `bottom_bar_show`, `bottom_bar_height`, `bottom_bar_bg`, `bottom_bar_draw_status` | mixed | Bottom bar |
| `scrollbar` | table | Scrollbar config |
| `hyperlinks` | table | OSC 8 hyperlink config |
| `cursor` | table | Cursor style, blink |
| `unfocused_pane` | table | Cursor and dim style for unfocused panes |
| `shell` | string or string[] | Default shell (when no domain is set) |
| `default_domain` | string | Domain used for new tabs / panes |
| `domains` | table<string, string or table> | Domain table |
| `env` | table<string, string> | Extra env vars injected into guests |
| `workspace` | table | `auto_bootstrap`, `default_layout` |
| `max_fps`, `idle_max_fps` | integer | Renderer framerate cap |
| `vsync` | boolean | Renderer vsync |
| `backend` | string | Primary renderer backend (`"sokol"`) |
| `command_timing` | boolean | On-screen command timing overlay |
| `load_default_keymaps` | boolean | Register shipped keymaps (default `true`) |
| `debug_overlay`, `debug_terminal_trace` | boolean | Debug overlays |
| `bell` | table | Visual bell config |

### Fonts

```lua
hollow.config.set({
  fonts = {
    family = "Cascadia Mono",
    size = 14,
    line_height = 0.95,
    smoothing = "grayscale",   -- or "subpixel"
    hinting = "light",         -- or "none", "normal"
    ligatures = true,
    embolden = 0.33,           -- global default
    regular_embolden = 0.0,    -- per-face overrides
    bold_embolden = 0.0,
    italic_embolden = 0.5,
    bold_italic_embolden = 0.0,
    fallbacks = { "Segoe UI Symbol", "Noto Sans Symbols 2" },
  },
})
```

### Scrollbar

```lua
hollow.config.set({
  scrollbar = {
    enabled = true,
    width = 12,
    min_thumb_size = 24,
    margin = 2,
    jump_to_click = true,
    track = "#000000",
    thumb = "#7e9cd8",
    thumb_hover = "#a0bfee",
    thumb_active = "#c0d8ff",
    border = "#000000",
  },
})
```

### Hyperlinks

```lua
hollow.config.set({
  hyperlinks = {
    enabled = true,
    shift_click_only = true,
    match_www = true,
    prefixes = "https:// http:// file:// ftp:// mailto:",
    delimiters = " \t\r\n\"'<>[]{}|\\^`",
    trim_leading = "([<{'\"",
    trim_trailing = ".,;:!?)]}",
  },
})
```

### Cursor

```lua
hollow.config.set({
  cursor = {
    style = "block",        -- "block" | "bar" | "underline" | "block_hollow"
    blink = true,
    blink_rate = 500,
  },
})
```

### Bell

```lua
hollow.config.set({
  bell = {
    visual = true,
    audible = false,         -- reserved, currently a no-op
    visual_duration_ms = 150,
    visual_color = "#ffcc88",
    visual_alpha = 80,       -- 0..255
  },
})
```

## Domains

A *domain* is a named shell the runtime can spawn. `domains` maps a
domain name to either a shell string or a table with per-domain
options.

```lua
hollow.config.set({
  default_domain = "wsl",
  domains = {
    pwsh       = { shell = "pwsh.exe" },
    powershell = { shell = "powershell.exe" },
    cmd        = { shell = "cmd.exe" },
    wsl        = { shell = "C:\\Windows\\System32\\wsl.exe",
                   default_cwd = "/home/me" },
    unix       = { shell = "/bin/zsh" },
  },
})
```

### WSL domains

The shipped base config calls `hollow.config.populate_wsl_domains()`
on Windows. It enumerates `wsl.exe -l` and creates one domain per
distro named `{distro}WSL`, plus a default `wsl` domain.

You can also address a specific distro by hand:

```lua
hollow.config.set({
  domains = {
    wsl = { shell = "wsl.exe -d Ubuntu" },
  },
})
```

### SSH domains

```lua
hollow.config.set({
  domains = {
    devbox = {
      ssh = {
        alias = "devbox",            -- SSH config host alias
        host = "10.0.0.8",           -- or use `host` directly
        user = "root",
        backend = "wsl",             -- "native" or "wsl"
        reuse = "auto",              -- "none" or "auto"
      },
    },
  },
})
```

- `alias` uses an SSH config host directly when `host` is not set.
- `host` makes Hollow prefer `user@host`.
- `backend = "wsl"` launches the SSH client through `wsl.exe`. This
  is the practical choice on Windows when you want Linux-side SSH
  config and agent behaviour.
- `reuse = "auto"` enables OpenSSH multiplexing flags for
  WSL/Linux-backed SSH domains. Native Windows OpenSSH falls back
  safely without extra flags.

See [WSL → WSL workflow patterns](../../platforms/wsl.md#wsl-workflow-patterns).

## Workspace bootstrap

```lua
hollow.config.set({
  workspace = {
    auto_bootstrap = "always",   -- or "never"
    default_layout = "default",  -- ~/.config/hollow/layouts/default.json
  },
})
```

When `auto_bootstrap = "always"`, Hollow checks for
`.hollow/workspace.json` rooted at the active pane cwd first, then
falls back to `workspace.default_layout`. See
[`hollow.workspace`](workspace-api.md).

## Snapshot

```lua
local snap = hollow.config.snapshot()
print(hollow.json.encode(snap, { indent = true }))
```

`snapshot()` returns a deep copy. Use it for debugging or for code
that needs to read config without reflecting later writes.

## See also

- [Configuration](../../configuration.md) — guide
- [`types/hollow.lua`](../../../types/hollow.lua) — `HollowConfig`
- [`hollow.theme`](theme.md) — theme specs
- [`hollow.term`](term.md) — read term state
