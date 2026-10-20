# Agent PTY multiplexing plan

Status: implementation started with an opt-in, headless `hollow-agent mux` mode. Dedicated `pty`, RPC `stdio`, and GUI backend defaults remain unchanged. See [current wire contract, limits, tests, and A/B benchmark](agent-mux.md). GUI connection sharing and performance qualification remain outstanding.

## Goal

Allow multiple Hollow panes on the same host to share one connector process and one agent connection, reducing process count and repeated startup overhead without materially degrading interactive latency or throughput.

Performance parity is a release gate, not an assumption. Retain the dedicated-connection backend until shared mode passes comparative measurements.

## Scope

Included:

- Multiple independent PTYs over one framed connection.
- Connection reuse for equivalent effective host identities.
- Bounded buffering, per-stream backpressure, and fair scheduling.
- Independent pane spawn, input, resize, close, and exit handling.
- Explicit connection-wide failure handling and opt-in rollout.

Not included in the first version:

- Persistent sessions, detach/reattach, or automatic shell restoration.
- Multiple clients attaching to the same terminal.
- Agent ownership of workspaces, tabs, split layouts, or terminal VT state.
- Sharing the terminal transport with filesystem or exec operations.
- Transparent migration of running panes between connections.

## Current implementation

- `src/pty/agent.zig` owns a dedicated connector and session for each agent-backed pane.
- `src/agent/pty.zig` serves one PTY using a poll loop and synchronous framed output writes.
- `src/agent/mux.zig` adds a separate nonblocking multi-PTY poll loop; `src/agent/mux_protocol.zig` defines experimental negotiation, limits, and credit handling. Spawn preparation is shared with dedicated mode but runs after fork in mux mode.
- `src/agent/pty_read_pool.zig` adds a fixed-size read-worker experiment, selected only with `HOLLOW_MUX_READ_WORKERS=1..4`; zero/default retains inline reads. All transport, credits, and lifecycle remain owner-thread responsibilities. A sole remaining stream uses inline reads only after all jobs/results drain, avoiding single-pane handoff loss in local measurements. Multi-pane parity and broader qualification remain outstanding, so the pool stays opt-in.
- `HOLLOW_MUX_READ_BATCH_JOBS=2` optionally rotates two credit-reserved PTYs within a worker's existing 64 KiB buffer and bounded turn; default 1 retains single-job A/B mode. Local multi-pane throughput improves substantially, with a small observed loaded-latency tradeoff. Dedicated/GUI defaults and qualification gates remain unchanged.
- Focus-first read turns now alternate with background byte DRR without advancing its cursor. `scripts/agent_mux.py --workload mixed` measures actual focused echoes under sustained floods and verifies every background stream progresses. Local tail latency improved substantially; supported-connector qualification and numerical release budgets remain outstanding.
- `src/agent/pty_protocol.zig` has a binary frame header containing kind, stream ID, and payload length. The current implementation uses one fixed stream.
- Spawn metadata is JSON; terminal input and output are raw byte payloads inside binary frames.
- Dedicated `pty` mode modifies its process environment while preparing its sole spawn; `mux` prepares each spawn in the child so the shared agent environment stays isolated.
- `src/app/pty_budget.zig` provides GUI-side parsing budgets. Transport scheduling must complement those budgets, not replace them.

## Target architecture

```text
Hollow pane handles
        |
Shared host connection owner
        |
One connector / framed transport
        |
hollow-agent multi-PTY event loop
        +-- stream A -> PTY A
        +-- stream B -> PTY B
        +-- stream C -> PTY C
```

Keep the pane-facing PTY interface and local VT/rendering ownership unchanged. Introduce a shared connection owner behind that interface; each pane owns a stream handle rather than the connector itself.

Pool by effective host identity: connector executable and arguments, target/user, relevant environment, and agent/protocol compatibility. Reuse existing host normalization where appropriate, but do not treat workspace discovery connections as terminal transports. Never pool distinct users or targets by display name alone.

The connection owner manages transport I/O, stream dispatch, bounded queues, bootstrap, and shutdown. Pane closure releases only that stream. Define a bounded idle lifetime for connections with no streams; application shutdown closes all owned connections.

## Protocol and scheduling requirements

### Stream lifecycle

- Negotiate a protocol version and multiplexing capability before using shared mode.
- Define connection-level messages separately from stream-level messages.
- Support spawn confirmation or failure, input, output, resize, close, and final exit status per stream.
- Reject duplicate/invalid stream IDs and prevent late frames from reaching a newly allocated pane. Avoid ID reuse within a connection where possible.
- Preserve input/output byte order within each stream. Deliver exit only after preceding output has been delivered, except under an explicitly documented abort policy.
- Distinguish recoverable stream errors from framing errors that invalidate the connection.
- Enforce payload, stream-count, queue, and connection-wide memory limits before allocation or enqueueing.

### Backpressure

- Use per-stream byte windows or an equivalent explicitly bounded flow-control mechanism in both directions.
- Return credits in batches as queue capacity becomes available; do not require round trips or acknowledgments for individual output frames.
- When a pane stops consuming, stop reading its PTY once its allowance is exhausted. Continue serving other PTYs and connection control traffic.
- When a child stops reading input, throttle only that stream's input. A large paste must not stall other streams.
- Reserve bounded capacity for control messages so exhausted data windows cannot prevent close, exit, or credit updates.
- Do not discard terminal bytes to satisfy memory limits. Backpressure the producer or fail the affected stream explicitly.

### Fairness and latency

- Use byte-based scheduling, initially weighted deficit round robin or a similarly simple bounded scheduler.
- Prioritize focused panes while guaranteeing progress for visible and background panes.
- Bound frame sizes and work per scheduling turn; a bulk stream must not monopolize the wire or event loop.
- Prioritize input and control traffic without violating per-stream ordering. Coalesce redundant pending resize/focus updates where safe.
- Do not wait for a batching timer before sending interactive traffic. Bound bulk batching by bytes and elapsed time.
- Keep transport writes nonblocking and handle partial writes. Once a frame begins, finish it before interleaving another frame.
- A shared ordered transport still has head-of-line blocking for already queued bytes. Limit queue depth and measure this residual cost; priority cannot bypass bytes already written.

## Spawn and failure isolation

- Build each child's environment, cwd, argv, and shell-integration settings independently. Do not mutate the long-lived agent's environment for individual spawns.
- Keep spawn preparation from blocking service of existing streams; measure shell-integration setup and other filesystem work.
- Ensure PTY children do not inherit unrelated PTY masters, transport descriptors, or agent control descriptors.
- A failed spawn, child crash, or stream close must leave other streams running.
- Close uses bounded deadlines and process-group termination/reaping; shutdown must not wait indefinitely on blocked writes.
- A connector or agent failure affects all streams on that connection. Report affected panes clearly; never silently respawn shells or replay input.
- Retry a connection for future spawns only under an explicit policy. Do not reinterpret a possibly successful spawn as safe to repeat.

## Implementation phases

### 1. Establish the baseline

- [x] Add a repeatable benchmark harness for the existing dedicated backend (`scripts/agent_mux.py`, also compares opt-in mux).
- [ ] Record single-pane and multi-pane throughput, input-to-echo p50/p95/p99, spawn latency, CPU, RSS, process/thread count, and queue high-water marks.
- [ ] Separate transport-only results from end-to-end Hollow parsing/rendering results.
- [ ] Record platform, build mode, host identity, terminal size, workload, warm/cold agent state, and network conditions.
- [ ] Repeat runs to establish noise; agree numerical regression limits before implementation results are evaluated.

Exit criterion: reproducible baseline and documented release budgets.

### 2. Specify and test the protocol

- [ ] Define negotiation, stream lifecycle, window updates, priority hints, error scope, and limits.
- [ ] Specify behavior for malformed, fragmented, oversized, unknown-stream, and late frames.
- [ ] Add protocol and scheduler tests, including ordering and memory bounds.
- [ ] Define compatibility behavior without changing existing dedicated mode.

Exit criterion: reviewed wire contract and deterministic tests for lifecycle and flow control.

### 3. Implement the multi-PTY agent

- [ ] Extract reusable PTY spawn/lifecycle code from the single-PTY implementation.
- [x] Add a stream table and nonblocking multi-PTY event loop without thread-per-pane growth.
- [x] Implement isolated child spawn state and descriptor hygiene.
- [ ] Add bounded input/output queues, credit accounting, fair scheduling, and reliable reaping.
- [x] Exercise shared mode with a headless client before GUI integration (`test-agent-mux`; broader qualification remains pending).

Exit criterion: stream isolation, bounded memory, and transport-level benchmark parity.

### 4. Integrate Hollow connection sharing

- [ ] Add a shared terminal connection owner and effective-host connection pool.
- [ ] Adapt pane PTY handles to independent streams while retaining dedicated mode.
- [ ] Support concurrent bootstrap requests, cancellation, and pane closure during deployment/spawn.
- [ ] Connect focus/visibility hints to transport scheduling.
- [ ] Define last-stream cleanup, idle expiry, connection failure fan-out, and application teardown.
- [ ] Add opt-in shared mode and diagnostic counters; leave production defaults unchanged.

Exit criterion: headless pane integration and GUI lifecycle tests pass without blocking the GUI thread.

### 5. Qualify and roll out

- [ ] Compare dedicated and shared mode on WSL, SSH, and supported container connectors.
- [ ] Validate supported guest architectures and connector teardown behavior.
- [ ] Run sustained-load and fault-injection tests.
- [ ] Publish comparative results and identify any platform-specific regressions.
- [ ] Change defaults only after release gates pass; retain an explicit dedicated-mode escape hatch.

Exit criterion: agreed performance budgets and correctness gates pass on supported targets.

## Benchmark and correctness matrix

Run with 1, 4, 16, and 32 panes where supported. Include local Linux transport as a diagnostic baseline and actual WSL/SSH/container paths for qualification.

| Scenario | Required behavior |
| --- | --- |
| Single-pane bulk output | No material throughput or CPU regression against dedicated mode |
| Idle panes plus one interactive pane | No material p95/p99 input latency regression |
| One or many output floods plus focused typing | Responsive focused pane; background streams continue progressing |
| Stopped consumer | Bounded memory; unrelated streams remain responsive |
| Large paste into a blocked child | Input throttles per stream; control and other panes keep working |
| Rapid focus, resize, spawn, and close | Correct routing and final size; no starvation or stale-handle delivery |
| Distinct cwd/env/shell settings | No cross-pane state leakage |
| Child exit with final output | Correct output ordering and exit status |
| Connector loss or stalled transport | Bounded shutdown; explicit failure for affected streams |
| Spawn cancellation and agent failure | No orphaned processes, leaked descriptors, or duplicate shells |
| Long sustained traffic | Stable bounded queues and memory; no starvation |

Use deterministic scheduler/flow-control tests for fairness guarantees; use performance runs for observed latency and throughput. Measure actual input-to-echo latency under load, not only sender enqueue time.

## Decision gates

Before implementation, settle:

1. Initial per-stream windows, frame size, total queue budget, and stream-count limit, informed by baseline measurements.
2. Exact host-pool identity and idle-connection lifetime.
3. Numerical throughput, p95/p99 latency, CPU, and memory regression budgets.
4. Version/capability compatibility and explicit backend selection behavior.

If shared mode misses those budgets, profile and tune before enabling it by default. If shared-transport contention remains unacceptable on a target, retain dedicated connections there or evaluate a small number of connection shards as a separate, measured follow-up.
