# CLI

Hollow has one Zig CLI implementation with two entry points:

| Entry point | Implementation | Best for |
| --- | --- | --- |
| [`hollow cli …`](native.md) | Shared Zig CLI inside Hollow | Host-side scripts and automation |
| [`hollow-cli …`](standalone.md) | Same CLI in a standalone binary | WSL, SSH, containers, shell hooks |

Both share friendly command syntax, generic API calls, validation, targeting,
key decoding, and JSON output. Socket and file transports do not need a tty;
OSC requires a readable POSIX terminal. Both default to `--transport auto`.

- [Command reference](native.md)
- [Standalone CLI, transports, and guest packaging](standalone.md)
- [Legacy Python client](hollow-cli.md) — retained for older hosts and compatibility

Guest agents embed an architecture-matched Zig CLI in their shell-integration
bundle; no Python or GUI dependencies are needed on the guest.

## Choosing between them

| Scenario | Use |
| --- | --- |
| A Python or PowerShell script in CI | `hollow cli …` |
| A bash script running inside Hollow | `hollow-cli` or `hollow cli` |
| A prompt hook that reports cwd | `hollow-cli` (or the shipped `shell-integration/` snippets) |
| A Lua plugin that drives Hollow | the [`hollow.term`](../lua/term.md) API directly |
| An automated test that talks to Hollow | `hollow cli …` |
| A remote SSH shell running inside Hollow | `hollow-cli` via OSC, or a forwarded command socket |

## See also

- [Shell integration](../../shell-integration.md) — overview
- [HTP protocol](../../htp-protocol.md) — wire format
- [`hollow.htp`](../lua/htp.md) — register custom channels
