# External events and completion waits

Both `hollow-cli` and `hollow cli` support these commands:

```sh
hollow-cli events subscribe
hollow-cli events read --after CURSOR [--pane ID] [--event KIND] [--command-id N]
hollow-cli events watch --after CURSOR [--pane ID] [--event KIND] [--command-id N]
hollow-cli --timeout 60 wait command --after CURSOR --pane ID [--command-id N]
hollow-cli --timeout 60 wait process-exit --after CURSOR --pane ID
hollow-cli --timeout 60 wait status-change --after CURSOR --pane ID
```

## Subscribe before launching work

Subscription returns `{"cursor":42,"capacity":512}`. This cursor marks the
current end of the event journal, independently of screen/UI revisions. Capture
it **before** launching work, then read or wait from that cursor. Fast completion
remains available even if it happened before the wait request reached Hollow.

For example, from a controller **outside the target pane's shell**:

```sh
pane=123 # Existing, dedicated automation pane at a shell prompt.
cursor=$(hollow-cli events subscribe | jq -r .cursor)
hollow-cli pane send-text "$(printf 'npm test\r')" --id "$pane"
hollow-cli --timeout 60 wait command --after "$cursor" --pane "$pane"
```

Use a dedicated pane without competing input. Without `--command-id`, a command
wait returns the first paired completion in that pane after the cursor, not
necessarily a command from your controller. For precise correlation, read a
`command_started` event and pass its `sequence` as `--command-id` when waiting
from the original cursor. Completion's `command_id` refers to that start.
These are observed shell reports, not authenticated execution receipts.

## Events and results

| Kind | Meaning |
| --- | --- |
| `command_started` | Shell integration reported a command start. |
| `command_finished` | Matching shell integration command ended; `status` is its exit code. Unpaired ends are ignored. |
| `process_exited` | Pane's child process exited; `status` is the OS exit status, or `null` if unavailable. This is not a command completion. |
| `status_changed` | Program status changed; query `program-status get --pane ID` for current records. Notifications are coalesced per frame, not a history of every intermediate status report. |
| `pane_closed` | Pane closed, including a manual close; not proof of successful command completion. |

Events contain `sequence`, `kind`, `pane_id`, nullable `command_id`, and nullable
`status`. Sequence numbers order events across panes. Command completion requires
shell integration emitting HTP `command_started`/`command_ended`; terminal output,
OSC prompt marks alone, or a revision increase never imply completion.

`events read` returns `{"cursor":N,"events":[...]}`. Pass its returned cursor
to the next read, including after an empty result. Filters apply only to event
selection; no pane filter means all panes, never the active/caller pane implicitly.
Event reads and completion waits require socket transport. Each host read waits
at most 250 ms; the CLI repeats reads until the overall `--timeout` for waits.

Raw API equivalents are `events_subscribe` (no arguments) and `events_read`:

```sh
hollow-cli api call events_read '{"after":42,"id":123,"event":"command_finished","timeout_ms":250}'
```

`capabilities` advertises `external_events` and `completion_waits`; `api describe`
provides the running host's input/output schemas for both methods.

`events watch` repeats reads indefinitely and prints one compact JSON event per
line (NDJSON); stop with Ctrl-C. `--pretty` and `--envelope` are rejected for watch.
The watcher reclaims transport/JSON allocations after each read.

Waits print one matching event. CLI exit code zero means an event was observed,
**not** that the command succeeded: inspect `status`, including nonzero exit codes.
A command wait does not turn process exit or pane close into command completion.

## Bounds and failures

The shared in-memory journal retains at most 512 events. No per-client allocation,
subscription handle, or unsubscribe is needed. A cursor older than retained history
fails with `event_overflow` and nonzero CLI exit status; no success is fabricated.
Overflow is conservative: unrelated panes can expire a filtered reader's cursor.
Do not silently resubscribe and claim prior work completed. Reconcile state or
fail that operation; subscribe again before launching new work.

Cursors belong only to one running Hollow instance. Discard them after restart
or reconnect to a different instance; they are not durable resume tokens. A cursor
ahead of the current journal fails with `invalid_cursor`. Shutdown wakes readers
with `shutting_down` after retained events have been consumed. No matching event
before the CLI deadline produces `timeout`.
