# Hollow

<div align="center">

![Zig](https://img.shields.io/badge/Zig-%23F7A41D.svg?&style=for-the-badge&logo=zig&logoColor=black)
[![GitHub stars](https://img.shields.io/github/stars/sudo-tee/hollow?style=for-the-badge)](https://github.com/sudo-tee/hollow/stargazers)
![Last Commit](https://img.shields.io/github/last-commit/sudo-tee/hollow?style=for-the-badge)

<a href="https://www.buymeacoffee.com/sudo.tee"><img src="https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png" height="20px"></a>

</div>

<div align="center">
    <img src="assets/banner.png" alt="Hollow demo" width="200"/>
</div>

<div align="center">
    <img src="assets/hollow.png" alt="Hollow demo" width="400"/>
    <img src="assets/hollow2.png" alt="Hollow demo" width="400"/>
</div>

## What Hollow Is

A Zig terminal emulator with a LuaJIT runtime and Ghostty's VT core. Fully
configurable via Lua — inspired by the Lua APIs from
[WezTerm](https://wezfurlong.org/wezterm/) and Neovim — with a plugin system for
custom panes, overlays, and widgets.

A personal side project — built for around my personal workflow, but completely customizable for anyone else.

If you are new to the repo, start with [the docs index](docs/README.md).

## Features

- Zig + LuaJIT runtime with a full Lua API (`hollow.config`, `hollow.term`,
  `hollow.events`, `hollow.keymap`, `hollow.ui`, `hollow.htp`, and more)
- Ghostty's VT core for fast, accurate terminal emulation
- Tabs, split panes, floating panes, maximized panes, workspaces, customizable top bar
- Keyboard quick select for visible URLs and OSC 8 hyperlinks
- Scrollback, selection, clipboard, hyperlink handling, font discovery, ligature, nerd fonts and emoji support
- Basic support for Kitty images and Sixel
- Windows domains for `pwsh`, `powershell`, `cmd`, and `wsl`
- Optional WSL PTY bypass helper with automatic ConPTY fallback (needed for full escape sequence support)
- Cross-platform targets: Windows and WSL (primary); Linux/X11 (basic support); macOS (planned)
- Plugin system with Lua API for custom panes, overlays, and widgets (`hollow.plugins`)
- Sensible default UX but fully customizable via Lua config and plugins

## Quick Start

**Download a release:** [github.com/sudo-tee/hollow/releases](https://github.com/sudo-tee/hollow/releases)
Windows builds include the optional `hollow-wsl-bypass` helper for WSL domains
(falls back to ConPTY automatically when the helper is absent). Linux builds
require an X11 session or XWayland; see [Linux](docs/platforms/linux.md).

**Customize:** copy `conf/init.lua` to `%APPDATA%\hollow\init.lua` (Windows) or
`~/.config/hollow/init.lua` (other).

**Build from source:**

**Zig version:** `0.15.2` only. If you use `asdf` or `mise`, run
`asdf install` or `mise install` from the repo root — `.tool-versions` is
already pinned.

```
./scripts/setup.sh        # first-time submodule init
./launch.sh               # Windows cross-build + run
zig build run             # non-Windows build + run
```

Full build docs in [Development](docs/development.md).

## Documentation

The full guide set lives in [`docs/`](docs/README.md):

| Section   | Start here                                                                                                                                                                     |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Guides    | [Getting started](docs/getting-started.md), [Configuration](docs/configuration.md), [Keybindings](docs/keybindings.md), [Panes/tabs/workspaces](docs/panes-tabs-workspaces.md) |
| Platforms | [Windows](docs/platforms/windows.md), [WSL](docs/platforms/wsl.md), [Linux](docs/platforms/linux.md), [macOS](docs/platforms/macos.md)                                         |
| Reference | [Lua API](docs/reference/lua/README.md), [CLI](docs/reference/cli/native.md), [Keymap actions](docs/reference/actions.md)                                                      |
| Examples  | [Config snippets](docs/examples/config-snippets.md), [UI recipes](docs/examples/ui-recipes.md), [Plugin authoring](docs/examples/plugin-authoring.md)                          |

Companion files: [`conf/init.lua`](conf/init.lua) (default config),
[`types/hollow.lua`](types/hollow.lua) (LuaLS typings).

## Default Keymaps

All keymaps are defined in [`conf/init.lua`](conf/init.lua). The leader key is
`<C-Space>` (1200ms timeout). See the file for the full bindings or override
them in your user config via `hollow.keymap.set`.

## Project Status

- Hollow is still an active project and the API surface is still moving.
- The docs in this repo are meant to describe the current product, not a future roadmap.
- Windows/WSL remain main tested targets. Linux/X11 has basic runtime support
  and release artifacts, with compositor-dependent window chrome behavior.

## Roadmap
