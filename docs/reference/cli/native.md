# Native `hollow cli …`

The native CLI subcommand talks directly to the running Hollow host's
command socket. It does not need a tty, does not need shell
integration sourced, and is the fastest option when a Hollow window
is already running.

The CLI uses `HOLLOW_COMMAND_ADDR` when available. Otherwise it discovers the
running host through `%LOCALAPPDATA%\hollow\command-ipc-address`, so a Windows
CLI invoked from an unrelated shell or from WSL works without inherited state.

The command server binds only to loopback addresses. It handles up to eight
connections concurrently, while application mutations remain serialized on the
frame thread. Incomplete frames are disconnected after a total five-second
operation deadline, including on Windows. Native client timeouts cover the frame
exchange; connection establishment uses the OS timeout because Zig 0.16's timed
connect API is unimplemented. Loopback binding does not authenticate local users;
protect access to the local session accordingly.

## Running it

```bash
hollow.exe cli <command> [...]
hollow.exe cli --help
```

`hollow.exe cli …` is the same launcher as the GUI; the `cli` token
is intercepted by `src/main.zig:guiMain` before the GUI is started.

## Global options

| Flag          | Effect                                              |
| ------------- | --------------------------------------------------- |
| `--pretty`    | Pretty-print JSON output                            |
| `--quiet`     | Suppress success output                             |
| `--envelope`  | Print the full reply envelope, not just the payload |
| `--timeout N` | Seconds to wait for a reply (default 1.5)           |

`get ...` commands print JSON payloads. Mutating commands are silent
on success; pass `--envelope` to see the full reply.

## Commands

### `get`

Query state. All `get` commands print JSON.

| Command                            | Args                   |
| ---------------------------------- | ---------------------- |
| `hollow cli get pane`              | `[--id ID]`            |
| `hollow cli get pane-text`         | `[--id ID]`            |
| `hollow cli get screen`            | `[--id ID]`            |
| `hollow cli get ui-nodes`          |                        |
| `hollow cli get revision`          |                        |
| `hollow cli get current-pane`      |                        |
| `hollow cli get tab`               | `[--id ID]`            |
| `hollow cli get current-tab`       |                        |
| `hollow cli get tabs`              |                        |
| `hollow cli get panes`             | `[--tag TAG]`          |
| `hollow cli get workspace`         | `[--id ID\|--index N]` |
| `hollow cli get current-workspace` |                        |
| `hollow cli get workspaces`        |                        |
| `hollow cli get domain`            |                        |
| `hollow cli get htp <channel>`     | `[params-json]`        |

### `workspace`

| Command                               | Args                                                     |
| ------------------------------------- | -------------------------------------------------------- |
| `hollow cli workspace new`            | `[--cwd PATH] [--domain NAME] [--cmd CMD] [--name NAME]` |
| `hollow cli workspace close`          | `[--id ID\|--index N]`                                   |
| `hollow cli workspace next`           |                                                          |
| `hollow cli workspace prev`           |                                                          |
| `hollow cli workspace select <index>` |                                                          |
| `hollow cli workspace rename <name>`  | `[--id ID\|--index N]`                                   |

### `tab`

| Command                         | Args                          |
| ------------------------------- | ----------------------------- |
| `hollow cli tab new`            | `[--cmd CMD] [--domain NAME] [--cwd DIR]` |
| `hollow cli tab close`          | `[--id ID\|--index N]`        |
| `hollow cli tab next`           |                               |
| `hollow cli tab prev`           |                               |
| `hollow cli tab select <index>` |                               |
| `hollow cli tab rename <name>`  | `[--id ID\|--index N]`        |

### `pane`

| Command                                          | Args                                                                    |
| ------------------------------------------------ | ----------------------------------------------------------------------- |
| `hollow cli pane split vertical\|horizontal`     | `[--cmd CMD] [--cwd PATH] [--domain NAME] [--ratio N]`                  |
| `hollow cli pane popup <cmd>`                    | `[--cwd PATH] [--domain NAME] [--x N] [--y N] [--width N] [--height N]` |
| `hollow cli pane close`                          | `[--id ID\|--tag TAG]`                                                  |
| `hollow cli pane zoom`                           | `[--id ID\|--tag TAG]`                                                  |
| `hollow cli pane float`                          | `[--id ID\|--tag TAG]`                                                  |
| `hollow cli pane tile`                           | `[--id ID\|--tag TAG]`                                                  |
| `hollow cli pane move <left\|right\|up\|down>`   | `[--id ID\|--tag TAG] [--amount N]`                                     |
| `hollow cli pane resize <left\|right\|up\|down>` | `[--id ID\|--tag TAG] [--amount N]`                                     |
| `hollow cli pane bell`                            | `[--id ID\|--tag TAG] [--level info\|warn\|error\|success] [--color #RRGGBB]` |
| `hollow cli pane send-text <text>`               | `[--id ID\|--tag TAG]`                                                  |
| `hollow cli pane set-tag <tag>`                  | `[--id ID\|--tag TAG]`                                                  |
| `hollow cli pane remove-tag <tag>`               | `[--id ID\|--tag TAG]`                                                  |
| `hollow cli pane set-tags [tag ...]`             | `[--id ID\|--tag TAG]`                                                  |

### `program-status`

```sh
hollow cli program-status set working --app demo --progress 25
hollow cli program-status set blocked --id build --kind permission --message "Allow deploy?"
hollow cli program-status get --pretty
hollow cli program-status clear --id build
hollow cli program-status clear
```

`set <idle|working|done|blocked|error>` accepts `--id TASK`, `--app TEXT`,
`--title TEXT`, `--message TEXT`, `--progress 0..100`, and
`--kind none|permission|question|auth`. Progress requires working/blocked;
non-none kind requires blocked. Reports replace the whole record, not patches.
`get` returns the current record array as JSON, with inherited `app` values
and nullable `progress`. `clear --id TASK` clears that task and descendants;
omitting `--id` clears all records.

All three accept `--pane ID` to target a pane. Otherwise `HOLLOW_PANE_ID`
selects the calling pane, falling back to the active pane outside Hollow.
Unknown panes and invalid reports fail without changing state. Task IDs are
at most 256 ASCII letters/digits or `/_.-`; app/title/message limits are
256/512/2048 UTF-8 bytes. Display text receives the same sanitization as OSC 7501.

These commands update the same state used by OSC 7501, Lua and the tab bar,
mux navigator and workspace switcher. Returning to the primary shell prompt
clears working/idle records. Blocked attention survives prompt return until
replaced/cleared or the child exits. Done/error records survive prompt return
until replaced/cleared. Refocusing acknowledges only unread blocked/error attention
(`attention` in `get` output), not status records. Reports raise attention only
while the pane is inactive. To see a working badge while testing:

```sh
{ hollow cli program-status set working --app demo --progress 25; sleep 20; }
```

The native client uses the command socket. The equivalent Python
[`hollow-cli program-status`](hollow-cli.md#program-status) also supports file
and OSC query transports. Shared HTP query channels are `program_status_set`,
`program_status_get`, `program_status_clear`; fields are passed in `params`,
with `pane` for the target pane and `id` for the task ID.

### `focus`, `scroll`, `config`

| Command                                               | Args |
| ----------------------------------------------------- | ---- |
| `hollow cli focus <left\|right\|up\|down>`            |      |
| `hollow cli scroll <top\|bottom\|page-up\|page-down>` |      |
| `hollow cli config reload`                            |      |
| `hollow cli config theme <name>`                      |      |

### `run`, `send-keys`, `emit`, `notify`

| Command                                      | Args                                                            |
| -------------------------------------------- | --------------------------------------------------------------- |
| `hollow cli run <cmd>`                       | `[--domain NAME]`                                               |
| `hollow cli send-keys <keys>`                | `[--id ID\|--tag TAG]`                                          |
| `hollow cli emit <channel>`                  | `[payload-json]`                                                |
| `hollow cli notify <message>`                | `[--level info\|warn\|error\|success] [--ttl MS] [--title TEXT]` |

### UI automation

| Command                      | Args                                                      |
| ---------------------------- | --------------------------------------------------------- |
| `hollow cli ui click <id>`   | `[--surface topbar\|bottombar\|overlay] [--generation N]` |
| `hollow cli wait <revision>` |                                                           |

`get screen` returns the visible terminal viewport as zero-based row objects,
plus cursor position, visibility, style, pane metadata, and automation revision.

`get ui-nodes` returns semantic nodes from the last rendered frame.
Each node includes its ID, surface, bounds, role, and supported actions. Pass its
generation back to `ui click` to reject clicks against stale UI.

Overlay panels and rows are discovered automatically as `dialog` and `listitem`
nodes with IDs such as `overlay:1:row:5`; widgets do not need to annotate them.
Structural nodes have an empty `actions` array. Rows backed by a widget action
use their explicit ID and advertise `click`.

Automation revisions increase after terminal output, queued input/actions, and
semantic UI changes. `wait R` blocks until the current revision is greater than
`R`; use global `--timeout` to bound the wait. The CLI uses 250 ms long-poll
requests so other clients can use command transport during longer waits.

`send-keys` decodes a kit/kb-style key sequence; for example
`{Up}{Enter}` sends the Up arrow followed by Enter.

`pane bell --level` uses built-in Hollow notification level color for visual flash.
An explicit `--color #RRGGBB` overrides it.

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

# Trigger attention in a specific pane
hollow.exe cli pane bell --id 123

# Trigger a red visual bell
hollow.exe cli pane bell --level error --id 123

# Use a custom visual bell color
hollow.exe cli pane bell --color "#ff00aa" --tag build

# Reload the config
hollow.exe cli config reload

# Switch to theme "rose-pine"
hollow.exe cli config theme rose-pine

# Custom HTP emit
hollow.exe cli emit custom-channel '{"key":"value"}'

# Send a notification
hollow.exe cli notify "Build succeeded" --level success --ttl 5000

# Custom HTP query
hollow.exe cli get htp echo '{"value":42}'

# Inspect terminal viewport and cursor
hollow.exe cli --pretty get screen

# List and click current semantic UI targets
hollow.exe cli --pretty get ui-nodes
hollow.exe cli ui click tabs.new --surface topbar --generation 4

# Wait for terminal or UI state to change
hollow.exe cli --timeout 5 wait 12
```

## See also

- [CLI index](README.md)
- [Python `hollow-cli`](hollow-cli.md) — OSC transport client
- [Shell integration](../../shell-integration.md) — overview
- [HTP protocol](../../htp-protocol.md) — wire format
