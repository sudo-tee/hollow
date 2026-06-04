# Python `hollow-cli`

A Python client that talks HTP over the active tty.
Useful for shell-built-in use cases where no host-side executable is
available (some WSL, SSH, and PowerShell flows).

For almost every script or automation use case, prefer the
[native `hollow cli …`](native.md) subcommand. Use this client only
when you cannot.

### WSL

Using this script from WSL requires the `hollow-wsl-bypass` helper
binary in the WSL environment.
Without it, you can still use the native `hollow.exe cli …`
subcommand from WSL, but with limitations: no image protocol, no
Sixel, and no Python `hollow-cli` over a redirected WSL pty.
The script is faster than calling the `hollow.exe` host command,
since it does not have to start a Windows process.

## Install

The client ships in the repo at
[`scripts/hollow-cli`](../../../scripts/hollow-cli). It is a single
Python 3 script with no third-party dependencies. Put it on your
`PATH` and you have `hollow-cli`.

## Usage

```bash
hollow-cli <command> [...]
```

## Global options

| Flag          | Effect                                              |
| ------------- | --------------------------------------------------- |
| `--pretty`    | Pretty-print JSON output                            |
| `--quiet`     | Suppress success output                             |
| `--envelope`  | Print the full reply envelope, not just the payload |
| `--transport` | `auto` (default), `file`, or `osc`                  |
| `--timeout`   | Seconds to wait for a reply (default 1.5)           |

The default `auto` transport uses the OSC-over-tty path. `file` uses
the host's request directory (used by some setups). `osc` forces OSC
even when another path is available.

## Command surface

### `get`

```bash
hollow-cli get pane [--id ID]
hollow-cli get pane-text [--id ID]
hollow-cli get current-pane
hollow-cli get tab [--id ID]
hollow-cli get current-tab
hollow-cli get tabs
hollow-cli get panes [--tag TAG]
hollow-cli get workspace [--id ID|--index N]
hollow-cli get current-workspace
hollow-cli get workspaces
hollow-cli get domain
hollow-cli get htp <channel> [params-json]
```

### `workspace`

```bash
hollow-cli workspace new [--cwd PATH] [--domain NAME] [--cmd CMD] [--name NAME]
hollow-cli workspace close [--id ID|--index N]
hollow-cli workspace next
hollow-cli workspace prev
hollow-cli workspace select <index>
hollow-cli workspace rename <name> [--id ID|--index N]
```

### `tab`

```bash
hollow-cli tab new [--cmd CMD] [--domain NAME]
hollow-cli tab close [--id ID|--index N]
hollow-cli tab next
hollow-cli tab prev
hollow-cli tab select <index>
hollow-cli tab rename <name> [--id ID|--index N]
```

### `pane`

```bash
hollow-cli pane split vertical|horizontal [--cmd CMD] [--cwd PATH] [--domain NAME] [--ratio N]
hollow-cli pane popup <cmd> [--cwd PATH] [--domain NAME] [--x N] [--y N] [--width N] [--height N]
hollow-cli pane close [--id ID|--tag TAG]
hollow-cli pane zoom [--id ID|--tag TAG]
hollow-cli pane float [--id ID|--tag TAG]
hollow-cli pane tile [--id ID|--tag TAG]
hollow-cli pane move <left|right|up|down> [--id ID|--tag TAG] [--amount N]
hollow-cli pane resize <left|right|up|down> [--id ID|--tag TAG] [--amount N]
hollow-cli pane send-text <text> [--id ID|--tag TAG]
hollow-cli pane set-tag <tag> [--id ID|--tag TAG]
hollow-cli pane remove-tag <tag> [--id ID|--tag TAG]
hollow-cli pane set-tags [tag ...] [--id ID|--tag TAG]
```

### Other

```bash
hollow-cli focus <left|right|up|down>
hollow-cli scroll <top|bottom|page-up|page-down>
hollow-cli config reload
hollow-cli config theme <name>
hollow-cli run <cmd> [--domain NAME]
hollow-cli send-keys <keys> [--id ID|--tag TAG]
hollow-cli emit <channel> [payload-json]
```

## Examples

```bash
hollow-cli get current-pane
hollow-cli get workspaces
hollow-cli workspace new --cwd /repo --name repo
hollow-cli tab rename editor --index 1
hollow-cli pane split vertical --cmd "npm run dev"
hollow-cli send-keys "{Up}{Enter}"
hollow-cli focus left
hollow-cli scroll page-down
hollow-cli config reload
hollow-cli get htp echo '{"value":42}'
hollow-cli emit notify '{"text":"done"}'
```

## How it differs from `hollow cli …`

|                                 | `hollow-cli`              | `hollow cli …`          |
| ------------------------------- | ------------------------- | ----------------------- |
| Transport                       | OSC over tty              | host command socket     |
| Needs a tty                     | yes                       | no                      |
| Needs shell integration sourced | yes                       | no                      |
| Briefly owns terminal I/O       | yes                       | no                      |
| Best for                        | prompt hooks, in-shell UI | scripts, CI, automation |

## See also

- [CLI index](README.md)
- [Native `hollow cli …`](native.md)
- [Shell integration](../../shell-integration.md) — overview
- [Shell integration recipes](../../shell-integration-recipes.md) — bash/zsh/fish/PowerShell helpers
- [HTP protocol](../../htp-protocol.md) — wire format
