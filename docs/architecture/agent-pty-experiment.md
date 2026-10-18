# Experimental agent PTYs

The Linux agent now runs real PTYs behind an explicit protocol opt-in. This
experiment does **not** switch Hollow panes or replace WSL bypass. It supplies
the agent/session half of the next PTY integration step, not GUI qualification.

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
not runtime-tested. The Python client is deliberately separate from Hollow's
native host manager and pane backends. Next integration must add a bounded native
stream/session adapter, then opt-in pane attachment and real baseline comparisons;
it must not replace bypass/default PTYs merely because these headless tests pass.
