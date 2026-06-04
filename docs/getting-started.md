# Getting started

Hollow is a terminal emulator for Windows with a Lua-configurable runtime
and Ghostty's VT core.
This page gets you from zero to a running window with your own overrides.

## What ships today

- A Windows-native terminal with tabs, split panes, floating panes, maximized panes, and workspaces
- A Lua configuration layer; reload the config without restarting
- A Lua API for UI, events, keymaps, and shell-to-host integration
- A native `hollow cli …` subcommand for host-side automation
- An optional WSL PTY bypass helper that skips ConPTY for WSL shells

The primary validated target is Windows.
WSL is a first-class shell domain.
Linux and macOS are not part of the supported matrix yet; see
[Platforms](platforms/README.md).

## Install a release

The latest release is on GitHub: [Releases](https://github.com/sudo-tee/hollow/releases).

A Windows release contains three executables that belong next to each other:

| File | Role |
| --- | --- |
| `hollow.exe` | CLI launcher and `hollow cli …` host |
| `hollow-gui.exe` | Console-less GUI shim |
| `hollow-native.exe` | Actual GUI process |
| `hollow-cli` | Python HTP client (optional, OSC over tty) |
| `wsl/hollow-wsl-bypass` | Linux-side WSL helper (optional) |

Debug symbols (`.pdb` files) are not bundled in releases.
For crash symbolication, see
[Packaging → Crash reports](packaging.md#crash-reports).

If you want the WSL PTY bypass, also install `hollow-wsl-bypass` inside your
WSL distro. See [WSL → Bypass helper](platforms/wsl.md#bypass-helper).

## Write a personal config

Hollow resolves one base config and one override config.
The base config is the shipped default in `conf/init.lua`.
Your override is what you actually own; it merges on top of the base.

Default override locations:

- Windows: `%APPDATA%\hollow\init.lua`
- Non-Windows hosts: `$XDG_CONFIG_HOME/hollow/init.lua` or
  `$HOME/.config/hollow/init.lua`

You can also pass `--config path/to/init.lua` on the command line, which takes
precedence over the default path.

Minimal override:

```lua
local hollow = require("hollow")

hollow.config.set({
  fonts = { size = 16, family = "Cascadia Mono" },
  scrollback = 128_000_000,
  window_titlebar_show = false,
})
```

Reload with `<leader>uu` (the default config binds that to
`hollow.config.reload()` and shows a toast).

See [Configuration](configuration.md) for the full model.

## Mental model

Hollow exposes a single Lua global: `hollow`.
The shipped namespaces are:

| Namespace | Purpose |
| --- | --- |
| `hollow.config` | Read and write configuration |
| `hollow.term` | Tabs, panes, workspaces, text and process helpers |
| `hollow.events` | Subscribe to host events |
| `hollow.keymap` | Bind keys to actions or Lua callbacks |
| `hollow.ui` | Top bar, sidebars, overlays, widgets |
| `hollow.htp` | Register shell-to-host query and emit channels |
| `hollow.fonts`, `hollow.json` | Font and JSON helpers |
| `hollow.workspace`, `hollow.async` | Workspace bootstrap and async |
| `hollow.process`, `hollow.fs` | Process spawning and filesystem |
| `hollow.theme`, `hollow.util`, `hollow.platform` | Theme, utility, and platform |
| `hollow.plugins` | Plugin loader |
| _All of the above_ | See [Reference](reference/lua/README.md) for full API |

Snapshots returned from `hollow.term` (tabs, panes, workspaces) are
read-only — treat them as values, not live references.

## Build from source

The repo builds with Zig `0.15.2` (pinned via `.tool-versions`).
The full toolchain walkthrough lives in [Development](development.md);
the short version:

```bash
./scripts/setup.sh   # one-time
./launch.sh          # build and run on Windows from WSL
```

`launch.sh` cross-builds `x86_64-windows-gnu` and copies the executables to
the repo root before running `hollow.exe`.

## Next steps

- [Configuration](configuration.md) — what knobs exist, which ones to touch first
- [Keybindings](keybindings.md) — the default keymap and how to override it
- [Panes, tabs, workspaces](panes-tabs-workspaces.md) — the layout primitives
- [Shell integration](shell-integration.md) — make shells report cwd, process, and exit status
