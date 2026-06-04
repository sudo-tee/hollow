# Shell integration

Hollow ships a small, OSC-based protocol called **HTP** (Hollow Terminal
Protocol) that shells use to report metadata back to the host.
HTP is what makes `pane.cwd` track your shell's actual directory, surfaces
the foreground process in the top bar, and lets you write scripts that
drive Hollow from inside a pane.

The shipped way to use HTP from scripts is the
[native `hollow cli …` subcommand](reference/cli/native.md).
The shipped `shell-integration/` snippets cover prompt hooks
(`cwd_changed`, `command_started`, `command_ended`) and the
[Python `hollow-cli`](reference/cli/hollow-cli.md) client covers the
OSC transport for queries and ad hoc emits.

For the wire-level protocol see [HTP protocol](htp-protocol.md).
For per-shell recipes see
[Shell integration recipes](shell-integration-recipes.md).
For the Lua handler API see [`hollow.htp`](reference/lua/htp.md).

## What HTP enables

When a shell reports through HTP, the host can:

- Track the actual cwd of every pane and update the top bar / tab title
- Show the running foreground process
- Trigger UI updates from inside a shell (e.g. open a picker)
- Drive Hollow from shell scripts (split panes, switch tabs, etc.)

HTP runs over the same tty the shell uses.
The framing uses OSC 1337 with a `Hollow;` prefix and chunked base64
framing for payloads larger than roughly 1 KB.

## Environment variables

Hollow injects two env vars into every guest session:

| Variable | Meaning |
| --- | --- |
| `HOLLOW_PANE_ID` | Stable id of the current pane; pass to host-side tooling |
| `HOLLOW_TRANSPORT` | The active transport (`osc` is the OSC-over-tty path) |

For WSL domains, Hollow also configures `WSLENV` so these variables
cross the Windows/WSL boundary with `/u` (UTF-8 propagation).

## Two ways to call the host

### 1. The native CLI

```bash
hollow cli get current-pane
hollow cli workspace new --cwd /repo --name repo
hollow cli pane split vertical --cmd "npm run dev"
hollow cli emit custom_channel '{"value":42}'
```

`hollow cli …` talks directly to the running Hollow host's command
socket, so it does not need a tty and does not need any shell
integration installed. This is the path most scripts and CI should use.

See [Native CLI](reference/cli/native.md) for the full command surface.

### 2. OSC from the shell

For shell-built-in use cases (a prompt hook that reports cwd, a
chained command that opens a picker) use the OSC transport via
[`hollow-cli`](reference/cli/hollow-cli.md):

```bash
hollow-cli emit cwd_changed '{"cwd":"/home/me/repo"}'
hollow-cli emit split_pane '{"floating":true}'
hollow-cli get current-pane
```

The OSC path uses `/dev/tty` and briefly owns terminal I/O while it
waits for the host reply. It works over SSH and inside WSL when the
host-side CLI is not available.

See [Shell integration recipes](shell-integration-recipes.md).

## What ships

The runtime includes built-in HTP query channels:

`pane`, `current_pane`, `tab`, `current_tab`, `tabs`, `panes`,
`workspace`, `workspaces`, `current_workspace`, `current_domain`,
`echo`.

And built-in HTP emit channels:

`close_pane`, `focus_pane`, `resize_pane`, `send_text`, `split_pane`,
`new_tab`, `close_tab`, `focus_tab`, `next_tab`, `prev_tab`,
`set_tab_title`, `new_workspace`, `close_workspace`, `next_workspace`,
`prev_workspace`, `switch_workspace`, `set_workspace_name`,
`toggle_pane_maximized`, `set_pane_floating`, `set_floating_pane_bounds`,
`move_pane`, `reload_config`, `set_theme`, `scroll`.

You can register your own channels from Lua with
`hollow.htp.on_query(channel, handler)` and
`hollow.htp.on_emit(channel, handler)`.

## Built-in shell integration scripts

Hollow ships snippets for the major shells under
[`shell-integration/`](../shell-integration):

- `bash.sh`
- `zsh.zsh`
- `fish.fish`

Source the right one from your shell rc file. The snippets install
prompt hooks that emit `cwd_changed` and `command_started` /
`command_ended`. For queries and ad hoc emits, call
[`hollow-cli`](reference/cli/hollow-cli.md).

## Choosing between OSC and the native CLI

| | Native CLI | OSC (`hollow-cli`) |
| --- | --- | --- |
| Needs a running Hollow window | yes | yes |
| Needs shell integration sourced | no | no |
| Needs a tty | no | yes |
| Works over SSH from another box | no | no |
| Works inside WSL from a Windows Hollow | yes | yes |
| Best for | scripts, CI, automation | prompt hooks, in-shell UI |

The two are not mutually exclusive. Use prompt hooks for ambient
metadata (cwd, foreground process) and the native CLI for explicit
mutations (split, focus, send text).

## See also

- [HTP protocol](htp-protocol.md) — frame layout, OSC sequences, request correlation
- [Shell integration recipes](shell-integration-recipes.md) — bash, zsh, fish, PowerShell
- [Native CLI](reference/cli/native.md) — the recommended host-side path
- [`hollow.htp`](reference/lua/htp.md) — register custom channels
