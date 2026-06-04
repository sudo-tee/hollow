# Reference

The reference section is the canonical source for the Hollow public
surface. Everything here mirrors behavior in the runtime; when the docs
and the code disagree, the code wins.

## Lua API

Split per namespace under [`reference/lua/`](lua/README.md).
Start with [Overview and conventions](lua/overview.md).

| Namespace | Doc | What it does |
| --- | --- | --- |
| `hollow.config` | [config.md](lua/config.md) | Read and write configuration |
| `hollow.term` | [term.md](lua/term.md) | Tabs, panes, workspaces, text, process |
| `hollow.events` | [events.md](lua/events.md) | Subscribe to host events |
| `hollow.keymap` | [keymap.md](lua/keymap.md) | Bind keys to actions or callbacks |
| `hollow.ui` | [ui.md](lua/ui.md) | Widgets, top bar, sidebars, overlays |
| `hollow.ui.workspace` | [workspace.md](lua/workspace.md) | Workspace switcher and discovery |
| `hollow.theme` | [theme.md](lua/theme.md) | Theme resolution and palette |
| `hollow.htp` | [htp.md](lua/htp.md) | Register custom HTP channels |
| `hollow.fonts` | [fonts.md](lua/fonts.md) | Font discovery helpers |
| `hollow.json` | [json.md](lua/json.md) | JSON encode / decode |
| `hollow.workspace` | [workspace-api.md](lua/workspace-api.md) | Workspace bootstrap specs |
| `hollow.async` | [async.md](lua/async.md) | Coroutines and promises |
| `hollow.process` | [process.md](lua/process.md) | Run child processes |
| `hollow.fs` | [fs.md](lua/fs.md) | Filesystem helpers |
| `hollow.plugins` | [plugins.md](lua/plugins.md) | Plugin loader and sync |
| `hollow.util` | [util.md](lua/util.md) | Path, color, table utilities |
| `hollow.platform` | [platform.md](lua/platform.md) | Read-only platform info |

## CLI

Two CLI surfaces ship today. See the [CLI index](cli/README.md).

- [Native `hollow cli …`](cli/native.md) — talks to the host's command socket
- [Python `hollow-cli`](cli/hollow-cli.md) — OSC-over-tty HTP client

## Actions

- [Built-in keymap actions](actions.md) — every string action name you
  can pass to `hollow.keymap.set(chord, "name", ...)`

## Source of truth

The LuaLS typings under [`types/hollow.lua`](../../types/hollow.lua)
are the canonical schema for the Lua API; the per-namespace pages
mirror them.
