# Activity listing

The native `hollow-cli` and `hollow cli` query the same session-local activity
state as the Activity Center widget. Restart the rebuilt host to expose the new
command; this is not supported by the legacy Python client.

```sh
hollow-cli get activities                       # Inbox, all workspaces
hollow-cli --pretty get activities --view history
hollow-cli get activities --view running
hollow-cli get activities --pane 42 --kind program --severity error
hollow-cli get activities --view history --workspace main
```

Output is a JSON array, including `[]` when no entries match. Full task titles
and multiline messages are returned without UI truncation. Retained events are
newest first; Running is a live snapshot, not an event log.

## Filters

| Option | Values |
| --- | --- |
| `--view` | `inbox` (default), `history`, `running` |
| `--pane ID` | Exact originating pane ID; no implicit caller-pane filter |
| `--workspace NAME` | Exact workspace name |
| `--kind` | `notification`, `bell`, `program` |
| `--severity` (alias `--level`) | `info`, `warn`, `error`, `success` |

Filters combine with AND. Running program reports use severity `info` for
working and `warn` for blocked; shell-command fallback uses `info`.

Entries include `id`, `kind`, and available content/context fields: `title`,
`message`, `app`, `state`, `block_kind`, `program_id`, `progress`, `level`,
`pending`, `count`, `timestamp_ms`, `pane_id`, `pane_title`, `pane_closed`,
`workspace`, `tab_title`, and `cwd`. Unavailable fields may be omitted. Retained
IDs are numeric; live Running IDs are strings. Timestamps are monotonic session
milliseconds, not wall-clock dates. Running entries have no event timestamp.

Listing never acknowledges entries, changes live program status, or clears
notifications. History remains bounded and session-only; config reload preserves
it, application restart does not. No dismiss or watch commands are added.

## API and raw program status

```sh
hollow-cli api describe get_activities
hollow-cli api call get_activities '{"view":"history","id":42,"activity_kind":"program","level":"error"}'
hollow-cli program-status get --pane 42
```

The native command uses `id` for the explicit pane filter and `activity_kind`
for the activity-kind filter. Transport `kind` selects `get_activities`; caller
metadata lives in `ctx` and is not a filter. Socket, file, and OSC use the same
command contract. No running Lua runtime returns an `unavailable` error, not an
empty activity list.

`program-status get` reads raw live status for a pane. Activity listing instead
exposes the widget's Inbox, History, and Running policy, including notifications
and bells. See [Activity API](../lua/activity.md) for lifecycle details.
