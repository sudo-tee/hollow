# Native `hollow cli …`

The native CLI subcommand talks directly to the running Hollow host's
command socket. It does not need a tty, does not need shell
integration sourced, and is the fastest option when a Hollow window
is already running.

## Running it

```bash
hollow.exe cli <command> [...]
hollow.exe cli --help
```

`hollow.exe cli …` is the same launcher as the GUI; the `cli` token
is intercepted by `src/main.zig:guiMain` before the GUI is started.

## Global options

| Flag | Effect |
| --- | --- |
| `--pretty` | Pretty-print JSON output |
| `--quiet` | Suppress success output |
| `--envelope` | Print the full reply envelope, not just the payload |
| `--timeout N` | Seconds to wait for a reply (default 1.5) |

`get ...` commands print JSON payloads. Mutating commands are silent
on success; pass `--envelope` to see the full reply.

## Commands

### `get`

Query state. All `get` commands print JSON.

| Command | Args |
| --- | --- |
| `hollow cli get pane` | `[--id ID]` |
| `hollow cli get pane-text` | `[--id ID]` |
| `hollow cli get current-pane` | |
| `hollow cli get tab` | `[--id ID]` |
| `hollow cli get current-tab` | |
| `hollow cli get tabs` | |
| `hollow cli get panes` | `[--tag TAG]` |
| `hollow cli get workspace` | `[--id ID\|--index N]` |
| `hollow cli get current-workspace` | |
| `hollow cli get workspaces` | |
| `hollow cli get domain` | |
| `hollow cli get htp <channel>` | `[params-json]` |

### `workspace`

| Command | Args |
| --- | --- |
| `hollow cli workspace new` | `[--cwd PATH] [--domain NAME] [--cmd CMD] [--name NAME]` |
| `hollow cli workspace close` | `[--id ID\|--index N]` |
| `hollow cli workspace next` | |
| `hollow cli workspace prev` | |
| `hollow cli workspace select <index>` | |
| `hollow cli workspace rename <name>` | `[--id ID\|--index N]` |

### `tab`

| Command | Args |
| --- | --- |
| `hollow cli tab new` | `[--cmd CMD] [--domain NAME]` |
| `hollow cli tab close` | `[--id ID\|--index N]` |
| `hollow cli tab next` | |
| `hollow cli tab prev` | |
| `hollow cli tab select <index>` | |
| `hollow cli tab rename <name>` | `[--id ID\|--index N]` |

### `pane`

| Command | Args |
| --- | --- |
| `hollow cli pane split vertical\|horizontal` | `[--cmd CMD] [--cwd PATH] [--domain NAME] [--ratio N]` |
| `hollow cli pane popup <cmd>` | `[--cwd PATH] [--domain NAME] [--x N] [--y N] [--width N] [--height N]` |
| `hollow cli pane close` | `[--id ID\|--tag TAG]` |
| `hollow cli pane zoom` | `[--id ID\|--tag TAG]` |
| `hollow cli pane float` | `[--id ID\|--tag TAG]` |
| `hollow cli pane tile` | `[--id ID\|--tag TAG]` |
| `hollow cli pane move <left\|right\|up\|down>` | `[--id ID\|--tag TAG] [--amount N]` |
| `hollow cli pane resize <left\|right\|up\|down>` | `[--id ID\|--tag TAG] [--amount N]` |
| `hollow cli pane send-text <text>` | `[--id ID\|--tag TAG]` |
| `hollow cli pane set-tag <tag>` | `[--id ID\|--tag TAG]` |
| `hollow cli pane remove-tag <tag>` | `[--id ID\|--tag TAG]` |
| `hollow cli pane set-tags [tag ...]` | `[--id ID\|--tag TAG]` |

### `focus`, `scroll`, `config`

| Command | Args |
| --- | --- |
| `hollow cli focus <left\|right\|up\|down>` | |
| `hollow cli scroll <top\|bottom\|page-up\|page-down>` | |
| `hollow cli config reload` | |
| `hollow cli config theme <name>` | |

### `run`, `send-keys`, `emit`

| Command | Args |
| --- | --- |
| `hollow cli run <cmd>` | `[--domain NAME]` |
| `hollow cli send-keys <keys>` | `[--id ID\|--tag TAG]` |
| `hollow cli emit <channel>` | `[payload-json]` |

`send-keys` decodes a kit/kb-style key sequence; for example
`{Up}{Enter}` sends the Up arrow followed by Enter.

## Targeting panes: `--id` vs `--tag`

Many `pane` commands accept both `--id` and `--tag`. When both are
omitted, the active pane is targeted. When `--tag` is given, the
command runs on every pane carrying that tag.

```bash
# Send text to the pane tagged "editor"
hollow.exe cli pane send-text "hello" --tag editor

# Zoom the pane tagged "build"
hollow.exe cli pane zoom --tag build
```

## Examples

```bash
# Open a new workspace in pwsh at C:/code/backend
hollow.exe cli workspace new --cwd "C:/code/backend" --domain pwsh --name backend

# Split vertical, run npm dev in a WSL pane
hollow.exe cli pane split vertical --domain wsl --cmd "npm run dev"

# Send Ctrl-C to the active pane
hollow.exe cli send-keys "{C-c}"

# Reload the config
hollow.exe cli config reload

# Switch to theme "rose-pine"
hollow.exe cli config theme rose-pine

# Custom HTP emit
hollow.exe cli emit notify '{"text":"build done","ttl":2000}'

# Custom HTP query
hollow.exe cli get htp echo '{"value":42}'
```

## See also

- [CLI index](README.md)
- [Python `hollow-cli`](hollow-cli.md) — OSC transport client
- [Shell integration](../../shell-integration.md) — overview
- [HTP protocol](../../htp-protocol.md) — wire format
