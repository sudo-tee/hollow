# CLI

Two CLI surfaces ship with Hollow. They are not redundant — each one
fits a different use case.

| Tool | Talks to | Needs tty | Best for |
| --- | --- | --- | --- |
| [`hollow cli …`](native.md) | host command socket | no | scripts, CI, automation |
| [`hollow-cli`](hollow-cli.md) | OSC over tty | yes | prompt hooks, in-shell UI |

Both are documented individually:

- [Native `hollow cli …`](native.md) — the recommended path
- [Python `hollow-cli`](hollow-cli.md) — OSC transport client

The native subcommand wins on every axis that matters for scripts:
it does not need a tty, it does not need shell integration sourced,
and it is the fastest option when a Hollow window is already
running. Use it for any host-side automation.

The Python client exists for shell-built-in use cases that have no
host-side executable available (some WSL, SSH, and PowerShell flows).
See [Shell integration](../../shell-integration.md) for the higher-level
overview and [HTP protocol](../../htp-protocol.md) for the wire format.

## Choosing between them

| Scenario | Use |
| --- | --- |
| A Python or PowerShell script in CI | `hollow cli …` |
| A bash script running inside Hollow | `hollow-cli` (OSC) or `hollow cli` |
| A prompt hook that reports cwd | `hollow-cli` (or the shipped `shell-integration/` snippets) |
| A Lua plugin that drives Hollow | the [`hollow.term`](../lua/term.md) API directly |
| An automated test that talks to Hollow | `hollow cli …` |
| SSH from a remote box into the host | neither — neither is reachable |

## See also

- [Shell integration](../../shell-integration.md) — overview
- [HTP protocol](../../htp-protocol.md) — wire format
- [`hollow.htp`](../lua/htp.md) — register custom channels
