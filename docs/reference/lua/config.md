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

| Key                                                                               | Type                           | Notes                                                           |
| --------------------------------------------------------------------------------- | ------------------------------ | --------------------------------------------------------------- |
| `fonts`                                                                           | table                          | Font family, size, hinting, smoothing, embolden, fallbacks      |
| `theme`                                                                           | string or table                | Built-in theme name or inline spec                              |
| `scrollback`                                                                      | integer                        | Lines of history                                                |
| `cols`, `rows`                                                                    | integer                        | Initial grid size                                               |
| `padding`                                                                         | integer                        | Cell padding in pixels                                          |
| `window_title`, `window_width`, `window_height`                                   | string, integer                | Window title; window size at startup only                       |
| `restore_window_placement`                                                       | boolean                        | Restore/save Windows placement; default `true`; see [guide](../../window-placement.md) |
| `window_titlebar_show`                                                            | boolean                        | Show the OS title bar                                           |
| `top_bar_mode`                                                                    | `"always"` \| `"tabs"`         | When to show the top bar                                        |
| `top_bar_height`, `top_bar_bg`                                                    | integer, color                 | Top bar geometry                                                |
| `bottom_bar_show`, `bottom_bar_height`, `bottom_bar_bg`, `bottom_bar_draw_status` | mixed                          | Bottom bar                                                      |
| `scrollbar`                                                                       | table                          | Scrollbar config                                                |
| `hyperlinks`                                                                      | table                          | OSC 8 hyperlink config                                          |
| `cursor`                                                                          | table                          | Cursor style, blink                                             |
| `unfocused_pane`                                                                  | table                          | Cursor and dim style for unfocused panes                        |
| `shell`                                                                           | string or string[]             | Default shell (when no domain is set)                           |
| `default_domain`                                                                  | string                         | Domain used for new tabs / panes                                |
| `domains`                                                                         | table<string, string or table> | Domain table                                                    |
| `env`                                                                             | table<string, string>          | Extra env vars injected into guests                             |
| `workspace`                                                                       | table                          | `auto_bootstrap`, `default_layout`                              |
| `max_fps`, `idle_max_fps`                                                         | integer                        | Renderer framerate cap                                          |
| `vsync`                                                                           | boolean                        | Renderer vsync                                                  |
| `synchronized_output`                                                             | boolean                        | Hold last frame during DEC mode 2026 (default `true`)           |
| `alternate_screen_resize_nudge`                                                   | boolean                        | Delayed resize cycle on alternate-screen entry (default `true`) |
| `hide_mouse_cursor_when_typing`                                                   | boolean                        | Hide OS mouse cursor during keyboard input                      |
| `paste_protection`                                                                | boolean                        | Confirm pastes that could run commands (default `true`)         |
| `backend`                                                                         | string                         | Primary renderer backend (`"sokol"`)                            |
| `command_timing`                                                                  | boolean                        | On-screen command timing overlay                                |
| `load_default_keymaps`                                                            | boolean                        | Register shipped keymaps (default `true`)                       |
| `debug_overlay`, `debug_terminal_trace`                                           | boolean                        | Debug overlays                                                  |
| `bell`                                                                            | table                          | Visual bell config                                              |

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

The cursor defaults to a steady block.
Applications such as Neovim can temporarily choose their own cursor shape and blink state.
`blink_rate` is the duration of each visible or hidden phase in milliseconds and defaults to `600`.
`blink_timeout` keeps the cursor steady after that many milliseconds without keyboard input or paste.
It defaults to `0` (no timeout).
Cursor thicknesses are in framebuffer pixels, limited to `1–16` and to the cell size.
`bar_thickness = false` uses the automatic width (usually 2–3 px); underline and hollow outline thicknesses default to `4` and `2`.
Only the focused pane can blink.
`rounded` controls rounding on bars, filled blocks, and hollow blocks, and defaults to `true`.
`busy` selects the steady cursor shown during a foreground command reported by shell integration.
It defaults to `"block"`; use `false` to keep the normal cursor behavior while a command runs.
Alternate-screen programs retain control of their cursor style.
`unfocused` selects a steady cursor for unfocused panes.
The bundled config uses `"block_hollow"`; use `false` to hide it.
The legacy `unfocused_pane.cursor` still works; when both spellings appear in the same `hollow.config.set` call, `cursor.unfocused` wins.
Pane dimming remains under `unfocused_pane.dim`.

```lua
hollow.config.set({
  cursor = {
    style = "block",        -- "block" | "bar" | "underline" | "block_hollow"
    blink = true,
    blink_rate = 500,
    blink_timeout = 2500,
    bar_thickness = 3,
    underline_thickness = 2,
    hollow_thickness = 1,
    busy = "block",
    unfocused = "block_hollow",
    rounded = true,
    trail = { decay = 450, min_distance = 8, color = "#88c0d0" },
  },
})
```

`trail` is read by [compatible cursor shaders](../../custom-shaders.md), including the shipped `cursor_trail.glsl`.
It does not enable a trail or change existing shaders that ignore the new inputs.

### Background

```lua
hollow.config.set({
  background = {
    opacity = 0.9,          -- 0..1, window transparency (startup decides the surface)
    backdrop = "acrylic",   -- Windows 11 22H2+; default "none"
    cell_opacity = 0.7,     -- explicit cell backgrounds; default 1
    powerline_opacity = true, -- fade separators with cell_opacity; default false
    powerline_glyphs = { "◀", "▶" }, -- extend U+E0B0..U+E0BF; default {}
    image = {               -- or a path string, or false
      path = "/home/me/wallpaper.png",
      fit = "cover",        -- "cover" | "contain" | "stretch" | "tile" | "center"
      opacity = 0.5,
    },
    shader = {              -- or a path string, or false
      path = "/home/me/shaders/aurora_background.glsl",
      opacity = 1,
      animate = true,       -- request animation redraws
      max_fps = 30,         -- optional background-only refresh cap; default 0
      render_scale = 0.5,   -- optional background-only resolution scale; default 1
    },
  },
})
```

See [Background and transparency](../../background.md).

### Custom Shaders

```lua
hollow.config.set({
  custom_shader = "/home/me/shaders/cursor_smear.glsl", -- or a list, or false
  shader_animation = "cursor", -- "cursor" | "always" | "off", or a boolean
})
```

See [Custom shaders](../../custom-shaders.md).

### Mouse Cursor

This option defaults to `true`. Set it to `false` to keep the OS mouse cursor
visible while typing. Mouse movement shows the cursor again.

```lua
hollow.config.set({ hide_mouse_cursor_when_typing = true })
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

A _domain_ is a named shell the runtime can spawn. `domains` maps a
domain name to either a shell string or a table with per-domain
options.

```lua
hollow.config.set({
  default_domain = "UbuntuWSL",
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

### Persistent domains (experimental)

Set `domains.<name>.persist = true` to create host-owned persistent workspaces on that domain.
The default is `false`; existing workspaces are not converted.
Supported owners run on Linux, including WSL and SSH hosts.
Native Windows owners are not implemented yet.
Failed persistent host resolution never falls back to a native ordinary shell.
An opted-in default domain also uses asynchronous owner creation at startup, with a visible connecting or failure card.
Automatic startup reattachment is not implemented yet.
See the [persistent sessions guide](../../persistent-sessions-guide.md) before opting in.

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
        backend = "UbuntuWSL",             -- "native" or "wsl"
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

### Agent hosts

By default, `host` runs each pane of the domain as `hollow-agent pty` on a host
bootstrapped by [`hollow.host`](host.md):

```lua
hollow.config.set({
  domains = {
    build = { host = { type = "ssh", destination = "build" } },
    dev   = { host = { type = "podman", container = "dev" } },
    wsl   = { shell = "wsl.exe", host = false }, -- always ConPTY
  },
})
```

- `type` is `"wsl"`, `"ssh"`, `"podman"` or `"docker"`; other fields are that
  connector's options. Optional `path_style = "posix"|"wsl"`.
- An explicit `host` never falls back: failures show a red `[hollow]` banner
  and the pane exits.
- On Windows, WSL domains (`wsl_distro` or `wsl.exe -d X`) use the agent
  implicitly and fall back to ConPTY. `host = false` opts out.

See [`hollow.host` → Pane PTYs](host.md#pane-ptys).

### Experimental shared terminal connections

Agent-backed domains can explicitly select multiplexing:

```lua
hollow.config.set({
  domains = {
    Ubuntu = {
      wsl_distro = "Ubuntu", -- implicit WSL agent on Windows
      pty = { mode = "mux" },
    },
    build = {
      host = { type = "ssh", destination = "build" },
      pty = { mode = "mux" },
    },
  },
})
```

Add `pty` to your existing domain; leave its shell, host, and environment intact.
Omitting `pty`, or setting `pty.mode = "dedicated"`, preserves the default
one-connector-per-pane backend. These options affect **new panes** only.
`host = false` still selects native PTYs; `pty` does not turn a native domain
into an agent host.

- `read_workers`: integer 0–4, default 4 when mux is selected. Values 1–4 select
  persistent reader threads in the shared agent, not one thread per pane. Each
  pane's PTY is assigned to one reader; readers send output directly over the
  shared transport. Set `read_workers = 0` for inline reads on the agent's main
  thread; this still uses mux, not dedicated connections. The setting is passed
  to the target agent, not read from the GUI process environment.
- `batch_jobs`: 1 or 2, default 2. Retained for compatibility with existing
  configurations; it has **no scheduling or performance effect** with persistent
  readers. New configurations can omit it; old batch-tuning advice no longer
  applies.
- Matching connector argv/quoting, deployment/artifacts, and tuning share one
  terminal connection, including concurrent bootstrap. Cwd, environment, command,
  size, and close remain per pane. Up to 32 streams share a connection; overflow
  creates another, with a process-wide cap of 16 live terminal connections.
- Last live stream closes the connection; no idle connection retention. A failed
  connection visibly fails its remaining panes. Shells are never automatically
  restarted or input replayed after spawn submission. A new pane can reconnect.
- Filesystem/exec traffic remains separate. Connection failure now has a shared
  failure domain; dedicated mode remains the default and rollback path.

To roll back, set `pty = { mode = "dedicated" }`, reload the config, and open
new panes. Existing panes retain their current connection. This is different
from `read_workers = 0`, which only changes how a mux agent reads PTYs.

#### What difference does mux make?

In the October 21 four-pane Windows/WSL head-to-head, current mux had similar
throughput and helper-inclusive Windows CPU with substantially lower helper RSS:

| Measurement | Dedicated (default) | Mux |
| --- | ---: | ---: |
| Agent helper processes | 4 | 1 |
| Sampled agent memory | 3.38 MiB | 0.72 MiB |
| Uncapped producer-admitted output (median) | 41.27 MiB/s | 42.08 MiB/s |
| Loaded Windows CPU, including captured helpers | 1.251 cores | 1.232 cores |
| Loaded ACK observation p99 | 17.55 ms | 15.79 ms |

Both sustained 10 MiB/s in three qualified capped pairs; one capped pair was
excluded for unmatched producer rate. Four uncapped and four echo pairs passed.
Memory covers Linux agent helpers, not the whole app; Windows CPU includes
captured helpers but excludes shared WSL/VM services and Linux processes. Output
speed is not screen refresh rate, and ACK observation includes IPC/text-query
overhead rather than physical keyboard-to-display latency. Paired variation and
occasional higher mux maxima remain visible in the
[current report](../../windows-mux-cpu.md#current-mux-versus-dedicated-pty-head-to-head-october-21-2026).

A ten-minute WSL test with repeated pane opening and closing passed. Mux still
remains experimental: keep dedicated mode if you prefer the default, or try mux
and compare it with your own workload. This supports mux as a practical option
for the measured WSL workload, not universal performance equivalence or broad
SSH/container qualification. Shared connections do not provide session
persistence or detach/reattach; closing the last pane shuts the connection down.
See the [development history](../../agent-mux-development.md) for earlier tests.

Wire windows remain 64 KiB per stream.
Bounded off-UI-thread read-ahead permits up to 4 MiB unread output per pane,
with a 16 MiB connection-wide logical output reservation budget; each slot keeps
a baseline window so floods cannot steal another pane's refill capacity.
Client input admission retains the dedicated backend's bounded 4 MiB queue for
large pastes; transmission still obeys the 64 KiB wire window. UI drain cadence
and connector latency may limit throughput.
See [the mux guide](../../agent-mux.md) or
[technical limits](../../agent-mux-development.md#bounds-and-scheduling).

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
