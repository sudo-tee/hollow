# Persistent sessions

Discover, attach, and kill [persistent sessions](../../persistent-sessions-guide.md) from scripts.
Both `hollow-cli` and `hollow cli` expose the same commands.

```sh
hollow-cli session list [--domain NAME]
hollow-cli session kill <id> [--domain NAME]
hollow-cli session attach <id> [--domain NAME] [--name NAME]
```

The domain must have `persist = true`.
An omitted domain inherits the active pane's domain, then the configured default domain.

## List

`session list` prints the owner's sessions without attaching to any of them:

```json
{
  "domain": "persistent_test",
  "host": "5d0e…",
  "sessions": [
    {
      "id": "8f3c…",
      "attached": true,
      "open": true,
      "revision": 12,
      "name": "backend",
      "panes": [
        { "id": 1, "title": "zsh", "cwd": "/home/me/src", "cols": 120, "rows": 40, "exited": false }
      ]
    }
  ]
}
```

`host` is the owner's stable host ID, persisted in its state directory.
It stays the same across owner restarts and is absent from owners that predate it.
`attached` means some client is attached, possibly another GUI.
`open` means a workspace in this GUI shows the session on the same host.
`name` appears when the saved layout records a workspace name.
An exited pane reports `exited: true` and its encoded `exit_status`.

## Kill

`session kill <id>` ends the session and every process in it, and prints `{ "domain", "host", "session" }`.
It is never retried.
When the reply is lost, the command fails with outcome `uncertain` and prints the failure details on stdout.
Run `session list` to find out whether the session is gone.

## Attach

`session attach <id>` queues attaching the session as a new workspace, like `hollow.term.attach_session`.
It takes over the session from any other attached client.
Success means the request was queued, not that the workspace was published.

## Failures

A failed list or kill exits with status 1 and code `session_query_failed`.
Its stdout carries `{ domain, outcome, error, remote? }`:

| `outcome` | Meaning |
| --- | --- |
| `not_sent` | The request never reached the owner. |
| `uncertain` | The owner may have acted; its reply was lost. |
| `rejected` | The owner refused, for example with `SessionNotFound` in `remote`. |

Admission errors fail immediately with `invalid_domain`, `invalid_args`, `resource_exhausted` (more than eight queries in flight), or `session_unavailable`.
The CLI waits at least 10 seconds, or `--timeout` if longer, because the first connection to a host may start it.

## Command API

The CLI builds on four commands that any [command API](native.md) client can call:

| Command | Arguments | Result |
| --- | --- | --- |
| `session_list` | `domain?` | `{ query, state: "running", revision }` |
| `session_kill` | `session`, `domain?` | `{ query, state: "running", revision }` |
| `session_result` | `query` | `{ query, op, state, revision, result? }` |
| `session_attach` | `session`, `domain?`, `name?` | queued |

`session_list` and `session_kill` only start a query.
Poll `session_result` until `state` is `done` or `failed`.
Over the socket transport, call `wait_revision` with the last `revision` between polls instead of sleeping.
A terminal result is returned once; afterwards the query id reports `query_not_found`.
Unread results expire after 60 seconds.
