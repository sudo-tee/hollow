# `hollow.activity`

Session-local activity shared by the Activity Center and topbar bell. Notifications,
terminal bells, and meaningful program-status reports share an inbox, but retain
their own lifecycle. Running work never contributes to the unread count.

## Using the Activity Center

- Click the always-visible topbar bell or press `<leader>a` to open Inbox.
- Press `<leader>h` to open History directly.
- Inside the widget: `Tab` switches Inbox/History, `/` searches, `j`/`k` or arrows
  navigate, `Enter` goes to the originating pane, `d` dismisses, `Ctrl-d` dismisses
  all pending entries, and `v` opens wrapped, scrollable message details.
- Live work is grouped into independently collapsible **Tasks** (expanded by
  default) and **Commands** (collapsed by default). Headers show matching counts;
  click one or select it and press `Enter`/`Space` to toggle. `t` (also `r`)
  toggles Tasks; `c` toggles Commands. Empty categories are hidden.
- Search temporarily reveals matching items in collapsed categories. Expansion
  changes made while searching apply only to search results; leaving search
  restores the normal expansion state. Opening a new widget restores defaults.
- Press `y` or `Ctrl-C` to copy the selected item's full title and message.
  Details also has a Copy button. Copying excludes workspace metadata, does not
  acknowledge the item, and works for History and Running entries too.
- `Esc` leaves search or details first, then closes the widget.
- The outline bell means no pending entries. A filled bell and count mean pending
  acknowledgement; repeated bells from one pane count as one grouped entry.
- Each item occupies one line, with a compact workspace pill on the right.
  Pills use the same workspace colors and custom overrides as the workspace selector.
  View and workspace pills have 8px horizontal and 3px vertical padding.
  Reported task rows show application name and state, not task titles. Shell
  rows show the actual command; classified tasks animate, other commands use a
  static, neutral Running indicator.
  Paths and full message bodies live in `v` details, not repeated metadata rows.
  The search field appears only after pressing `/`.

Tasks show live `working` and `blocked` program reports, with progress when
available, plus shell commands matched by task rules below. A blocked task already
in Inbox is not repeated under Tasks.
Commands show shell-integrated commands when that pane has no active
program-status report. Once a command reports program status, shell fallback stays
suppressed for that command even after its status becomes idle, completes, or is
cleared. A new shell command can appear normally. Ordinary shells without either
source cannot supply task lifecycle information. Hollow does not infer a command's
expected lifetime from its name or elapsed time.

## Shell-command rules

Configure rules in your Lua config. All three lists default to empty:

```lua
hollow.activity.setup({
  tasks = {
    "^zig build%f[%s%z]",
    "^cargo test%f[%s%z]",
    "^make%f[%s%z]",
    "^npm run build%f[%s%z]",
  },
  commands = { "%-%-watch", "^npm run dev%f[%s%z]" },
  ignore = { "^nvim%f[%s%z]" }, -- Hide nvim and nvim <args> entirely.
})
```

Rules are case-sensitive **Lua patterns**, not regular expressions or globs,
matched against the full shell command text as received from shell integration.
`^` anchors the start; `%f[%s%z]` matches a whitespace/end boundary so `make`
does not match `makebelieve`. Wrappers (`sudo`, `env`), paths, aliases, and compound
commands are not parsed or normalized; write patterns for the text your shell sends.

Precedence is **ignore → commands → tasks**:

- `ignore` (blacklist) hides matching shell fallback entries from Tasks, Commands,
  Lua/CLI Running listings, and task badges. It does not terminate processes or
  suppress notifications, bells, or explicit program-status reports.
- `commands` forces the collapsed Commands category, even if a task rule matches
  (for example, a test runner in watch mode).
- `tasks` promotes matching shell commands to expanded Tasks, with animated task
  indicators, including workspace badges. Full command text remains copyable.
- Unmatched commands remain in Commands with a neutral static indicator.

Explicit program status always wins. Rules only affect shell fallback and cannot
resurrect a command suppressed after its program status was cleared. Shell tasks
leave Tasks and lose their badges when shell integration reports completion;
completion does not currently create Inbox or History entries.

Each `setup()` replaces all rules (omitted lists become empty), copies the supplied
lists, and reclassifies already-running commands. `setup()` with no options resets
rules. Reloading config reapplies its rules without restarting processes or
discarding activity history.

## API

```lua
hollow.activity.list({ view = "inbox" })   -- default view; newest first
hollow.activity.list({ view = "history" }) -- all retained entries, including pending
hollow.activity.list({ view = "running", pane_id = 42 }) -- filtered live work
hollow.activity.list({ workspace = "main", activity_kind = "program", level = "error" })
hollow.activity.running()                 -- live reported tasks and shell commands
hollow.activity.summary()                 -- { count, level? }; excludes running
hollow.activity.dismiss(entry.id)          -- true if acknowledgement changed
hollow.activity.dismiss_all()
hollow.activity.clear_history()            -- remove acknowledged entries only

hollow.ui.activity.open({ view = "inbox", width = 100, max_height = 24 })
hollow.ui.activity.open({ view = "history" })

-- Reusable text clipboard API; returns true when the write is queued.
hollow.clipboard.write("Text to copy")
```

`hollow.clipboard.write(text)` returns false if unavailable, rejected, or text
contains an embedded NUL. It supports empty strings and multiline Unicode text.

Lists are isolated snapshots. Retained entries have numeric IDs, `kind`
(`notification`, `bell`, or `program`), title/message, severity, monotonic
`timestamp_ms`, `pending`, and a grouped occurrence `count`. Pane-originated
entries also retain pane ID, pane title, workspace, and cwd. Program entries
include `state` and optionally `block_kind`. Live running entries have string IDs
and optionally `progress`; they are not retained events and cannot be dismissed.
Live entries expose `source = "program_status"` or `"shell_command"` so callers
can distinguish them without interpreting IDs or command names. `category` is
`"task"` or `"command"`; a rule-classified shell task keeps `source = "shell_command"`.
Collapsing a widget category does not remove its entries from API or CLI Running
snapshots; ignore rules do.

`list` accepts exact-match `pane_id`, `workspace`, `activity_kind`, and `level`
filters combined with AND. `view = "running"` queries the same live snapshot as
`running()`. The native [activity CLI](../cli/activities.md) uses this same API;
neither Lua nor CLI listing acknowledges entries.

`ui.activity.open()` accepts `view`, `width`, `height`, `max_height`, `theme`,
`chrome`, and `backdrop`. It returns a modal handle, or `nil` when another modal
is already open. The existing `attention_navigator` action and mux attention
filter remain available for pane-oriented navigation.

## Lifecycle

- All notifications enter History, including notifications received while focused.
  This includes terminal protocols and `hollow.ui.notify.*` calls.
- Background notifications and bells enter Inbox. Background means either the
  originating pane is not focused or Hollow's window lacks OS focus. Notifications
  without a pane use window focus only. `ui.notify.show` accepts `pane_id` to
  associate a plugin notification with a pane.
- Background `blocked`, `done`, and `error` reports enter Inbox. Focused reports
  enter History only. Progress ticks and ordinary `working`/`idle` reports do not
  create history entries. Unchanged state reports update their existing entry
  without resurrecting a dismissed request.
- Clearing or replacing a program status archives its related Inbox entry,
  including `done` and `error`. Starting new work does not leave an old completion
  marker pending. History retains the old report; unrelated program records,
  notifications, and bells are unaffected. Closing a pane archives its program
  entries as well.
- Opening the widget, focusing a pane, or expiring a toast does **not** acknowledge
  the inbox. Dismissal and successful go-to-pane acknowledge the selected entry.
- Explicit toast clearing, Escape dismissal, protocol close, or notification-ID
  replacement archives the matching notification. Replacement retains the old
  version in History and creates a new entry.
- Dismissal never cancels work or clears live program status. Existing terminal
  tab/pane attention markers retain their normal focus-based lifecycle.
- Closed panes remain identified in history; navigation to those entries is disabled,
  even if a later pane reuses the same native ID.

Up to **500** events are retained; oldest events are evicted at capacity. No activity
is written to disk. Config reload transfers it in memory, while application restart
starts empty. Clearing history preserves pending entries.

Program-status events currently expose coalesced snapshots: intermediate transitions
inside one terminal update may not be observable. History is an activity log, not a
lossless protocol trace. Bells may likewise be coalesced by the terminal event loop.

Custom events `activity:changed` (`{}`) and `activity:dismissed` (`{ id }`) can be
observed through `hollow.events.on`. Shell command lifecycle does not emit
`activity:changed`; subscribe to `term:command_started` / `term:command_finished`
as well when building a custom live view. Query `running()` for current state.
