# Documentation

The is the main entry point for Hollow's documentation.

| Section                        | What lives there                 | Start with                                     |
| ------------------------------ | -------------------------------- | ---------------------------------------------- |
| [Overview](getting-started.md) | Install, first run, mental model | [Getting started](getting-started.md)          |
| [Guides](#guides)              | Concept-focused how-tos          | [Configuration](configuration.md)              |
| [Platforms](#platforms)        | Per-OS notes and troubleshooting | [Windows + WSL](platforms/windows.md)          |
| [Reference](#reference)        | API and command surface          | [Lua API](reference/lua/README.md)             |
| [Examples](./examples/README.md) | Runnable recipes and snippets    | [Config snippets](examples/config-snippets.md) |

## Guides

- [Getting started](getting-started.md) — install, first run, mental model
- [Configuration](configuration.md) — config model, defaults, overrides
- [Keybindings](keybindings.md) — default keymaps, modal bindings, the leader key
- [Panes, tabs, workspaces](panes-tabs-workspaces.md) — the three layout primitives
- [Themes](themes.md) — built-in themes, custom themes, palette overrides
- [Custom UI](custom-ui.md) — top bar, sidebars, overlays, and the widget runtime
- [Copy mode](copy-mode.md) — vim-like scrollback navigation and search
- [Plugins](plugins.md) — installing, authoring, and updating plugins
- [Shell integration](shell-integration.md) — what HTP does and how to enable it
- [HTP protocol](htp-protocol.md) — wire-level protocol reference
- [Shell integration recipes](shell-integration-recipes.md) — bash, zsh, fish, PowerShell helpers
- [Development](development.md) — build from source, project layout, running tests
- [Packaging](packaging.md) — release artifacts, runtime layout, WSL bypass, Python client
- [Troubleshooting](troubleshooting.md) — common failure modes and fixes
- [FAQ](faq.md) — short, opinionated answers to recurring questions

## Platforms

Per-OS notes for the targets Hollow actually supports or works on today.

- [Platform matrix](platforms/README.md)
- [Windows](platforms/windows.md)
- [WSL](platforms/wsl.md)
- [Linux](platforms/linux.md)
- [macOS](platforms/macos.md)

## Reference

- [Reference index](reference/README.md)
- **Lua API** — split per namespace under [`reference/lua/`](reference/lua/README.md)
  - [Overview and conventions](reference/lua/overview.md)
  - [`hollow.config`](reference/lua/config.md)
  - [`hollow.term`](reference/lua/term.md)
  - [`hollow.events`](reference/lua/events.md)
  - [`hollow.keymap`](reference/lua/keymap.md)
  - [`hollow.ui`](reference/lua/ui.md)
  - [`hollow.ui.workspace`](reference/lua/workspace.md)
  - [`hollow.theme`](reference/lua/theme.md)
  - [`hollow.htp`](reference/lua/htp.md)
  - [`hollow.fonts`](reference/lua/fonts.md)
  - [`hollow.json`](reference/lua/json.md)
  - [`hollow.workspace`](reference/lua/workspace-api.md)
  - [`hollow.async`](reference/lua/async.md)
  - [`hollow.process`](reference/lua/process.md)
  - [`hollow.fs`](reference/lua/fs.md)
  - [`hollow.plugins`](reference/lua/plugins.md)
  - [`hollow.util`](reference/lua/util.md)
  - [`hollow.platform`](reference/lua/platform.md)
- **CLI**
  - [CLI index](reference/cli/README.md)
  - [Native `hollow cli …`](reference/cli/native.md)
  - [Python `hollow-cli`](reference/cli/hollow-cli.md)
- [Built-in keymap actions](reference/actions.md)

## Examples

Runnable recipes and small, complete snippets.

- [Config snippets](examples/config-snippets.md)
- [UI recipes](examples/ui-recipes.md)
- [Plugin authoring](examples/plugin-authoring.md)
