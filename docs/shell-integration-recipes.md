# Shell integration recipes

Small, complete HTP recipes for each supported shell.
For the higher-level overview see
[Shell integration](shell-integration.md); for the wire format see
[HTP protocol](htp-protocol.md).

## What ships

- `shell-integration/bash.sh`
- `shell-integration/zsh.zsh`
- `shell-integration/fish.fish`
- `shell-integration/powershell.ps1`

The Python OSC transport client is at
`scripts/hollow-cli`. See
[Python `hollow-cli`](reference/cli/hollow-cli.md).

## bash

Source from `.bashrc`:

```bash
source /path/to/hollow/shell-integration/bash.sh
```

The snippet installs prompt hooks that emit `cwd_changed` and
`command_started` / `command_ended`.
It does not implement OSC reply capture; for queries and ad hoc
emits, call [`hollow-cli`](reference/cli/hollow-cli.md) directly:

```bash
hollow-cli get current-pane
hollow-cli emit split_pane '{"floating":true}'
```

## zsh

Source from `.zshrc`:

```zsh
source /path/to/hollow/shell-integration/zsh.zsh
```

For queries and ad hoc emits, call `hollow-cli` directly:

```zsh
hollow-cli get current-workspace
hollow-cli emit new_workspace '{"cwd":"/repo","name":"repo"}'
```

## fish

Source from `config.fish`:

```fish
source /path/to/hollow/shell-integration/fish.fish
```

For queries and ad hoc emits, call `hollow-cli` directly:

```fish
hollow-cli get current-tab
hollow-cli emit close_pane '{}'
```

## PowerShell

Hollow auto-dot-sources `shell-integration/powershell.ps1` when launching
the `pwsh` or `powershell` domain — no manual setup required. The snippet
reports cwd via OSC 7 and updates the window title via OSC 0 on every
prompt.

For queries and ad hoc emits, call
[`hollow-cli`](reference/cli/hollow-cli.md) directly:

```powershell
hollow-cli get current-pane
hollow-cli pane split vertical --cmd "npm run dev"
hollow-cli emit notify '{"text":"done"}'
```

`hollow-cli` is a Python 3 script with no third-party dependencies.
It writes to the active tty, so it works from any PowerShell host
that has access to the console.

## OSC over tty vs. host socket

| | OSC (`hollow-cli`) | `hollow cli …` |
| --- | --- | --- |
| Needs a tty | yes | no |
| Needs shell integration sourced | no | no |
| Brief tty ownership during the call | yes | no |
| Works over SSH from another host | no | no |
| Best for | prompt hooks, in-shell UI | scripts, CI, automation |

The two are not mutually exclusive. Use the shipped
`shell-integration/` snippets for ambient metadata and the native
CLI for explicit mutations.

## See also

- [Shell integration](shell-integration.md) — overview and decision guide
- [HTP protocol](htp-protocol.md) — wire format and channel list
- [Native CLI](reference/cli/native.md) — host-side path
- [Python `hollow-cli`](reference/cli/hollow-cli.md) — OSC transport client
- [`hollow.htp`](reference/lua/htp.md) — register custom channels
