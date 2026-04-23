# Hollow

<div align="center">
    <img src="assets/banner.png" alt="Hollow demo" width="600"/>
</div>

## What Hollow Is

Hollow is a Zig terminal emulator with a LuaJIT runtime and Ghostty's VT core.
The current build is usable today, highly configurable through Lua, and
validated primarily on Windows and WSL.

I see it as a spiritual successor to WezTerm. WezTerm is a fantastic terminal emulator, but Wezterm development has slowed down and the project is not as active as it once was. Hollow is an attempt to create a new terminal emulator that builds on the strengths of WezTerm while also providing a more modern and flexible architecture.

If you are new to the repo, start with [the docs index](docs/README.md). The
root README is the product overview; the rest of `docs/` is the actual guide
set.

## Table Of Contents

- [What Hollow Is](#what-hollow-is)
- [Getting Started](#getting-started)
- [Documentation Map](#documentation-map)
- [What Ships Today](#what-ships-today)
- [Default Keymaps](#default-keymaps)
- [Project Status](#project-status)
- [Project Docs](docs/README.md)

## Why "Hollow"?

The name "Hollow" is meant to evoke the idea of a container or vessel that can be filled with different contents. In this case, the "hollow" is the terminal emulator itself, which can be customized and extended with different configurations, scripts, and plugins to suit the user's needs. The name also has a certain simplicity and elegance to it, which reflects the design philosophy of the project.

## Getting Started

### Download a release

The latest release is available on GitHub: [Releases](https://github.com/sudo-tee/hollow/releases)

### Customize the config

Copy the default config `conf/init.lua` to the user config location:

- Windows: `%APPDATA%\hollow\init.lua`
- Non-Windows: `$XDG_CONFIG_HOME/hollow/init.lua` or `$HOME/.

Refer to [the configuration docs](docs/configuration.md) for details on the config model, defaults and overrides

### Development builds

#### Build from source (Windows/WSL)

First-time setup:

```bash
./scripts/setup.sh
```

Build and run:

```bash
./launch.sh
```

Build only:

```bash
./launch.sh --build-only
```

Debug build:

```bash
./launch.sh --debug
```

#### Build from source (other platforms)

First-time setup:

```bash
./scripts/setup.sh
```

Build and run:

```bash
zig build run
## Or build a release binary:
zig build -Doptimize=ReleaseFast
```

## Documentation Map

Start with [the docs index](docs/README.md).

| File                                                     | Purpose                                         | Read this when                                              |
| -------------------------------------------------------- | ----------------------------------------------- | ----------------------------------------------------------- |
| [docs/README.md](docs/README.md)                         | Documentation hub and structure                 | you want the full map of guides and references              |
| [docs/configuration.md](docs/configuration.md)           | Config model, defaults, overrides, packaging    | you want to customize Hollow or ship a default config       |
| [docs/windows-wsl.md](docs/windows-wsl.md)               | Windows-first setup, WSL usage, troubleshooting | you are running Hollow in its primary validated environment |
| [docs/hollow-lua-api.md](docs/hollow-lua-api.md)         | Lua runtime API reference                       | you are scripting Hollow or building custom UI/automation   |
| [docs/htp-shell-examples.md](docs/htp-shell-examples.md) | Shell-side HTP helpers and examples             | you want shells or scripts to talk back to the host         |

Companion reference files outside `docs/`:

- `conf/init.lua`: the shipped default configuration
- `types/hollow.lua`: LuaLS typings for the runtime API

## What Ships Today

- tabs, split panes, floating panes, maximized panes, and workspaces
- scrollback, selection, clipboard, and hyperlink handling
- a shipped top bar with workspace, tabs, cwd, key legend, and time
- a Lua API centered on `hollow.config`, `hollow.term`, `hollow.events`, `hollow.keymap`, `hollow.ui`, and `hollow.htp`
- CLI and Lua font discovery helpers
- Windows domains for `pwsh`, `powershell`, `cmd`, and `wsl`
- a bundled config that users can extend from `%APPDATA%\hollow\init.lua` on Windows or `$XDG_CONFIG_HOME/hollow/init.lua` / `$HOME/.config/hollow/init.lua` on non-Windows hosts

The shipped Windows default domain is currently `pwsh`. `wsl` is available and
documented because it is an important workflow, but it is not the default in the
current bundled config.

## Default Keymaps

The default keymaps are defined in `conf/init.lua`. The bundled leader key is
`<C-Space>` (timeout 1200ms). Below are the default bindings included in the
shipped config (key → action):

- `<C-S-c>`: `copy_selection`
- `<C-S-v>`: `paste_clipboard`
- `<S-Insert>`: `paste_clipboard`
- `<C-\>`: `split_vertical`
- `<C-S-\>`: `split_horizontal`
- `<C-t>`: `new_tab`
- `<C-w>`: `close_tab`
- `<C-S-w>`: `close_pane`
- `<C-Tab>`: `next_tab`
- `<C-S-Tab>`: `prev_tab`
- `<C-A-n>`: `new_workspace`
- `<C-A-p>`: `workspace_switcher`
- `<C-A-r>`: `rename_workspace`
- `<C-A-w>`: `close_workspace`
- `<C-A-Right>`: `next_workspace`
- `<C-A-Left>`: `prev_workspace`
- `<C-S-Left>`: `focus_pane_left`
- `<C-S-Right>`: `focus_pane_right`
- `<C-S-Up>`: `focus_pane_up`
- `<C-S-Down>`: `focus_pane_down`
- `<C-S-m>`: `maximize_pane`
- `<C-S-f>`: `float_pane`
- `<C-A-S-f>`: `tile_pane`
- `<C-A-h>`: `move_pane_left`
- `<C-A-l>`: `move_pane_right`
- `<C-A-k>`: `move_pane_up`
- `<C-A-j>`: `move_pane_down`
- `<C-A-S-Left>`: `resize_pane_left`
- `<C-A-S-Right>`: `resize_pane_right`
- `<C-A-Up>`: `resize_pane_up`
- `<C-A-Down>`: `resize_pane_down`
- `<A-S-PageUp>`: `scrollback_page_up`
- `<A-S-PageDown>`: `scrollback_page_down`
- `<C-S-Home>`: `scrollback_top`
- `<C-S-End>`: `scrollback_bottom`
- `<leader>r`: rename current tab (bound to a small rename prompt; desc: "rename tab")
- `<leader>uu`: reload the config (desc: "reload config")

You can override any of these in your user config by calling `hollow.keymap.set`
or `hollow.keymap.set_leader` in `$XDG_CONFIG_HOME/hollow/init.lua` or
`%APPDATA%\\hollow\\init.lua`.

## Project Status

- Hollow is still an active project and the API surface is still moving.
- The docs in this repo are meant to describe the current product, not a future roadmap.
- The current build is suitable for building, running, configuring, and packaging now, with Windows/WSL as the main tested target.
- If you are planning a docs site, treat [docs/README.md](docs/README.md) as the navigation root.
