# Experimental agent mux

`hollow-agent mux` serves independent PTYs over one stdin/stdout connection.
It is a separate, opt-in mode: `hollow-agent pty` still serves one dedicated
PTY, and `hollow-agent stdio` still serves filesystem/exec RPC. Neither GUI
backend selection nor production defaults change.

This is the headless agent slice of [the multiplexing plan](agent-multiplexing-plan.md),
not completed GUI connection sharing or a performance-qualified release.

## Build, test, compare

```sh
zig build --build-file build-agent.zig agent -Doptimize=ReleaseFast
zig build --build-file build-agent.zig test-agent-mux test-agent-loop test-agent-pty
python3 scripts/agent_mux.py --mode both --panes 1 4 16 32 --runs 3 --build-mode ReleaseFast
```

Use `--mode pty` or `--mode mux` to measure one backend independently. The
same binary contains both. Output is JSON Lines; redirect it to retain runs.
The benchmark uses identical raw-mode Python children and 80x24 PTYs. It
records cold startup, per-child readiness latency, actual input-to-echo
p50/p95/p99, aggregate bulk throughput, live agent RSS/thread/process counts,
agent-tree CPU, and Python client CPU. Modes alternate order across repeats.
The client services dedicated connections round robin rather than draining
one pane to completion first.

These are **local Linux transport-only diagnostics**, including the Python
driver's framing/credit overhead, not GUI rendering or remote connector
qualification. Echo is measured before bulk traffic, not under output floods.
Agent RSS is a live snapshot, not peak RSS or total shell-tree RSS. CPU covers
startup, echo, bulk, and teardown, not bulk alone. Use `--build-mode` to record
the build mode (it is not autodetected);
OS caches and external host load are uncontrolled. Full peak-memory and
connection-wide queue accounting, mixed-load echo latency, warm shared-connection spawn measurements, remote
paths, and agreed numerical release budgets remain outstanding. No parity
claim follows from these measurements.

### Initial diagnostic measurements

October 19, 2026, x86_64 Linux musl `ReleaseFast`, local WSL2 Linux
6.18.54.1 transport, Python 3 driver, 8 MiB bulk per pane, 25 echo samples per
pane, three cold-agent runs. Values below are medians across runs; echo is
idle, not measured under bulk load. OS cache state was uncontrolled.

| Panes | Dedicated MiB/s | Mux MiB/s | Dedicated echo p99 ms | Mux echo p99 ms |
| --- | ---: | ---: | ---: | ---: |
| 1 | 76.0 | 72.8 | 0.287 | 0.278 |
| 4 | 294.6 | 80.7 | 0.299 | 0.285 |
| 16 | 434.3 | 83.3 | 0.339 | 0.320 |
| 32 | 309.4 | 83.3 | 0.333 | 0.384 |

**Multi-pane bulk parity is not met.** These numbers include client-side
framing and credit traffic and do not isolate the bottleneck. Profile before
tuning or changing any defaults. Reproduce with the commands above; raw
session results were saved at `/tmp/opencode/hollow-agent-mux-benchmark.jsonl`
(local artifact, not a repository fixture).

### Throughput investigation

On the same WSL2 target, opt-in `HOLLOW_MUX_DIAGNOSTICS=1` reports counts,
queue high-water marks, syscall elapsed time, and agent-only user/system CPU
on stderr at shutdown. The benchmark includes those counters in its JSON when
enabled. Diagnostics add timing overhead; normal runs omit those timing calls.

```sh
HOLLOW_MUX_DIAGNOSTICS=1 python3 scripts/agent_mux.py --mode mux --panes 4 \
  --bytes 33554432 --samples 1 --runs 3 --build-mode ReleaseFast
python3 scripts/agent_pty_read_bench.py --panes 4 16 32 --workers 1 2 4 --runs 3
```

Findings:

- Original loop alternated a PTY read turn with a transport write turn. A
  128 MiB/four-pane run needed approximately 58,000 polls and 29,000 writes.
- Immediate output batching cuts those to approximately 16,500 polls and
  8,300 writes **without increasing the 16,393-byte staging bound**, changing
  windows, or waiting for a batching timer. Each turn permits at most 32 read
  attempts and checks a 250-microsecond budget between reads, stopping earlier
  when nothing is ready. A syscall itself cannot be preempted by that budget.
- The Python client originally returned credit for every output frame. It now
  batches at half a window (32 KiB); `--credit-batch 1` restores the previous
  policy for comparisons. Updates fell from approximately 30,000 to 3,600
  for 128 MiB. Batching credits saves client CPU, but alone does not remove
  the throughput ceiling.
- With both changes, approximately **1.14 seconds of a 1.38-second run** was
  inside PTY `read()` calls. Agent-only CPU was approximately 1.14 seconds
  system and 0.03 seconds user. User-only `perf` sampling cannot explain that
  kernel time; syscall timing and the raw control experiment localize it.
- An unframed, single-reader PTY drain also tops out near 100–114 MiB/s on
  this target. This reproduces most of the ceiling without Hollow, frame
  parsing, credit traffic, or the shared output pipe. Dedicated agents can
  execute their PTY reads concurrently; this mux owner serializes them.

Controlled ablation, four panes × 32 MiB, three runs, same updated Python
driver and dedicated before/after agent binaries (median):

| Agent output batching | Client credit batching | MiB/s | Client CPU seconds |
| --- | --- | ---: | ---: |
| No | No | 82.0 | 0.714 |
| No | Yes | 82.3 | 0.589 |
| Yes | No | 93.6 | 0.432 |
| Yes | Yes | 92.3 | 0.363 |

Raw diagnostic drain, 8 MiB per pane, three runs (median MiB/s):

| Panes | One reader | Two fixed readers | Four fixed readers |
| --- | ---: | ---: | ---: |
| 4 | 100.0 | 224.2 | 182.0 |
| 16 | 112.5 | 274.1 | 275.4 |
| 32 | 114.3 | 292.9 | 298.4 |

Raw workers discard bytes after counting them. These are **not mux throughput
or latency results**: no shared writer, per-stream windows, fairness, or
transport queue is exercised. They identify a bounded two-reader-pool
prototype as a promising next experiment, not proof of parity or a decision
to add thread-per-pane growth. Such a prototype must retain a single transport
owner, explicit descriptor ownership/cancellation, bounded credits/queues, and
the existing correctness and latency gates. An explicitly selected prototype
is now implemented; see the Tern comparison and reader-pool experiment below.

Post-batching end-to-end transport diagnostic, original 8 MiB / 25 idle echo
sample / three-run workload (median):

| Panes | Dedicated MiB/s | Mux MiB/s | Dedicated echo p99 ms | Mux echo p99 ms |
| --- | ---: | ---: | ---: | ---: |
| 1 | 73.0 | 70.3 | 0.253 | 0.259 |
| 4 | 289.0 | 87.9 | 0.351 | 0.310 |
| 16 | 363.4 | 87.8 | 0.392 | 0.356 |
| 32 | 300.3 | 90.0 | 0.381 | 0.350 |

The large multi-pane gap remains. Host variation is visible in dedicated
results; the controlled ablation is stronger evidence for the batching effect
than comparing separate full runs. Raw local artifacts:
`/tmp/opencode/hollow-mux-ablation.jsonl`,
`/tmp/opencode/hollow-pty-reader-scaling.jsonl`, and
`/tmp/opencode/hollow-agent-mux-after.jsonl`.

### Tern binary comparison and fixed reader pool

The user supplied `$HOME/tern/tern`: Tern 0.9.4 (`b9ef74c`), stripped x86_64
dynamic ELF, build ID `d5dbdffb5357b5275cb4270293acc4a61d89d826`.
Investigation used an executable copy, an isolated configuration/socket under
`/tmp/opencode`, and a temporary `LD_PRELOAD` observer. The original binary and
the user's running/default Tern state were not modified. No Tern code is used
by Hollow or required by tests.

Observed, rather than inferred from imported symbol names:

- A `term-pty-poller` thread plus multiple PTY read threads in the same daemon.
- Four masters (FDs 27–30) read by four different thread IDs during concurrent
  output. Read calls start with a 65,536-byte allowance and fill successive
  buffer positions; descriptors have `O_NONBLOCK` set.
- Each master delivered all 32 MiB from its child. Aggregate producer-completion
  throughput was approximately 326 MiB/s (one child: approximately 96 MiB/s).
  **This is a daemon-drain observation, not an equivalent Hollow transport
  benchmark:** no raw byte-for-byte subscribed client, GUI, or network path was
  measured, and the daemon's state representation differs from Hollow's.
- The trace establishes parallel PTY reads, not a proven worker-count bound or
  Tern's full scheduling/backpressure design. Those cannot be concluded from
  this sample or from strings in a stripped binary.

Local observer source/log: `/tmp/opencode/tern-probe.c` and
`/tmp/opencode/tern-probe-p_52ubzq/probe.log`. Observations support offloading
reads; they do not prove that multiplexing must use one thread per pane.

Hollow's prototype lives in `src/agent/pty_read_pool.zig`. Select it explicitly:

```sh
# Inline reference (also the default).
HOLLOW_MUX_READ_WORKERS=0 python3 scripts/agent_mux.py --mode mux --build-mode ReleaseFast
# Fixed pool, still one connector and one transport/lifecycle owner.
HOLLOW_MUX_READ_WORKERS=4 python3 scripts/agent_mux.py --mode mux --build-mode ReleaseFast
```

Accepted worker counts are 0–4. Nonzero counts add exactly that many reader
threads, independent of pane count. The default remains **0** because the
prototype is not performance-qualified. `pty` and `stdio` ignore this setting.
The benchmark records the selected count; `test-agent-mux` runs its full suite
with 0, 2, and 4 readers.

Ownership and bounds:

- The owner alone parses frames, dispatches output, owns credit accounting,
  spawns/reaps children, and closes streams. Workers receive no stream pointers.
- Before dispatch the owner reserves output credit. One job at a time may read
  a stream; unused reservation returns on completion. Credit updates cannot
  acknowledge bytes that have not been staged for delivery.
- A worker owns a close-on-exec duplicate of its master, closing it before
  publishing a result. Closing a pane cannot recycle that descriptor underneath
  a read. A slot cannot be freed/reused until its read job has been collected
  and its result staged or explicitly aborted.
- Jobs have a 32 KiB byte quantum (64 KiB focused), capped by the stream's
  existing 64 KiB window. Unused quantum is discarded. Each job performs at
  most 32 nonblocking read attempts, checking a 750-microsecond budget between
  calls, with no wait to fill the result. The owner continues input/control
  service while reads run.
- The fixed pool has capacity for four 64 KiB result buffers, allocated only
  when enabled; only the selected workers can hold results. Live read
  reservations are bounded by `workers × 64 KiB`. Staging stays 16,393 bytes,
  wire data frames stay at most 16 KiB, and the control queue stays 64 KiB.
- Ready results rotate between workers for transport delivery; one stream's
  result order is preserved. Worker wake/completion eventfds are bounded and
  close-on-exec. Application teardown stops/joins readers before releasing
  stream state; workers never perform transport writes.

Same-driver comparison, local WSL2, ReleaseFast, 8 MiB per pane, 25 idle echo
samples per pane, three runs with variant order reversed on alternating runs
(median MiB/s):

| Panes | Dedicated | Inline mux | 2 readers | 4 readers |
| --- | ---: | ---: | ---: | ---: |
| 1 | 75.8 | 79.9 | 63.6 | 63.2 |
| 4 | 278.9 | 88.9 | 130.8 | 212.8 |
| 16 | 365.7 | 91.5 | 127.8 | 235.5 |
| 32 | 329.3 | 89.1 | 126.5 | 238.8 |

At 32 panes, dedicated agents had 32 threads versus 5 for four-reader mux.
Idle echo p99 medians were 0.337 ms dedicated, 0.349 ms inline, and 0.470 ms
with four readers. **Single-pane throughput regresses with worker handoff;
multi-pane parity is still not met.** These are idle echo measurements, not
mixed-load latency qualification. No default changes follow from this table.
Full data: `/tmp/opencode/hollow-mux-pool-comparison.jsonl`.

## Experimental v1 wire contract

The frame envelope matches dedicated PTY's nine-byte layout:
`kind:u8, stream:u32 LE, payload_length:u32 LE`, followed by payload bytes.
Semantics and negotiation are separate. A dedicated client must not silently
switch to mux or fall back after a possibly successful spawn.

Agent sends kind 1 (`hello`) on stream 0 with JSON identifying protocol
`hollow-mux`, version `1`, capabilities `multi-pty` and `windows`, and limits.
Client must respond with kind 9 on stream 0:

```json
{"protocol":"hollow-mux","version":1}
```

Whitespace/key order do not matter. Unknown JSON fields are ignored. Version
or protocol mismatch, duplicate negotiation, and non-negotiation traffic
before the reply invalidate the connection. Negotiation has a 10-second deadline.

| Kind | Direction | Stream | Payload |
| --- | --- | --- | --- |
| 1 hello | agent → client | 0 | Protocol/version/capability/limit JSON |
| 9 negotiate | client → agent | 0 | Protocol/version JSON, at most 128 bytes |
| 2 spawn | client → agent | nonzero | Existing PTY `Spawn` JSON, at most 64 KiB |
| 10 spawned | agent → client | nonzero | Initial input credit, u32 LE |
| 3 input | client → agent | nonzero | Raw bytes, at most 16 KiB |
| 4 output | agent → client | nonzero | Raw bytes, at most 16 KiB |
| 5 resize | client → agent | nonzero | Nonzero columns:u16 LE, rows:u16 LE |
| 8 close | client → agent | nonzero | Empty; explicit stream abort |
| 6 exit | agent → client | nonzero | Exit code:u32 LE; signal exits use 128 + signal |
| 7 error | agent → client | nonzero | UTF-8 diagnostic error name |
| 11 credit | either direction | nonzero | Additional byte credit:u32 LE |
| 12 focus | client → agent | nonzero | Empty; select this stream for doubled byte quantum |

Spawn IDs must strictly increase, including failed spawns. Never reuse an ID;
start another connection before u32 exhaustion. Zero is connection-only.
Late frames for retired/closing streams are ignored; future unknown IDs,
duplicate IDs, unknown kinds, invalid payloads, and window violations invalidate
the connection. Fragmented/coalesced frames are supported. Header-specific
payload limits are checked before waiting for or allocating the full payload.

`spawned` follows close-on-exec pipe confirmation, before PTY output. Spawn
parse/validation, stream-limit, setup, and exec failures report stream `error`;
a failed spawn has no subsequent `exit`. Once spawned, child exit reports
`exit` after all preceding PTY output. A PTY input-write failure reports an
`error`, aborts the stream, then reports `exit`; it does not stop other streams.
An early close racing spawn may produce only `exit`, without `spawned`.
Spawn preparation has a 10-second deadline, followed by the close grace period.

### Bounds and scheduling

Initial constants are experimental, not baseline-derived release decisions:

- 32 concurrent streams per connection.
- 64 KiB input and output byte windows per stream.
- 16 KiB maximum data frame; 64 KiB maximum spawn metadata.
- At most 2 MiB logical pending PTY input across all streams.
- One staged transport buffer, at most 16 KiB + 9 bytes, containing complete
  frames; no per-stream output queue.
- Separate 64 KiB logical control queue, not charged against data windows.
- With explicitly enabled read workers, the fixed additional result capacity
  and credit reservations described above; inline mode allocates none of it.
- Incremental parser storage bounded by spawn metadata plus read/compaction slack.

Allocator capacity slack, JSON parsing, fixed stream state, kernel buffers, and
child processes are additional to those logical payload limits. Stream and
metadata limits bound them; the limits are not a total RSS ceiling.

Output starts with 64 KiB implicit credit when spawn is accepted. Client must
not send input before `spawned` grants its initial input credit. Credits return
as input is written to the PTY or output is consumed by the client. Clients may
batch updates; no individual-frame acknowledgments are required. A grant must
be positive and cannot raise available credit above 64 KiB. Zero output credit
removes that PTY from read polling, without blocking other streams or control
traffic. A blocked input consumer fills only its own input window.

Byte deficit round robin uses a 16 KiB quantum, doubled for the focused stream.
The optional reader pool instead assigns bounded 32/64 KiB byte read jobs and
rotates their ready results; it is not yet a qualified replacement for the
inline scheduler's latency behavior.
Ready output frames share that fixed staging bound, with at most 32 read
attempts and a 250-microsecond budget checked between reads; there is no wait
to fill it. Non-ready
streams discard unused deficit. Input/control are serviced before the next
output batch; complete pending control frames are batched by bytes, not a timer.
All transport writes are nonblocking and resume partial buffers without
interleaving. Already-written shared-transport bytes still cause head-of-line
blocking. GUI visibility hints and broader priority policy are not integrated.

### Lifecycle and failure policy

Environment, path conversion, shell integration, cwd, and argv preparation run
in each forked child, not the owner. Only PTY stdio and a close-on-exec status
pipe survive into preparation; the pipe closes on successful exec. Descriptor
cleanup currently requires Linux `close_range` (Linux 5.9+); unsupported kernels
fail that spawn explicitly. Shared agent filesystem/exec RPC is not involved.

Closing aborts pending input and unread output for that stream. Already staged
output frames complete before exit. Send SIGHUP to the child process
group, then SIGKILL after 1.5 seconds if necessary. Explicit abort is the
exception to normal final-output delivery. Other panes continue running.
Exited child PIDs stay reserved until output drains, preventing stale process
group signals from targeting recycled PIDs.

Transport EOF, protocol error, SIGINT/SIGTERM, a full control queue, or a stalled
transport terminates this connection and all its streams. No input replay,
shell restoration, or automatic retry occurs. A pending transport write times
out after 10 seconds without progress; teardown does no transport writes and
has a bounded grace/reap deadline. As with other process-group based shutdown,
descendants that deliberately create a different session/process group are
outside that group's termination scope.

This headless mode stays alive with zero streams until its caller disconnects.
A GUI pool must supply effective-host identity, bounded idle expiry, concurrent
bootstrap/cancellation, failure fan-out, and application shutdown ownership.
