# Experimental agent PTYs

The Linux agent now runs real PTYs behind an explicit protocol opt-in. This
experiment includes a bounded native stream adapter and explicit development-only
pane opt-in. It does **not** change default pane backends or replace WSL bypass,
and headless adapter tests are not GUI qualification.

## Try it

```sh
zig build --build-file build-agent.zig agent -Doptimize=ReleaseSafe
python3 scripts/agent_pty.py --agent zig-out/bin/hollow-agent -- /bin/sh -i
python3 scripts/agent_pty_tests.py --agent zig-out/bin/hollow-agent
```

The interactive client enters local raw mode, forwards bytes and terminal resize,
renders received output directly to the terminal, and restores terminal settings
on exit/failure. Ctrl-C is input to the remote terminal, not local process control.
Optional `--connector-argv '<JSON argv>'` opens the same agent through a selected
`podman exec -i`, `wsl.exe --exec`, or `ssh -T` command. Configure/authenticate the
transport yourself; this client does not implement bootstrap or host-key policy.
Never pass `-t`/`-tt` to the outer launcher: only the agent allocates the PTY.

## Experimental pane attachment

Launch Hollow with an explicit JSON configuration (absolute connector paths are
recommended):

```sh
export HOLLOW_EXPERIMENTAL_AGENT_PTY='{"connector_argv":["/absolute/path/hollow-agent","stdio"],"argv":["/bin/sh","-i"],"cwd":"/","env":[{"key":"TERM","value":"xterm-256color"}]}'
```

Every new pane in that process then opens its own connection/session. Unset the
variable to retain native/WSL bypass selection. Invalid configuration or an
unsupported agent fails closed, never silently falls back. Launch-command panes
are rejected rather than ignoring their command. This development override does
not deploy agents or infer remote argv, cwd, or environment from native spawn
settings; configure those explicitly. Lua workspace/host policy integration is
still pending. Agent sessions expose no local PID and disable local cwd inference.

The adapter starts asynchronously, signals the existing pane wake callback, queues
at most 64 KiB input, and consumes at most 64 KiB pending output. Output credit
follows consumption; terminal completion cannot overtake buffered output. Input
is chunked to 16 KiB with one control request in flight, and a full remote queue
retries retained bytes after a scheduled wake. Resize is coalesced. Closing the
pane destroys its connection and invokes agent connection-scoped cleanup; no
reconnect or replay is attempted.

```sh
zig build --build-file build-agent.zig test-agent-pty -Doptimize=ReleaseSafe
```

This headless target tests the adapter and pane PTY union, not a rendered pane.
`HOLLOW_TEST_CONNECTOR_ARGV` selects a remote connector for adapter cases; pane
entry-point and wake tests still use their explicit local fixture.

### Explicit shared native adapter (research only)

`SharedConnection.create` and `AgentPty.spawnShared` let a headless experiment
attach up to 16 adapters to one prepared connector. This is not a new pane
configuration or HostManager backend: the development pane override above still
creates one dedicated connection per pane. No persistence/replay is added.

The wrapper and all session methods are owner-thread-only. It owns one aggregate
wake callback; its caller services every attached session after a wake. Each
adapter polls only its own spawn/control IDs, so a fast sibling cannot consume
another session's completion. Stream IDs are allocated in submission order,
including when handles are created and first serviced in different orders.

Job admission and request-slot admission are separate: the agent's existing
16-job limit still includes PTYs, EXECs and filesystem workers, while up to 32
requests leave room for each PTY's one input/resize RPC. Full admission retries
on a scheduled wake rather than silently failing the session.

Closing a shared adapter cancels only its spawn and pending control. Bounded
tombstones discard late frames and retire only after terminal acknowledgement;
if the outbound queue is full, the watchdog retries cancellation. A cancellation
deadline failure can still disconnect the transport, as before. Destroying the
shared owner closes the connection for all sessions but retains its storage until
the last adapter closes; owner handle becomes invalid on destruction. The wake
callback/context must therefore outlive all attached adapters. Unexpected
transport loss intentionally fails every attached PTY: sharing changes the fault
boundary, not just connection count.

Regression cases cover 1/4/8/16 sessions with reverse submission/consumption,
full-load input/resize, failed launch isolation, stopped consumption at 64 KiB,
close/replacement and owner-first teardown. They are correctness tests, not
shared-connection performance qualification.

### Real pane and terminal integration

A separate headless graph links the actual terminal engine and exercises
`Pane.bootstrap`, layout resize, `pollPty`, startup deferral, render-state updates,
background parsing, and teardown without window/GPU/Lua/font dependencies:

```sh
bash scripts/setup.sh --agent-pane
zig build -Dagent-pane-only=true test-agent-pane -Doptimize=ReleaseSafe
```

Two cases verify 128 KiB binary startup input by SHA-256, terminal query/reply
through the pane write callback, primary/alternate terminal grid contents, final
output and exit status, and closing one pane with partially delivered input while
another remains usable. The fixture uses lightweight callbacks, not the complete
application callback bundle. `HOLLOW_TEST_CONNECTOR_ARGV` routes these sessions
through an explicitly prepared connector; unset selects the built local agent.
This is real pane/terminal-state integration, not GPU rendering or a native
Windows application run.

## Experimental wire contract

HELLO must include `"experimental_pty":true`; HELLO_ACK then advertises
`"experimental.pty"`. Without opt-in, PTY operations return `unsupported` and
ordinary fs/exec behavior stays unchanged. The extension is experimental, not a
stable production capability or automatic protocol-version upgrade.

* `PTY_SPAWN`: byte-valued `argv_b64`, optional `cwd_b64`/`env_b64` as for EXEC;
  distinct increasing even `stdout_stream_id` and reserved `stderr_stream_id`;
  `rows`/`cols` in 1–65535 (defaults 24/80); `output_credit` 0–1048576 (default
  65536); `timeout_ms` 1–86400000 (agent default one day).
* The spawn request ID is the connection-scoped session ID. Spawn remains open:
  DATA for that request/output stream arrives **while the program is running**;
  one terminal RESPONSE with `exit_code` follows fully drained output, or ERROR
  reports launch failure/cancel/deadline. There is no separate ready ACK yet.
* PTY stdout and stderr are merged by the terminal. The reserved stderr stream
  produces no DATA. No client may treat this as two independently captured pipes.
* WINDOW_UPDATE uses the spawn request ID/output stream and a positive u64 LE
  consumed-byte count. Outstanding credit cannot exceed 1 MiB. Late valid credit
  acknowledgements after terminal completion are ignored. Credit is granted only
  after consumption; a non-consuming peer must not continuously replenish it.
* `PTY_INPUT`: `session_id`, `bytes_b64`; at most 16 KiB per input request, 64 KiB
  pending per session. NUL and non-UTF-8 bytes are legal input. RESPONSE `{}` means
  queued, not consumed by the child. Full queues return `resource_exhausted`;
  callers must retain/retry those bytes rather than discard them.
* `PTY_RESIZE`: `session_id`, `rows`, `cols`. TIOCSWINSZ updates dimensions and
  delivers SIGWINCH to the terminal foreground process group.
* `PTY_CLOSE`: `session_id`; starts supervised TERM/KILL cleanup, ACKs the control
  request, and ends the original spawn with `cancelled`. CANCEL of the spawn ID
  also closes it. Invalid/stale session controls are per-request errors.

One connection's existing 16-job limit includes PTYs, EXECs and filesystem
workers. PTY queues retain at most 64 KiB output and 64 KiB input per session,
plus the existing bounded agent transport queue/kernel PTY buffers. Reads pause
when output buffering is full; input writes are nonblocking and polled. Slow
PTY output does not monopolize the loop or prevent control/fs RPCs. If a peer
withholds output credits, normal exit waits for output drainage; explicit close,
connection loss or deadline terminates the session instead of waiting forever.

## Process and terminal ownership

The same per-job subreaper guardian supervises EXEC and PTY workloads. A PTY
workload creates a session with `setsid`, takes its slave as controlling terminal,
and maps all three stdio descriptors to it. Other jobs' descriptors are closed.
The guardian does not retain the terminal slave/master. The agent owns only the
nonblocking master, launch-error pipe and bounded queues. Linux PTY-master EIO
after slave closure is terminal EOF, not a connection-wide transport error.

Resize and Ctrl-C use actual Linux terminal semantics; byte input is not parsed
as key names or shell commands. Close/EOF/deadline and agent death use supervised
cleanup. Sessions do not detach, survive transport loss, or reconnect/replay.

## Qualification boundary

Eleven tests pass locally, through rootless Podman, and through real `wsl.exe`
invoked from Linux/Windows interop. Ordinary fs/exec conformance remains green.
These results do not qualify native Windows GUI behavior, latency, throughput,
OOM/fork-bomb/guardian-death stress, or hostile PTY clients. ARM64 is cross-built,
not runtime-tested. Native adapter tests additionally cover multi-megabyte output,
exact input across real backpressure, wakeups, exit/drain ordering, transport-loss
isolation, and explicit pane backend selection. Windows adapter code is
cross-compiled, not executed. Real pane/terminal-state cases additionally pass
locally, through rootless Podman and through WSL interop. Rendered GUI lifecycle and baseline performance
comparisons remain required before any default switch. Pane attachment uses one
connection per pane. Explicit shared native experiments do not add HostManager
session multiplexing or persistent sessions.
