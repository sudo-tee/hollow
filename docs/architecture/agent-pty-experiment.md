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

### Explicit focus/session scheduler (research only)

This is an independently negotiated **hierarchical weighted round-robin baseline**,
not byte-fair DRR, GUI workspace policy, or a rollout switch. Agent must have both
`HOLLOW_AGENT_BOUNDED_BULK` and `HOLLOW_AGENT_FOCUS_SCHEDULER` present; client HELLO
must include both `experimental_pty:true` and `experimental_focus:true`.
Only then does HELLO_ACK advertise `experimental.focus`. Requested native clients
fail closed if that capability is missing. Ordinary fs/exec connections and
non-focus PTY connections keep their existing scheduler selection.

For a prepared local target, the native research API is:

```zig
const owner = try SharedConnection.createWithOptions(allocator, connector_argv, wake,
    .{ .experimental_focus = true });
// Each attached pane supplies caller-owned logical session metadata.
var pane = try AgentPty.spawnShared(allocator, owner,
    .{ .argv = &.{ "/bin/sh", "-i" }, .logical_session_id = 7 }, cols, rows);
// After pane startup, output_stream is available. Explicit UI/experiment input:
const request_id = try owner.updateFocus(1, 7, pane.output_stream.?);
// Caller must pollFor(request_id) and freeCompletion(), including remote errors.
```

No GUI event wiring, shared-pane configuration or HostManager policy is inferred.
The development pane override remains dedicated and cannot select this scheduler.
Server flags must be explicitly supplied on the **target** for prepared remote
connectors, not merely in the client's environment. Python `PtyClient.start(focus=True)`
and `spawn(..., logical_session=7)` expose the same wire contract.

* Negotiated `PTY_SPAWN` requires positive `logical_session_id`, distinct from the
  spawn request ID used by PTY_INPUT/RESIZE/CLOSE. Several panes may share it.
* `FOCUS_UPDATE` is an ordinary short-lived REQUEST with `generation` equal to
  HELLO_ACK's `connection_nonce`, positive monotonic `sequence`,
  `active_session_id` (logical group), and `active_stream_id` (PTY output stream).
  IDs/sequences are JSON integers in 0–2^63−1; sequences and logical PTY groups
  must be nonzero. Session and stream zero together clear focus. A positive live
  group with stream zero selects only that session; otherwise stream must belong
  to that group on this connection.
* RESPONSE `{ "applied":true, "sequence":N }` means metadata applied during
  dispatch, **not** bytes reprioritized retroactively or child input consumed.
  Stale/duplicate sequences return `applied:false` with current sequence, without
  validating an obsolete target. Wrong nonce, invalid new target, or sequence zero
  returns `invalid_argument`, without advancing accepted sequence. Without the
  capability, operation returns `unsupported` without spawning a worker.
* Closed/cancelled targets cannot receive new focus. Terminally released panes
  clear their stream selection; releasing last group member clears selected group.
  Sequence remains monotonic. Stream IDs are never reused; slot reuse cannot
  retarget an old stream. No replay/reconnect or persistence is introduced.
* Native transport treats focus as a control, not a worker job. The 16-job/32-request
  admission split remains; focus can return NotReady/ResourceExhausted locally and
  callers must retain/retry metadata explicitly. Caller supplies sequences; neither
  wrapper nor agent infers focus from traffic or pane activity.

Scheduler first rotates **logical session groups**, then panes within each group.
Selected session receives four visits per outer turn versus one for each other
session and one for the aggregate bulk group; selected pane receives four visits
per inner turn versus one for siblings. Bulk fs/exec jobs rotate inside their one
group. More panes do not multiply a session's outer weight. Without a selected
group, all groups have equal weight; this is still different from flat per-job RR.

One visit emits at most one 16 KiB PTY quantum or one whole bulk frame; the existing
64 KiB single-ready-stream quantum and 65,624-byte soft batch limit remain. Small
frames count as full visits, not proportional bytes. Oversized atomic filesystem
metadata may queue alone into empty output under existing limits. A frame that
cannot fit reserves next selection until output drains, even across focus changes.
Partially written/queued frames are not reordered or preempted. Control direction
remains full-duplex FIFO; no independent control lane or flood rate limiter is added.

State is fixed-capacity for 16 jobs/groups, with at most 64 selections per output
scheduling call. Cursors/quota carry across calls; focus changes never restart them
and truncate residual quota to at most one visit. Unready/zero-credit panes are
skipped; credit and capture limits are unchanged. Deterministic tests check exact
stable weighted visits, bounded visit gaps for continuously ready slots, focus
churn, slot reuse and metadata retry. These are not wall-time fairness, byte-QoS,
arbitrary arrival/churn or CPU/RSS/scale qualification.

```sh
python3 scripts/agent_focus_tests.py --agent zig-out/bin/hollow-agent
HOLLOW_AGENT_BOUNDED_BULK=1 HOLLOW_AGENT_FOCUS_SCHEDULER=1 \
  python3 scripts/agent_pty_bench.py --focus-scheduler --backend shared \
  --sessions 8 --load noisy stalled --bulk off mixed --resize-every 16 \
  --runs 3 --samples 1000 --size-mib 10 --output focus-research.jsonl
```

Benchmark groups every four panes, explicitly selects foreground stream in group
one **before load starts**, and leaves focus static. `focus_ack_ns` is initial
request-to-ACK wall time, not loaded focus-change application delay. Existing
foreground-first consumption remains identical; no focus-first GUI parsing/render
variable is simulated. Dynamic focus switching is tested for correctness, not yet
latency-qualified. Every result remains `qualification:false`.

### Explicit hierarchical byte-deficit scheduling

The independent deficit prototype requires target flag
`HOLLOW_AGENT_DEFICIT_SCHEDULER` **in addition to** bounded-bulk/focus flags,
HELLO `experimental_deficit:true` **in addition to** PTY/focus opt-ins, and ACK
`experimental.deficit`. Native `SharedConnection.Options.experimental_deficit`
requires explicit `experimental_focus`; missing capability disconnects rather
than silently reverting to weighted visits. Python `PtyClient.start(focus=True,
deficit=True)` follows the same rule. Existing ordinary and weighted-focus
connections are unchanged, even when target deficit flag is present.

`FOCUS_UPDATE` fields, nonce/sequence checks, grouping and ownership are unchanged.
Outer selected session gets four 16,406-byte wire quanta versus other sessions
and aggregate bulk class one; selected pane gets four versus sibling leaves one.
Known next frame size determines eligibility, actual queued header+payload bytes
determine charge. Terminal/error eligibility uses a conservative size bound but
charges actual emitted bytes. A PTY selection emits one DATA frame within its
existing credit/data/batch limits. Immediate control frames are not deficit-charged.

Deficits reset for unready/zero-credit leaves and wholly unready groups. Focus
updates preserve cursors and never grant budget; positive residuals clamp to one
base quantum or the observed next indivisible frame size. The latter exception
prevents large metadata starvation under focus churn. Frame size and existing
metadata-alone batch exception stay unchanged; a failed whole-frame fit retains
retry precedence across focus changes until enqueue or slot release. Fixed
16-slot state, bounded virtual-round searches and 64 successful selections per
call do not establish wall-time QoS or sustained flood/scale behavior.

Use `--focus-scheduler --deficit-scheduler` in the benchmark, with all three
target flags. Result `deficit_scheduler` must exactly match explicit request.
See [DRR experiment](../benchmarks/agent-pty/2026-10-19-deficit-scheduler.md) for
byte-accounting, unequal-frame tests and matched comparisons. This does not add
Lua/GUI routing, live regrouping, new job slots or a separate priority transport.

### Explicit separate-bulk topology probe

`--separate-bulk --backend shared --bulk fs|exec|mixed` keeps all PTYs on their
existing shared connection but gives checked filesystem/exec interference its own
prepared connection to **another instance of the same agent** via the same
connector argv. No HostManager routing, pane default, new protocol, handler or
priority control lane is introduced. Focus stays on the PTY connection only;
the bulk agent uses ordinary fs/exec negotiation, not experimental PTYs/focus.
Both agents see the same inherited target environment; bounded-bulk flags remain
inactive on a connection that did not negotiate experimental PTYs.

The benchmark already warms one complete checked operation of each selected kind
before load for both placements. Separate startup/HELLO therefore does not enter
foreground echo/output measurements, though it remains a real deployment cost.
One owner loop still services foreground first and bounded background/bulk work;
separation does not create a dedicated client bulk-consumer thread.

Result `separate_bulk:true` and `bulk_lane:"separate_agent"` must match explicit
configuration. Without the option, shared placement and its existing admission
rules stay unchanged. Inactive bulk and non-shared backends reject this option
rather than silently ignoring it. Separate mode allows 16 PTYs **plus** bulk on
the other connection, not more than 16 jobs per connection; compare at equal
PTY count for performance. No extra connection is created for `--bulk off`.
Both pending bulk operations are abandoned and their independently owned
connection destroyed at teardown; no fallback to the PTY connection is attempted.

This is a **two-process/two-transport experiment**, not same-agent dual lanes.
It changes process scheduling, resources and failure boundaries along with
head-of-line contention. It cannot isolate which factor caused a difference.
Remote runs require an already prepared connector that supports concurrent
connections to the intended target and an explicit prepared zero fixture path;
the benchmark does not deploy agents or attest target identity. CPU/RSS,
transport establishment, remote reconnect and fault containment need independent
qualification. Report background/bulk rates alongside foreground improvement.

### Per-focus diagnostics and loaded refresh probe

On a negotiated focus connection, existing target-side
`HOLLOW_AGENT_QUEUE_PROFILE` additionally emits **`AGENT_FOCUS_PROFILE`** JSON on
stderr before each PTY terminal response. Native callers must drain stderr
(`--telemetry` in the benchmark); remote launchers must set the flag explicitly
on the target. No new wire frames, production telemetry or default scheduler
selection is introduced. Aggregate `AGENT_QUEUE_PROFILE` schema stays unchanged.

Each snapshot contains absolute `queued_wire_bytes`, `written_wire_bytes`,
`discarded_wire_bytes` and `consumed_wire_bytes` (written plus discarded), plus
`focus` schema 1: `capacity:64`, `accepted`, `dropped` and retained `events`.
This is fixed storage, **not a ring**: after the first 64 accepted updates,
additional timing records are dropped, never wire bytes. Accepted sequence count
still advances; new output is never attributed to an older retained focus.
Snapshots repeat connection history, so do not sum records from multiple PTY
terminal snapshots as independent samples.

Events identify accepted `sequence`, logical `group` and output `stream`, using
agent-local CLOCK_MONOTONIC nanoseconds:

* `dispatch_ns`: explicit metadata accepted/applied, not ACK receipt.
* `ready_ns`: first observation after dispatch of **captured target PTY bytes plus
  positive credit**. If already buffered/credited at dispatch, it equals dispatch
  time. Not kernel readiness, child output creation or newly echoed input.
* `enqueue_ns`: first matching **newly queued** DATA frame after dispatch. Already
  queued target DATA cannot satisfy it. It may still contain captured older child
  output; no prompt-token causal identity is asserted.
* `payload_begin`/`payload_end`: absolute wire-byte interval for that DATA payload,
  excluding its header. Positions survive output compaction and diagnostic span
  overflow; they are not PTY payload byte offsets.
* `first_write_ns`/`complete_write_ns`: successful stdout writes intersecting first
  payload byte / covering final byte of that **one frame**, respectively. A
  header-only write cannot mark payload progress. These end at agent stdout, not
  connector delivery, client consumption, parsing, rendering or visible echo.

Nullable timestamps preserve incomplete observations. `stop` is null for pending
or completed records, `superseded` for an unqueued target replaced by newer focus,
`released` for an unqueued terminated target, `no_stream` for clear/session-only
selection, or `discarded` for connection-discarded incomplete output. An enqueued
record remains write-tracked after later focus changes. Its pending fields are
not completed just because a terminal snapshot was emitted; serialization occurs
before that terminal frame is queued. Rejected/stale updates create no accepted
event. No raw payload, paths or argv are included in these diagnostic records.

`--focus-every N` adds an explicitly different workload: refresh **the same target**
before each Nth prompt, including warmups, and wait for its ACK while servicing
backgrounds/bulk. Result `focus_refreshes` retains sequence, warmup-inclusive
`before_prompt_index` and client-side `ack_ns`; initial pre-load ACK stays in
`focus_ack_ns`. Refresh waits are **outside** input-to-echo timing, so report both.
The update itself truncates residual scheduler quota; compare identical refresh
workloads with profiling off/on instead of treating it as invisible instrumentation.
It is not cross-pane/session switching or GUI focus wiring. Output workloads have
only the initial pre-load update. Parser checks accepted counts, sequence order,
timestamp/position bounds and censoring without filling missing timings.

```sh
HOLLOW_AGENT_BOUNDED_BULK=1 HOLLOW_AGENT_FOCUS_SCHEDULER=1 \
HOLLOW_AGENT_QUEUE_PROFILE=1 python3 scripts/agent_pty_bench.py \
  --telemetry --focus-scheduler --focus-every 32 --backend shared \
  --sessions 8 --load noisy stalled --bulk off mixed --resize-every 16 \
  --runs 3 --samples 1000 --size-mib 10 --output focus-profile-research.jsonl
```

Subtract timestamps only within the agent clock (or separately client ACK RTTs);
correlate clocks by sequence, not by subtracting client and agent absolute values.
`ready_ns → enqueue_ns` bounds observed captured/credited waiting in this loop,
not all stream scheduling delay. Per-stream sustained QoS, genuine loaded target
switches, byte-fair DRR and split-lane alternatives remain separate experiments.

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

An independent server-side `HOLLOW_AGENT_BOUNDED_BULK` research flag additionally
rotates completed fs/exec frames with PTY output quanta on experimental-PTY
connections. It adds no wire messages, capabilities, HostManager selection or
GUI focus policy, and is ignored without experimental PTY HELLO. Whole metadata
frames may exceed the ~64 KiB soft batch cap only as an empty-buffer atomic
exception; negotiated payload and global limits still apply. See
[benchmark methodology](host-agent-benchmarks.md#opt-in-bounded-bulk-scheduling).
This flag is not a pane/shared-backend rollout switch.

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
