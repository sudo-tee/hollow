# Persistent session owner upgrade plan

Status: implemented for Linux and WSL owners (`hollow-agent session serve`); native Windows owners keep empty-only retirement.

## Goal

Updating Hollow should replace a running Linux or WSL session owner without losing its panes.
Before this change an outdated owner with live sessions kept running until its last session ended (`retire-empty`).
Users with long-lived sessions therefore ran the old agent indefinitely.

## Approach

The owner re-executes itself in place, modelled on the Tern daemon `--handoff` re-exec.
`execve` keeps the process ID, the pane children, and every file descriptor without close-on-exec.
The old image passes its state to the new image through a memfd and keeps these descriptors open across the exec:

- every PTY master,
- the listening Unix socket,
- the owner lock file, so its `flock` stays held,
- the memfd payload,
- a read-only descriptor on its own executable, used for fallback.

Pane processes never notice the exchange.
Unread PTY output stays in the kernel and is read by the new image.
Client sockets and the signal descriptor close on exec.
The probing connector reconnects; other attached clients end and must reconnect explicitly.
Signals blocked for the signalfd stay pending across the exec, so no `SIGCHLD` is lost.

## Trigger

`session connect` probes the owner before bridging.
With `--upgrade handoff` (the default) the probe hello also carries:

- `handoff_path`: the connector's own executable (`/proc/self/exe`),
- `handoff_format`: the payload format it reads,
- `handoff_ghostty`: its ghostty build identity.

The owner accepts the handoff only when all of these hold:

- it has live sessions (empty owners use the existing retirement path),
- it is not stopping and owns the lock and listen descriptors,
- the payload format matches,
- the probe build differs from its own and is neither its predecessor nor a target that already failed,
- `handoff_path` is absolute and executable, and its fingerprint equals the probe build.

An accepting owner answers the probe with `retiring = true`, so the connector reconnects.
The exec runs at the end of the current loop step, once no pane is still waiting for its launch status.
Owners advertise the capability as the `exec-handoff` welcome feature.
For 10 seconds after a takeover or a failed exec, welcomes carry `handoff = { from, to, ok }`.
The owner keeps this window, so it does not depend on client clocks.
The GUI validates both builds, reports each distinct handoff once as the `session:handoff` Lua event, and shows a toast by default.

Any client of the owner socket can already run commands as this user.
The checks therefore confirm compatibility, not trust, and the target path is not restricted to a cache directory.

## Payload

`src/agent/session_handoff.zig` defines the format:

1. Magic `HHO1`, a `u32` format version, and the fallback path.
2. A length-prefixed JSON `State`: descriptors, build identities, sessions, pane metadata, and pending terminations.
3. One length-prefixed terminal blob per pane.

The blob is a binary ghostty snapshot when both builds share a ghostty identity, else a `formatVt` replay.
A pane whose terminal fails to restore starts blank; its process keeps running.
The payload is bounded to 512 MiB, and larger state fails the handoff with `ResourceExhausted`.

## Failure handling

- Payload or exec failure in the old image: descriptors get close-on-exec again, the owner keeps serving, and it never retries that target.
- Takeover failure in the new image: it releases partial state without closing inherited descriptors and execs the fallback path with the same payload.
- The fallback path is `/proc/self/fd/<n>` on the old executable, so it works even after a deploy replaced the file.
- A fallback whose fingerprint matches the failing image is skipped, which prevents an exec loop.
- The fallback adopts the payload and marks the rejected target as failed.

## Configuration

Domains choose the policy with `upgrade`:

| Value | Behavior |
| --- | --- |
| `"handoff"` | Default. Exec the new agent in place when the owner has live sessions. |
| `"retire_empty"` | Previous behavior: replace the owner only after its last session ends. |
| `"never"` | Do not ask the owner to retire or hand off. |

The GUI passes non-default values as `session connect --upgrade <mode>`.
Older agents ignore the extra argument, and older owners ignore the new hello fields.

## Not carried across

- Client connections. Only the probing connector reconnects on its own.
- Shell command tracking state (`shell_command`) of each pane terminal.

## Tests

- `session_handoff.zig`: payload round-trip, truncation, and format checks.
- `session_vt.zig`: adoption from both snapshot formats keeps screen text and answers queries.
- `session_transport_test.zig`: a live owner from a different build is handed off in place; the PID, pane, and screen survive and the pane keeps accepting input.
- The `retire_empty` path keeps its existing transport test.

## Open work

- No automated test injects a takeover failure to exercise the fallback exec.
- Native Windows owners cannot exec in place; they keep empty-only retirement.
