# Lua API

The runtime exposes a single Lua global: `hollow`.
This directory is the canonical reference for everything reachable from
`hollow.*` and from the small set of top-level helpers.

Start with [Overview and conventions](overview.md), then jump to the
namespace you need. The full type schema lives in
[`types/hollow.lua`](../../../types/hollow.lua).

## Top-level helpers

| Symbol | Doc | What it does |
| --- | --- | --- |
| `require("hollow")` | [overview.md](overview.md) | The single global |
| `hollow.log(...)` | [overview.md](overview.md#log-and-inspect) | Print to the host log |
| `hollow.inspect(value)` | [overview.md](overview.md#log-and-inspect) | Pretty-print a value |
| `hollow.read_dir(path)` | [overview.md](overview.md#filesystem-helpers) | List directory entries |
| `hollow.strftime(fmt)` | [overview.md](overview.md#date-and-time) | Format a timestamp |
| `hollow.schedule(fn)` | [overview.md](overview.md#scheduling) | Run a function on the next frame |
| `hollow.defer(fn, timeout_ms?)` | [overview.md](overview.md#scheduling) | Same, with optional delay |
| `hollow.on_gui_ready(handler)` | [overview.md](overview.md#scheduling) | Run after the GUI is up |

## Namespaces

| Namespace | Doc |
| --- | --- |
| `hollow.config` | [config.md](config.md) |
| `hollow.term` | [term.md](term.md) |
| `hollow.events` | [events.md](events.md) |
| `hollow.keymap` | [keymap.md](keymap.md) |
| `hollow.ui` | [ui.md](ui.md) |
| `hollow.ui.workspace` | [workspace.md](workspace.md) |
| `hollow.theme` | [theme.md](theme.md) |
| `hollow.htp` | [htp.md](htp.md) |
| `hollow.fonts` | [fonts.md](fonts.md) |
| `hollow.json` | [json.md](json.md) |
| `hollow.workspace` | [workspace-api.md](workspace-api.md) |
| `hollow.async` | [async.md](async.md) |
| `hollow.process` | [process.md](process.md) |
| `hollow.fs` | [fs.md](fs.md) |
| `hollow.plugins` | [plugins.md](plugins.md) |
| `hollow.util` | [util.md](util.md) |
| `hollow.platform` | [platform.md](platform.md) |

## See also

- [Built-in keymap actions](../actions.md) — string action names
- [Native CLI](../cli/native.md) — host-side automation
- [HTP protocol](../../htp-protocol.md) — wire format
