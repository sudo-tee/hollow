# Agent mux: development notes and measurements

For setup and everyday use, see [Sharing a connection between panes](agent-mux.md).
This document keeps the experiment history, including older implementations
and results that later sections supersede. It is a developer reference, not
the recommended setup guide.

`hollow-agent mux` serves independent PTYs over one stdin/stdout connection.
It is a separate, opt-in mode: `hollow-agent pty` still serves one dedicated
PTY, and `hollow-agent stdio` still serves filesystem/exec RPC. Dedicated remains
the GUI default; agent-backed domains can explicitly opt into shared transport.

This implements the headless agent and experimental config integration from
[the multiplexing plan](agent-multiplexing-plan.md), not a default rollout.

## Current status and latest measurements

For current Windows/WSL performance, use the
[October 21 same-binary head-to-head](windows-mux-cpu.md#current-mux-versus-dedicated-pty-head-to-head-october-21-2026).
Mux is a practical option for the measured four-pane workload: uncapped
throughput medians 41.27/42.08 MiB/s dedicated/mux, captured Windows-group CPU
1.251/1.232 cores at matched 10 MiB/s, and helper RSS 3.375/0.719 MiB. Four
echo pairs passed with p99 group medians 17.55/15.79 ms; occasional mux maxima
were higher. One capped pair was excluded for unmatched producer rate, leaving
three qualified capped pairs. The report preserves variation and exclusions;
it does not claim statistical equivalence, a universal speedup, or physical
keyboard-to-display latency. No full test suite was rerun for that report.

The GUI defaults to dedicated connections. Selecting `pty = { mode = "mux" }`
uses four persistent readers unless `read_workers` overrides it; direct agent
invocation without `HOLLOW_MUX_READ_WORKERS` still defaults to zero/inline.
`batch_jobs` / `HOLLOW_MUX_READ_BATCH_JOBS` are validated compatibility settings,
not active scheduling controls. Earlier per-job pool and batch-tuning sections
below describe superseded implementations, not recommended settings.

Windows client watchdog separation (`24f83ae`) and buffer-first frame parsing
(`59cc049`) are retained. Independent mux-versus-previous-mux CPU confirmation
and a separate diagnostic found substantially fewer small reads; current
head-to-head results, not historical pre-fix CPU penalties, should guide users.
See [Windows investigation](windows-mux-cpu.md) for rejected experiments too.

The focused-pane lifetime fix and measured ten-minute WSL GUI soak passed as
described below. Broader connectors/architectures, long-duration reliability,
and default rollout remain unqualified. Connection sharing does not implement
session persistence, detach/reattach, or crash recovery. Closing the last GUI
pane using a connection tears it down; filesystem/exec transports stay separate.

## Historical experiments

The sections below preserve measurements and conclusions at each checkpoint.
Statements that a fix was a candidate or a particular qualification was still
pending describe that checkpoint; the current status above supersedes them.

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
qualification. Default `--workload bulk` measures idle echo before bulk traffic;
`--workload mixed` measures focused echo under sustained output floods, as
described below (with flood counts and CPU, not the bulk mode's RSS snapshot).
Agent RSS is a live snapshot, not peak RSS or total shell-tree RSS. CPU covers
startup, echo, bulk, and teardown, not bulk alone. Use `--build-mode` to record
the build mode (it is not autodetected);
OS caches and external host load are uncontrolled. Full peak-memory and
connection-wide queue accounting, broader mixed-load qualification,
warm shared-connection spawn measurements, remote
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

Hollow's prototype lived in `src/agent/pty_read_pool.zig`; it has since been
replaced by persistent readers in `src/agent/pty_readers.zig` (see
[Persistent readers with reader-side transport flush](#persistent-readers-with-reader-side-transport-flush)).
The selection knobs are unchanged:

```sh
# Inline reference (also the default).
HOLLOW_MUX_READ_WORKERS=0 python3 scripts/agent_mux.py --mode mux --build-mode ReleaseFast
# Fixed pool, still one connector and one transport/lifecycle owner.
HOLLOW_MUX_READ_WORKERS=4 python3 scripts/agent_mux.py --mode mux --build-mode ReleaseFast
```

Accepted worker counts are 0–4. Nonzero counts add exactly that many reader
threads, independent of pane count. The default remains **0** because the
prototype is not performance-qualified. `pty` and `stdio` ignore this setting.
With a nonzero count, a sole stream now uses the inline fast path once all
worker jobs/results have drained. Threads remain allocated and parked; adding
another stream returns to pooled reads without changing wire or credit state.
The benchmark records the selected count and batch setting; `test-agent-mux`
runs its full suite with inline reads, 2/4 readers with single jobs, and 2/4
readers with paired jobs.

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
- Jobs have a 32 KiB byte quantum (up to 64 KiB focused), capped by the stream's
  existing 64 KiB window and remaining worker batch capacity. Unused quantum is
  discarded. Each worker batch performs at most 32 nonblocking read attempts,
  checking a 750-microsecond budget between
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
with four readers. **At this checkpoint, single-pane throughput regressed with worker handoff;
multi-pane parity is still not met.** These are idle echo measurements, not
mixed-load latency qualification. No default changes follow from this table.
Full data: `/tmp/opencode/hollow-mux-pool-comparison.jsonl`.

### Focused echo under sustained floods

The next investigation added `--workload mixed` to the same client. One raw-mode
child echoes single-byte keystrokes; all other children continuously write
64 KiB blocks. The client selects the echo stream as focused, drains for a
50 ms warmup, then sends one keystroke at a time with 5 ms between completed
echoes, while continuing to drain floods. Timing starts before input submission
and ends when the actual echo frame is consumed. Flood bytes are checked and
counted independently for every background stream; all must make progress.
Results exclude teardown, terminal parsing/rendering, and real connector paths.

```sh
HOLLOW_MUX_READ_WORKERS=4 python3 scripts/agent_mux.py \
  --workload mixed --panes 4 16 32 --samples 100 --runs 3 --build-mode ReleaseFast
```

The checkpoint's focus hint only doubled byte quantum: focused reads still
waited behind the background round-robin cursor. With 32 panes this produced
31.345 ms inline p99 despite sub-millisecond idle echo. Worker offload reduced
but did not eliminate that scheduling delay.

The scheduler now alternates a focus-first read turn with background byte DRR.
The priority turn does **not** advance the background cursor. Continuous focused
output cannot prevent background turns: with full byte quanta, all 31 background
streams are selected within 62 decisions, even if focus is always ready.
Partial focused reads do not consume background deficit. Existing per-turn
time/byte bounds, pool capacity, stream windows, and staging limits are unchanged.
This is read scheduling priority, not an ability to bypass already staged wire
bytes or in-flight read jobs. Ready worker results still rotate fairly.

Local WSL2 / ReleaseFast, three-run medians of 100-sample p99 input-to-echo
latency (milliseconds); variants reversed on alternating runs:

| Panes | Dedicated control, after | Inline before → after | 2 readers before → after | 4 readers before → after |
| --- | ---: | ---: | ---: | ---: |
| 4 | 0.790 | 11.146 → 0.793 | 1.261 → 0.994 | 0.803 → 0.846 |
| 16 | 5.177 | 19.240 → 0.967 | 3.279 → 0.811 | 3.547 → 0.791 |
| 32 | 3.983 | 31.345 → 0.887 | 6.147 → 1.087 | 8.365 → 0.890 |

Background throughput did not collapse to obtain those latencies. At 32 panes,
median aggregate flood throughput before/after was 88.0/89.4 MiB/s inline,
118.6/119.7 with two readers, and 186.3/222.2 with four readers. Dedicated
control measured 266.4/277.0 MiB/s. These are separate before/after passes, not
paired binaries, and throughput remains noisy; latency change is the strong
signal. A hundred samples and three runs do not qualify long-tail latency on
all supported connectors. Numerical release budgets remain undecided.

A follow-up with **1,000 echoes per run**, 32 panes, three runs, and the final
focus-first binary confirmed the improvement over longer local intervals:

| Backend | Median p50 / p95 / p99 (ms) | Worst individual echo (ms) | Median flood MiB/s |
| --- | ---: | ---: | ---: |
| Dedicated | 0.405 / 1.518 / 2.702 | 9.557 | 375.0 |
| Inline mux | 0.569 / 0.812 / 0.991 | 5.025 | 89.5 |
| Four-reader mux | 0.411 / 0.733 / 1.006 | 5.127 | 231.5 |

Every background stream progressed in every run; minimum bytes per background
stream across those runs were 56.2 MiB dedicated, 13.9 MiB inline, and 40.8 MiB
with four readers. Raw data: `/tmp/opencode/hollow-mux-mixed-longer.jsonl`.
The individual maxima also show why p99 near 1 ms is not a hard latency bound.

Raw local results: `/tmp/opencode/hollow-mux-mixed-before.jsonl` and
`/tmp/opencode/hollow-mux-mixed-focus-first.jsonl`. Functional benchmark smoke
coverage checks actual echoes and every flood's progress without asserting
machine-dependent latency thresholds. Deterministic scheduler tests assert
focus/background interleaving, full-round coverage, partial-read accounting,
and focus-only/idle behavior.

Two controlled follow-up ablations were **not retained**. Both used alternating
old/new binaries, three runs, 8 MiB/pane, and the focus-first scheduler:

- Increasing background read jobs from 32 to 64 KiB: two-reader throughput
  improved modestly (32 panes: 123.8 → 131.4 MiB/s), but four-reader results were
  inconsistent (16 panes: 243.0 → 233.1; 32 panes: 227.7 → 242.1). Mixed-load
  four-reader p99 rose slightly (1.079 → 1.187 ms). Kept smaller jobs.
- Borrowing masters with deferred close instead of duplicating each job's FD:
  most throughput results barely changed (32 panes, four readers:
  231.4 → 233.2 MiB/s; mixed flood: 230.5 → 230.6). Kept duplicated descriptors
  and their simpler cancellation/isolation contract; no broad measured benefit
  justified changing ownership.

Data: `/tmp/opencode/hollow-mux-pool-quantum-ablation.jsonl` and
`/tmp/opencode/hollow-mux-pool-descriptor-ablation.jsonl`. Subsequent work below
avoids the single-pane handoff; the multi-pane throughput gap remains unresolved.

### Worker phases, PTY read rotation, and the single-pane fast path

Opt-in diagnostics now include job phase timings, summed across workers:

- `read_jobs`: completed per-PTY jobs collected by the owner.
- `read_batches`: completed worker batches collected by the owner (one or two
  jobs); phase timings below are per batch, not counted twice for a pair.
- `read_batch_jobs`: selected maximum jobs per batch (1/default or 2).
- `read_queue_ns`: job publication to reader start (including wake/scheduling).
- `read_work_ns`: reader start to result publication (reads, loop, FD close).
- `read_collect_ns`: result publication to owner collection.
- `read_result_ns`: result publication to buffer release, **including** collection
  wait; do not add it to `read_collect_ns` as if they were disjoint.
- `inline_reads`: read attempts served by the inline path, even with an enabled pool.

These are monotonic wall times, not per-thread CPU time; totals may exceed
connection elapsed time. Timings cover startup/echo as well as bulk and are
disabled unless `HOLLOW_MUX_DIAGNOSTICS` is set. Jobs abandoned by connection
abort need not appear in collected/released totals.

For 16 panes × 32 MiB, two readers took 3.822 seconds bulk elapsed: 5.778 seconds
aggregate read work, 0.559 queue wait, 0.511 collection wait, and 1.034 result
hold. Four readers took 2.024 seconds: 5.746 work, 0.634 queue wait, 0.535
collection wait, and 1.381 result hold. These suggest roughly 71–76% of worker
capacity spent in read work, not a pure transport-handoff bottleneck. The
estimate uses bulk elapsed against whole-connection counters, so it is not an
exact utilization measurement. Data: `/tmp/opencode/hollow-mux-worker-phases-two.jsonl`
and `/tmp/opencode/hollow-mux-worker-phases-four.jsonl`.

One hypothesis was PTY migration between readers. A controlled stable
`stream slot % reader count` assignment did not improve the two-reader ceiling
(32 panes: 125.2 MiB/s both ways) and increased four-reader mixed p99
(0.850 → 1.717 ms). It was **discarded**; dynamic assignment remains. Data:
`/tmp/opencode/hollow-mux-worker-affinity-ablation.jsonl`.

Raw PTY control instead exposed the cost of repeatedly reading the **same**
PTY before rotating. The diagnostic now supports:

```sh
python3 scripts/agent_pty_read_bench.py --panes 16 --workers 2 \
  --batch-reads 1 2 4 8 --runs 3
```

With identical producers, no transport/credits/framing, three-run medians on
this WSL2 kernel were:

| Attempts per ready PTY before rotation | MiB/s | Mean wall time per counted read (µs) |
| --- | ---: | ---: |
| 1 | 261.2 | 25.9 |
| 2 | 226.2 | 35.4 |
| 4 | 194.1 | 44.8 |
| 8 | 184.1 | 49.4 |

This isolates an important workload/scheduling effect below Hollow's transport;
it does **not** identify the exact kernel mechanism, prove transport parity, or
show that one-read jobs would win after owner handoff costs. At this stage,
rotating several credit-reserved PTYs inside a bounded worker batch was a
candidate for further measurement. The opt-in implementation is described below. Data:
`/tmp/opencode/hollow-raw-read-batching-cli.jsonl`.

The retained small optimization addresses the already-known single-pane cost:
when exactly one stream remains and **every** worker state is idle, read on
the owner using the existing bounded inline path. Running jobs and ready results
keep the pooled path active until drained; read ownership never overlaps, and
staged bytes/credit accounting remain unchanged. A newly spawned second stream
resumes pooling on the next scheduling turn. Stream count is conservative: an
idle second stream still selects pooling. No utilization heuristic, batching
timer, new queue, or production default is introduced.

Paired old/new binaries, ReleaseFast, 8 MiB/stream, 25 idle echoes, three runs
with variant order alternated, single-pane medians:

| Backend | Before MiB/s | After MiB/s |
| --- | ---: | ---: |
| Dedicated control | — | 75.2 |
| Inline control | — | 75.5 |
| Pool selected, 2 readers | 63.3 | 74.8 |
| Pool selected, 4 readers | 63.3 | 77.9 |

At 32 panes, four-reader bulk was 231.0/228.4 MiB/s before/after; mixed p99
was 0.983/0.887 ms. An apparent four-pane drop in short runs was checked with
32 MiB/pane over five paired runs: 234.6/232.2 MiB/s medians, overlapping ranges
(210.5–235.7 and 230.8–240.7). Treat small multi-pane differences as noisy rather
than claim a throughput gain. Data: `/tmp/opencode/hollow-mux-single-fastpath-comparison.jsonl`
and `/tmp/opencode/hollow-mux-fastpath-four-longer.jsonl`.

Regression coverage exercises binary output across single→multi→single stream
transitions and deterministic selection with running/ready jobs. The stalled
final-output/PID-retention test keeps a second idle stream live so the worker
result lifecycle remains covered rather than silently testing only the fast
path. Numerical release budgets and broader connector qualification remain open.

### Opt-in paired PTY read batches

`HOLLOW_MUX_READ_BATCH_JOBS=2` selects a bounded two-PTY worker batch; default
**1** retains single-job mode for comparison. It only affects mux with nonzero
read workers. Dedicated `pty`, `stdio`, and GUI defaults are unchanged. No wire,
version, or capability changes are needed.

```sh
HOLLOW_MUX_READ_WORKERS=4 HOLLOW_MUX_READ_BATCH_JOBS=2 \
  python3 scripts/agent_mux.py --panes 1 4 16 32 --runs 3 --build-mode ReleaseFast
HOLLOW_MUX_READ_WORKERS=4 HOLLOW_MUX_READ_BATCH_JOBS=2 \
  python3 scripts/agent_mux.py --workload mixed --panes 32 \
  --samples 1000 --runs 3 --build-mode ReleaseFast
```

Implementation and bounds:

- A batch rotates individual nonblocking read attempts between up to two
  independently credit-reserved PTYs. EAGAIN/EOF stops only that member; others
  continue. Each batch retains the 32-attempt, 750-microsecond between-calls
  budget, with no wait to fill a result.
- Jobs share **one existing 64 KiB worker buffer**, partitioned by reserved
  allowances. Two ordinary jobs reserve up to 32 KiB each; focus may reserve up
  to 64 KiB when selected first, leaving no partner capacity. Payload capacity
  remains four × 64 KiB, reservations at most `workers × 64 KiB`, transport
  staging 16,393 bytes, and data frames at most 16 KiB. Job metadata adds a
  small bounded overhead; there is no additional payload queue.
- Each job owns its own close-on-exec master duplicate: at most two per worker,
  rather than one. All close before batch publication, or after joining an
  abandoned batch on shutdown.
- The owner assigns separate job keys, returns unused reservation once per
  member, and rotates ready results for delivery. A member may abort/retire/reuse
  its stream slot while its partner's result is held. Collection skips released
  members **before** looking up their old slot. The buffer is reusable only
  after **all** members release it.
- Pair only when ready PTYs outnumber idle readers. Scarce work gets one job per
  reader first, avoiding four PTYs occupying only two of four readers.
  Focus-first decisions still alternate with background turns; the single-pane
  inline path still waits for all batches/results to drain.

An initial 16-pane × 32 MiB diagnostic showed timed PTY reads dropping from
roughly 45 to 30 microseconds with rotation. An original single-job binary was
saved for reference; the new binary also retains single-job mode to separate
refactor effects from rotation effects. Counters:
`/tmp/opencode/hollow-mux-rotating-first.jsonl`.

Local WSL2, ReleaseFast, 8 MiB per pane, 25 idle echoes, three-run median MiB/s;
variant order reversed on alternating runs; syscall diagnostics disabled:

| Panes | Dedicated | Inline | 2 readers, single | 2 readers, paired | 4 readers, single | 4 readers, paired |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 74.8 | 79.0 | 77.5 | 79.4 | 78.4 | 77.4 |
| 4 | 279.8 | 89.8 | 126.2 | 176.8 | 213.4 | 215.3 |
| 16 | 387.5 | 90.9 | 128.1 | 199.1 | 240.3 | 317.6 |
| 32 | 396.4 | 89.3 | 125.0 | 198.0 | 234.7 | 322.5 |

Longer bulk runs (32 MiB/pane, three-run medians) confirmed the gain and checked
the original binary against the refactored single-job path:

| Panes | Dedicated | Original single-job, 4 readers | Refactored single-job, 4 readers | Paired, 4 readers |
| --- | ---: | ---: | ---: | ---: |
| 4 | 300.6 | 232.3 | 238.1 | 234.2 |
| 16 | 370.7 | 245.1 | 247.2 | 345.1 |
| 32 | 404.7 | 235.5 | 238.1 | 329.9 |

At 32 panes, single/paired agent-tree CPU medians were 10.764/8.892 seconds and
client CPU 1.609/1.280 seconds. Tree CPU includes children/startup/teardown, not
just reads. Four-reader modes both use five agent threads, versus 32 dedicated.
Data: `/tmp/opencode/hollow-mux-rotating-bulk.jsonl` and
`/tmp/opencode/hollow-mux-rotating-bulk-longer.jsonl`.

Focused echo under 31 sustained floods, 1,000 actual echoes/run, three-run
medians, same final binary and alternating order:

| Backend | p50 / p95 / p99 (ms) | Worst individual echo (ms) | Flood MiB/s |
| --- | ---: | ---: | ---: |
| Dedicated | 0.374 / 1.482 / 2.893 | 11.744 | 377.2 |
| Four readers, single jobs | 0.410 / 0.715 / 0.979 | 3.364 | 234.5 |
| Four readers, paired jobs | 0.490 / 0.937 / 1.283 | 3.118 | 329.5 |

Every flood progressed; minimum per-stream volume was 56.5 MiB dedicated,
41.4 MiB single-job, and 59.0 MiB paired across those runs. Pair publication
waits for the bounded batch, so latency may rise even as throughput improves.
This is an explicit throughput/latency experiment, **not** parity or rollout
approval. Bulk still trails dedicated; numerical budgets, remote connectors,
and GUI qualification remain open. Data:
`/tmp/opencode/hollow-mux-rotating-mixed.jsonl` (100-sample 4/16/32-pane runs) and
`/tmp/opencode/hollow-mux-rotating-mixed-longer.jsonl` (the table above).

Tests run all five inline/worker/batch configurations. Deterministic tests cover
rotation, exhausted/empty members, shared buffer bounds, independent release,
stale released slots, and reader parallelism with scarce work. Real-agent tests
cover eight binary streams, an exhausted consumer alongside many floods and
focused echo, close/reuse, ordering, descriptor hygiene, teardown, and invalid
batch sizes rejected before hello.

## Experimental config integration

Agent-backed domains now accept `pty = { mode = "mux", read_workers = 4,
batch_jobs = 2 }`; omitted settings retain dedicated mode. See
[config reference](reference/lua/config.md#experimental-shared-terminal-connections)
for WSL/SSH examples and rollback. Existing GUI environment flags do not select
the backend; config sends tuning explicitly through the connector to the agent.

`src/pty/agent_mux.zig` pools only terminal connections. Effective host identity
is a canonical serialization of connector argv/remote-shell quoting, agent
path/install directory/artifact paths and digests/timeout, path style/fallback
policy, and tuning. Different spawn cwd/env/argv/commands/sizes share transport
but not child state. Identity is conservative: different policies may create
separate connections even when they reach the same machine. New panes adopt
current config; existing connections retain their snapshot across reloads.

The process-wide registry allows 16 live connections, each with at most 32
stream handles; full connections spill into another connection. One writer,
reader, and watchdog serve a connection, independent of its pane count. The
first pane launches one deployment/connector; concurrently attached panes wait
for that same negotiation. No pane API performs blocking transport IO. Last
stream retirement closes stdin, waits a bounded grace, and kills a stalled
connector if needed. There is no idle connection cache or reconnect/replay of
existing shells. Protocol or connector failure ends all remaining streams
visibly; a new pane can establish a fresh connection.

Client input admission retains the dedicated backend's all-or-nothing 4 MiB
per-stream bound, avoiding a new large-paste admission regression. Only 64 KiB
may be outstanding on the wire per stream. The writer uses
16 KiB data frames, input credits, fair per-stream turns, coalesced resizes and
focus hints. Input and returned output credits alternate when both are pending;
output grants batch at 32 KiB, or when the receive allowance reaches zero. The
reader checks headers before payload admission, validates negotiation and
per-stream credits, and never waits for a consumer while routing siblings.
The first adapter limited unread output to 64 KiB and returned credits only on
pane consumption; the bounded read-ahead correction below supersedes that
behavior. Spawn serialization and receive control payloads each use fixed
64 KiB staging. A small bounded failure banner may be appended on termination.

Spawn submission is the no-replay boundary: implicit WSL fallback is possible
only before a spawn is sent. Closing one pane sends only its stream close; a
stalled shared transport/close timeout may still require killing the connector
and failing siblings. Three-second write/close grace and host hello timeout are
checked by the watchdog; deployment cancellation affects the shared bootstrap
only when no interested pane remains. Filesystem/exec connections are untouched.

Real-agent client tests cover reuse, per-spawn env/resize/input/exit, isolated
close and spawn errors, stalled consumers, binary output across many windows,
connector/tuning separation, bounded input, visible loss fanout with no restart,
fresh connections after failure, and bounded silent-hello/close handling.
GUI rendering and actual WSL/SSH behavior/performance remain qualification work.
The frame-paced diagnostic and correction below address the original
consumption-driven buffering limit; headless tables still are not end-to-end GUI results.

## Native pane-adapter measurements and bounded read-ahead

The wire client drains continuously; GUI panes consume output on UI turns.
`src/agent_pane_bench.zig` now exercises **the actual AgentPty adapter**, comparing
continuous drains with frame-paced queue snapshots without loading VT/rendering:

```sh
zig build --build-file build-agent.zig agent agent-pane-bench -Doptimize=ReleaseFast
python3 scripts/agent_pane_bench.py --panes 1 4 16 32 --runs 3 --build-mode ReleaseFast
zig build --build-file build-agent.zig test-agent-pane-bench
```

Children run deterministic raw-mode Python, report one ready byte, wait for a
start byte, emit an exact byte count, and remain alive until closed. Spawns are
sequential while earlier panes stay alive. `startup_ms[0]` measures a **cold
connection to a preinstalled agent**, not deployment; subsequent values measure
warm pane opens. Python interpreter startup is included, user shell profiles are
not. Each synthetic UI turn drains only the queue's initial snapshot, not bytes
that arrive during the turn. No VT parser, frame time budget, rendering, actual
WSL/SSH, or network latency is simulated. CLI `--frame-us 0` selects continuous
drains; `16667` is approximately 60 Hz. Queue snapshots and drain timing make
this a diagnostic rather than a complete GUI throughput model.

### Bottleneck and correction

The first config adapter returned credits only as the pane consumed its 64 KiB
queue. At 60 Hz this creates an approximately **3.75 MiB/s per-pane ceiling**,
even though the same single-pane adapter measured about 81 MiB/s when drained
continuously. This is an adapter buffering limitation, not an agent PTY-read
limit. The original adapter benchmark was saved for paired comparisons.

Experimental mux clients now use bounded reader-thread read-ahead:

- Wire windows stay **64 KiB**, frames stay 16 KiB, and protocol/version do not
  change. The reader never waits for a stalled pane while routing siblings.
- Unread protocol output is capped at **4 MiB per pane**, matching dedicated
  client buffering. Credits replenish from available read-ahead capacity rather
  than waiting for every GUI frame. Credit updates remain batched.
- The connection has a **16 MiB logical output reservation budget**. Each of
  32 slots accounts for `max(64 KiB, queued protocol bytes + outstanding receive
  credits + pending consumption notices)`. Thus even empty slots and stalled
  interactive streams retain a baseline window: background floods cannot steal
  capacity needed by new spawns or by a small stream refilling after consumption.
- Queued bytes and outstanding credits share the budget; receiving a frame
  moves, rather than duplicates, its reservation. Reader-discarded abort bytes,
  UI consumption, and stream retirement release reservations exactly once.
  Only the owner grants credits. UI consumption notices cross the session lock
  and are collected under connection ownership; lock order remains unchanged.
- A stream with final output retains its client slot/budget until those bytes
  are consumed, unless pane close explicitly aborts it. Error banners remain a
  small bounded addition outside the protocol ledger. Failed-connection output
  remains pane-owned until drained/closed. The 16 MiB budget is **not an RSS
  bound**: allocator capacity, fixed staging, input buffers, and historical
  pane-owned final output are separate bounded allocations.
- Client input keeps its existing 4 MiB admission bound. Dedicated buffering,
  agent defaults, config selection, and filesystem/exec paths are unchanged.

### Results

WSL2 Linux, ReleaseFast, preinstalled local agent, same agent binary and saved
reference/new adapter binaries, four mux readers with paired jobs, alternating
variant order, three-run medians. Longer runs use **16 MiB per pane** and a
16,667-microsecond snapshot-drain cadence:

| Panes | Dedicated adapter | Original mux adapter | Read-ahead mux adapter |
| --- | ---: | ---: | ---: |
| 1 | 73.6 | 3.7 | 73.7 |
| 4 | 293.5 | 15.0 | 211.6 |
| 16 | 465.0 | 60.0 | 311.0 |
| 32 | 467.7 | 119.9 | 306.4 |

Values are aggregate MiB/s. The single-pane reference limitation disappears;
multi-pane throughput remains below dedicated, so **no general parity claim**.
Read-ahead reservation high-water samples peaked around 7.4 MiB in these bulk
runs; a separate saturated-consumer regression reaches the 16 MiB cap. Physical
queue/RSS overhead is not inferred from this logical high-water counter.

Shorter paired runs (4 MiB/pane) also compared continuous drains. Original/new
mux medians were 80.7/84.5 MiB/s at one pane, 218.1/234.4 at four,
320.3/327.5 at 16, and 308.6/309.7 at 32. These short-run differences are not
proof of an additional continuous-drain speedup. Short frame-paced runs are
especially quantized by the number of UI turns; prefer longer comparisons.

Local warm opens were dominated by roughly 10–12 ms Python spawn/readiness
cost. With an explicitly **synthetic 50 ms connector startup delay**, four-pane
three-run medians were 67.5 ms cold / 66.7 ms warm dedicated, versus
69.2 ms cold / 11.3 ms warm mux; live connector counts were four versus one.
This verifies elimination of repeated connector startup, not a measured SSH/WSL
network benefit. Reproduce with `--connector-delay-ms 50 --panes 4 --frame-us 0`.

Raw data:

- `/tmp/opencode/hollow-native-pane-64k-baseline.jsonl`
- `/tmp/opencode/hollow-native-pane-read-ahead-paired.jsonl`
- `/tmp/opencode/hollow-native-pane-read-ahead-longer.jsonl`
- `/tmp/opencode/hollow-native-pane-warm-delay.jsonl`

Regression coverage includes the per-stream and aggregate caps, reserved baseline
refills under budget exhaustion, exact binary output over many windows, and a
256 KiB interactive echo while eight unconsumed floods saturate the connection
budget. This last test deliberately exceeds one wire window so an initial-credit
burst cannot masquerade as sustained progress. Benchmark smoke tests check ready
counts, actual bytes, connection reuse, and queue/reservation bounds in both
continuous and frame-paced modes. Actual GUI/remote tail-latency and sustained
RSS qualification remain release gates.

The aggregate cap intentionally limits read-ahead when stalled panes occupy the
shared budget. Baseline windows preserve sibling progress, not full bulk speed
under every saturated-consumer pattern. Visibility-aware buffering is separate
follow-up work; no current result qualifies that case for rollout.

Validation passed in Debug and ReleaseFast: 76 Zig tests, all 23 wire integration
tests in five configurations, and the adapter benchmark smoke test (four
mode/cadence combinations). Windows ReleaseFast and both Linux agent architectures
build. An initial Debug run overlapping a Windows compile hit the existing
wire test's three-second zombie-state expectation in two configurations; a
standalone rerun and complete serialized Debug/ReleaseFast runs passed. This
timing sensitivity is not evidence of a new server fix; the agent server is
unchanged by the read-ahead correction.

## Native backlog latency and avoidable owner work

The native adapter diagnostic also measures actual focused echoes while other
panes keep output queues backlogged:

```sh
python3 scripts/agent_pane_bench.py --panes 4 32 --frame-us 16667 \
  --echo-samples 1000 --drain-bytes 16384 --read-chunk 65536 \
  --runs 3 --build-mode ReleaseFast
```

This uses raw Python children with one focused echo stream and `panes - 1`
sustained floods. Background panes drain at most the selected byte quota per
frame turn; every flood must make measurable progress. The focused adapter is
polled independently every 100 microseconds, with a 100 ms warmup and 5 ms idle
interval between echoes. A sample starts before input admission and ends after
the matching byte is read back; there is never more than one outstanding echo.
Returned bytes are checked, including changing binary echo tokens. Reported
percentiles use nearest rank; tables below are medians of per-run percentiles.

This deliberately measures **adapter/driver latency under backlog**, not GUI
keyboard/event/VT/render latency. Background byte quotas are diagnostic controls,
not a reproduction of the app's complete visible/hidden parsing scheduler.
It also does not qualify focus switching, remote connectors, or release budgets.

### Queue-copy investigation

Mux originally compacted the entire remaining queue after any partial read.
Copy counters showed a one-pane, 16 MiB, 60 Hz diagnostic with 4 KiB reads moving
about **12 times the payload** in reader compactions. Matching dedicated's
append-space policy (compact only when append space is exhausted) reduced that
reader-copy ratio to approximately zero; consumer compactions remained around
one payload. A deterministic regression checks both the no-copy append path
and compaction when required, including binary ordering across the consumed
prefix.

Three-run median bulk throughput in that 4 KiB-read case rose 63.8 → 72.0 MiB/s;
64 KiB reads measured 73.6 → 79.4 MiB/s. These short frame-paced runs are
quantized and **not proof of a broad throughput gain**. Four/32-pane throughput
was largely unchanged. The cleanup removes unnecessary lock-held copies without
changing queue bounds, credits, allocation policy, or dedicated behavior.
`reader_compacted_bytes` and `consumer_compacted_bytes` now report the respective
copy work for both adapters. Data:
`/tmp/opencode/hollow-native-compaction-first.jsonl` and
`/tmp/opencode/hollow-native-compaction-paired.jsonl`.

### Empty polling was waking the shared owner

Profiling the backlog workload exposed a larger avoidable cost: every empty
`AgentPty.read()` notified the mux connection. A focused adapter polled every
100 microseconds could wake the writer/watchdog thousands of times per second,
even though no queue capacity or control state had changed. Each writer turn
scanned the stream table and acquired session locks unnecessarily.

Empty reads now remain silent. Reads that consume output still notify after
releasing the session lock, including final-output consumption needed for slot
retirement. Close/input/resize/focus notifications are unchanged. A deterministic
test asserts zero notifications for an empty poll and exactly one for consuming
protocol output. Diagnostics distinguish empty reads, UI `notify` calls, and
owner turns; these are not kernel wakeup or context-switch counts.

Local WSL2 Linux, ReleaseFast, same agent, saved counter-instrumented reference
and updated adapters; four mux readers with pairs, 1,000 echoes per run, three
runs in alternating variant order, 16,667 µs background cadence, 16 KiB per-pane
drain quota, and 64 KiB read buffer:

| Panes | Variant | p50 / p95 / p99 (ms) | Process-tree CPU (s) | UI notifications | Owner turns |
| --- | --- | ---: | ---: | ---: | ---: |
| 4 | Dedicated | 0.416 / 0.607 / 0.713 | 1.202 | — | — |
| 4 | Mux, empty polls notify | 0.515 / 0.720 / 0.933 | 2.968 | 27,527 | 30,423 |
| 4 | Mux, quiet empty polls | 0.525 / 0.737 / 0.849 | 1.637 | 3,034 | 7,545 |
| 32 | Dedicated | 0.415 / 0.728 / 1.429 | 5.351 | — | — |
| 32 | Mux, empty polls notify | 0.518 / 0.841 / 2.227 | 5.621 | 36,207 | 42,453 |
| 32 | Mux, quiet empty polls | 0.520 / 0.753 / 2.032 | 4.332 | 12,759 | 20,900 |

CPU includes the native driver, agents, workload children, startup and teardown,
not just the transport owner. Thus this demonstrates a reduction in observed
**process-tree CPU**, not a measured percentage of GUI CPU saved. The driver
continued making roughly 29,000 empty reads per run; avoiding their notifications
cut futile owner work rather than changing the polling workload or frame budget.
Background consumption stayed around 2.8 MiB/s at four panes and 28.8–28.9 MiB/s
at 32, intentionally limited by quotas. Every background stream progressed.

Tail samples remain noisy: worst individual old/new mux echoes were
4.935/1.920 ms at four panes and 4.109/4.418 ms at 32. Do not infer a hard latency
bound or general tail improvement from these medians. Queue/reservation caps,
protocol, reader count, connection lifetime, and production defaults are unchanged.
Full comparative records: `/tmp/opencode/hollow-native-empty-notify-paired.jsonl`.
Initial backlog diagnostic: `/tmp/opencode/hollow-native-backlog-initial.jsonl`.

Benchmark smoke coverage now includes exact echo counts, progress of every
flood, queue bounds, diagnostic notification bounds, and continuous/frame-paced
background draining. Larger persistent queues can still require compaction when
append space really runs out; those costs and remaining multi-pane transport
overhead require further profiling rather than bigger buffers or default changes.

Validation after these changes passed serialized Debug and ReleaseFast suites:
78 Zig tests, 23 wire integration tests across five configurations, and both
native diagnostic smoke tests (bulk and backlog, each across dedicated/mux and
continuous/frame-paced draining). Windows x86_64 ReleaseFast GUI and Linux
x86_64/aarch64 agents also built successfully.

## Initial Windows GUI / WSL repaint measurements

October 20, 2026: actual Windows Hollow GUI, Ubuntu-26.04 WSL agent-backed
domains, dedicated versus `pty = { mode = "mux", read_workers = 4,
batch_jobs = 2 }`. These exercise the connector, pane adapter, and terminal
parser, unlike the native adapter-only diagnostics above. They are **not
displayed-frame rates**: repaint completion uses a terminal DSR acknowledgement,
not confirmation that every generated frame was presented by the renderer.

The user's initial `bench.sh repaint 1000` samples at 212×62 measured median
47.8 Mcells/s dedicated (three runs) and 44.6 Mcells/s mux (four runs), about
6.7% lower mux throughput. Each run lasted only about 0.3 seconds.

A follow-up automated comparison used the running GUI and its Windows command
CLI. Temporary workspaces left existing panes intact and were closed afterward;
the original workspace was restored. Workloads wrote directly to their PTYs,
without a pipe or per-frame log. A temporary copy of `bench.sh` wrote exact JSON
timings after the existing repaint/drain measurement; rendering and drain logic
were unchanged. The installed GUI executable matched `zig-out/bin/hollow-native.exe`
byte-for-byte (SHA-256
`dcc2b3280f3c586ce05e971fdb99e8a39ed2b6d3ca13a2ef9d36ff365756dc77`).
The checkout was `c322df9`; binary identity alone does not establish build flags.

Three runs per backend and layout, alternating PTY/mux order between repeats:

| Layout | Frames per pane | Dedicated Mcells/s, median (range) | Mux Mcells/s, median (range) | Mux relative to dedicated |
| --- | ---: | ---: | ---: | ---: |
| One pane, 212×62 | 20,000 | 47.40 (47.09–48.92) | 44.72 (44.06–44.80) | −5.6% |
| Four visible panes, 2×2 grid | 50,000 | 71.19 (64.47–71.53) | 65.32 (63.63–72.85) | −8.2% |

Grid pane sizes were 105/106 columns by 30/31 rows. Workers waited at a shared
filesystem gate before each run; this is not an exact simultaneous-start
barrier. Grid throughput is total generated cells divided by the longest
individual pane's drain-adjusted elapsed time, **not** the sum of independent
pane rates or an exact first-start-to-last-finish wall-clock rate. All panes
completed all requested frames and received drain acknowledgements. Individual
single-pane runs took roughly 5.4–6.0 seconds; grid runs roughly 8–10 seconds.

The single-pane result corroborates the user's short samples. The grid result
is encouraging but variable: the third mux trial exceeded its dedicated
counterpart, and individual grid drain acknowledgements ranged up to 172 ms.
Neither observation establishes focused typing latency or fairness under
sustained load. Existing user workspaces and live connections remained present;
connection warmth, OS load, and GUI presentation timing were uncontrolled.
These are warm GUI/WSL repaint observations, not cold startup, isolated bulk
transport, process-tree CPU/RSS, SSH/container, teardown-fault, or release
qualification. Numerical release budgets remain unagreed; defaults and memory
limits remain unchanged.

Local artifacts (not repository fixtures):

- `/tmp/opencode/hollow-gui-repaint-20261020-074551/results.jsonl`
- Per-pane exact timing JSON in that directory's `1-pty`, `1-mux`, `4-pty`, and
  `4-mux` subdirectories.
- `/tmp/opencode/hollow-gui-repaint-run.py` and
  `/tmp/opencode/hollow-gui-repaint-worker.sh` (local orchestration), with
  `/tmp/opencode/hollow-gui-bench.sh` (temporary result-recording copy).

Next GUI measurements should distinguish actual input-to-echo latency from
terminal-generated DSR round trips, sustain background traffic throughout
sampling, switch focus between panes, and measure per-pane progress, CPU/RSS,
startup, and bounded teardown. Do not infer multi-pane transport parity from
this parser-heavy repaint workload.

## GUI echo observation under sustained sibling floods

October 20, 2026: uncapped experiment in the actual same Windows GUI / Ubuntu
26.04 WSL domains. A temporary four-pane grid ran raw Python echo workers in
the top and bottom left panes, with two continuously changing bounded repaint
floods on the right. Focus switched every 100 samples. Three paired runs
alternated backend order; each run had 200 idle samples followed by 1,000
loaded samples. Each sample sent one changing GUID+sequence token with one
request outstanding, disabled TTY local echo, and required the raw child to
write `ACK:<token>`. Success required exact token match in current GUI-parsed
pane text. All loaded runs had nine successful focus moves; focus was validated
each segment, with no sample-count or token failures.

Timing ran from before `pane_send_text`'s socket request to the first
`get_pane_text` reply containing the ACK. One long-lived Windows PowerShell
5.1 process used a fresh TCP connection per command, `NoDelay`, and combined
header/body writes; process startup was not timed. Focus commands and focus
validation were excluded, but first sample after each switch was included.
This is not DSR, physical-keyboard, renderer-presentation, or backend-only
timing. Loaded sampling took about 34 seconds per run.

Per-run nearest-rank p50/p95/p99, then median across three runs (ms; rounded
to two decimals):

| Backend | Idle p50 / p95 / p99 | Loaded p50 / p95 / p99 | Worst loaded sample |
| --- | ---: | ---: | ---: |
| PTY | 6.92 / 10.94 / 14.41 | 13.64 / 17.16 / 18.92 | 43.81 |
| Mux | 7.26 / 11.19 / 15.30 | 13.07 / 16.57 / 18.93 | 42.78 |

Flood aggregate producer throughput, admitted bytes divided by run duration:
PTY runs were 88.96269, 84.56439, and 85.78852 MiB/s (median 85.79);
mux runs were 67.03508, 67.41727, and 70.29793 MiB/s (median 67.42).
Counts are bytes accepted by producer `os.write`, including ANSI and queued
bytes, not exact parsed or rendered bytes. Progress checkpoints were about
250 ms; both floods progressed throughout. Largest observed update interval
was about 501 ms mux versus 255 ms PTY; these are observations, not hard fairness
bounds. Observer send and final-query median components were each about
4.5–4.8 ms, substantial observer overhead. No parity claim at equal throughput.

Local data: `/tmp/opencode/hollow-gui-loaded-20261020-075432`, with raw
`idle-N.jsonl` / `loaded-N.jsonl` and progress files under `pty` / `mux`, plus
`summary.jsonl` at its root. Temporary harness files are
`/tmp/opencode/hollow-gui-loaded-worker.py`,
`/tmp/opencode/hollow-gui-loaded-sample.ps1`, and
`/tmp/opencode/hollow-gui-loaded-run.py`. Native defaults and limits remain
untouched. Actual focus switching was exercised, but RSS, faults, startup,
teardown, and release budgets remain unqualified.

### Matched offered load in an isolated GUI instance

To keep testing from disturbing the user's terminal, a second instance used
separate configuration, `APPDATA`, `LOCALAPPDATA`, and command IPC. Its window
was placed on a separate 1920×1152 monitor working area and was not foreground
or minimized at launch. Window state was not sampled continuously. Both
`max_fps` and `idle_max_fps` were 120, with vsync disabled. This differs from
the original instance's idle cap of 15; **do not attribute cross-experiment
latency changes solely to load capping**. Within this comparison both backends
used the same isolated instance and settings.

The same echo/focus protocol and three-run sample counts were repeated with
each flood capped at 20 MiB/s. Average-rate pacing resets after pauses or more
than 100 ms of lag; it is not a strict instantaneous bandwidth guarantee.
Both workers measured 19.965–19.977 MiB/s in every loaded run, with no repeated
byte counts in the approximately 250 ms progress snapshots. Largest observed
progress interval was 256 ms. This verifies observed producer progress, not
a deterministic fairness bound or exact terminal-rendered throughput.

Median of per-run nearest-rank percentiles (ms):

| Backend | Idle p50 / p95 / p99 | Matched-load p50 / p95 / p99 | Worst loaded sample |
| --- | ---: | ---: | ---: |
| PTY | 8.10 / 11.53 / 12.67 | 10.77 / 14.99 / 17.85 | 40.84 |
| Mux | 8.79 / 11.79 / 15.51 | 10.75 / 14.49 / 16.97 | 39.54 |

All 3,000 loaded echoes per backend and focus transitions completed without
token or sample-count failures. These observer-limited results show no obvious
mux latency regression at this offered load; they do not establish a general
latency bound, keyboard-to-display performance, or throughput parity.

Data: `/tmp/opencode/hollow-gui-loaded-20261020-080757`, with the same raw and
progress-file structure as above. `run-setup.json` records launcher observations,
environment isolation, settings, and cleanup. Temporary launch/config files:
`/tmp/opencode/hollow-gui-isolated-launch.ps1` and
`/tmp/opencode/hollow-gui-isolated.lua`. Test workspaces and the isolated GUI
were closed afterward; no workload workers remained, and the original user's
IPC discovery address stayed unchanged. This successful cleanup is not a
fault-injection or bounded-teardown qualification.

An earlier matched-load attempt,
`/tmp/opencode/hollow-gui-loaded-20261020-080144`, was aborted during its first
idle trial after focus validation failed. The user confirmed interacting with
that terminal; its 100 partial idle samples and all incomplete data are excluded.

## Isolated GUI / WSL CPU and memory observations

October 20, 2026: three paired trials in a fresh, isolated actual-GUI instance,
alternating backend order and launching a fresh GUI per backend each time to
avoid retained memory crossing backends. Separate config, `APPDATA`,
`LOCALAPPDATA`, and command IPC kept the instance isolated; its window stayed
visible, unfocused, and on another monitor in recorded samples. Both backends
used max/idle FPS 120, vsync off, and Rec Mono Duotone at size 14.5. Each run used
four panes: two raw idle echo workers plus two dynamic repaint floods. Unlike
the echo-observer experiment above, no echo inputs
or observer-poll loop ran here. Phases were idle, capped at 20 MiB/s per flood,
and uncapped, each for 20 seconds; sampling warmed for one second after load
changes.

Median across paired trials:

| Phase / metric | Dedicated PTY | Mux |
| --- | ---: | ---: |
| Capped producer rate (MiB/s) | 40.00 | 40.00 |
| Capped Linux agent average cores | 0.532 | 0.881 |
| Capped Linux Python workers average cores | 1.158 | 1.242 |
| Capped Windows GUI average cores | 1.139 | 1.230 |
| Capped Linux agent sampled max RSS (MiB) | 3.42 | 1.23 |
| Capped Linux agent + workers sampled max RSS (MiB) | 62.62 | 60.54 |
| Capped Windows GUI sampled max working set (MiB) | 169.19 | 154.41 |
| Capped Windows GUI sampled max private bytes (MiB) | 438.45 | 346.13 |
| Capped Windows descendant working-set sampled max sum (MiB) | 209.55 | 52.44 |

CPU is core-seconds divided by elapsed seconds, not percent of whole machine.
At matched 40 MiB/s, mux Linux-agent CPU was about 65.7% higher and GUI CPU
about 8.0% higher: **no overall CPU win**. These observations do not identify a
root cause. Do not add CPU or RSS across Linux/Windows, or interpret summed
working sets/RSS as unique physical memory: shared pages may be counted more
than once. Linux totals use sampled `/proc` RSS, whose accounting is
approximate; Windows working sets are coarse sampled maxima and private bytes
are commit, not RSS. Maximum per-trial Windows sampling gaps were 1.03–1.10 s for PTY and
0.80–0.83 s for mux despite a nominal 250 ms cadence. CPU uses actual timestamps
from each OS in separate windows with startup offsets; phase workloads remained
stable through both windows.

Topology was four PTY agents/four Python workers versus one mux agent with five
threads/four workers. Windows descendant maxima were 20 versus 5 and include
WSL/WSLHost/conhost; they are not strict connector process counts. These
20-second phases are **not** sustained-leak or RSS qualification. Major-fault
delta was zero; this was not a fault test.
Uncapped producer medians were 84.23 MiB/s PTY (70.59–87.07) and 72.17 MiB/s
mux (52.30–73.09). Host and producer-workload variation affect these rates;
they are not transport maxima, and CPU comparisons at different throughput are
not fair.

All 18 phase validations passed; tracked Linux worker/agent identities were
verified gone after all six runs, and isolated GUIs closed. An aborted
metadata-file publication race occurred before trial 2's
workload; it was excluded. Atomic publication was fixed and the first paired
trial preserved on resume; this was harness recovery, not agent failure. The
original GUI and configuration were untouched. Launch-to-IPC/window placement
took 0.35–0.66 s for PTY and about 0.37 s for mux. CLI-to-Python-ready averages
were 2.34–2.52 s PTY and 2.17–2.56 s mux, dominated by native PowerShell CLI and
polling; this is not cold-shell startup. Mux's initial default pane was already
warm; no startup gate is qualified. Existing GUI stderr handling also means
agent stderr diagnostics are not observable through the GUI; no implementation
change is implied.

Raw analysis: `/tmp/opencode/hollow-gui-resource-20261020-082658/analysis.json`.
Harness files `/tmp/opencode/hollow-gui-resource-{run.py,launch.ps1,config.lua,summary.py}`
and samplers `/tmp/opencode/hollow-gui-proc-sample.py` and
`/tmp/opencode/hollow-gui-win-sample.ps1` are local artifacts, not repository
fixtures. Next: profile read-pool handoff, owner polling, and scheduling; compare
0/1/2/4 workers and batch 1/2 at fixed load, including latency, before changing
buffers.

## Read-worker CPU/throughput tradeoff in the GUI

October 20, 2026: follow-up A/Bs used the same installed GUI and isolated fresh
instance per configuration, with three alternating repeats. Each run had four
panes: two idle raw echo workers and two dynamic repaint floods, with no echo
inputs. Inline (`read_workers=0`, `batch_jobs=1`) was compared with pooled
(`read_workers=4`, `batch_jobs=2`). CPU came from process/procstat samples;
Linux also sampled per-thread CPU and `/proc/PID/task` context-switch counts.
No stderr diagnostics were used. Verified topology was one owner thread inline
and one owner plus four readers pooled; only two readers did CPU work in each
pooled run, with two parked. These are observations, not a cause attribution.

The first run root, `/tmp/opencode/hollow-gui-worker-ab-20261020-085225`, used
20-second phases with each flood capped at 20 MiB/s, then uncapped. Capped
producer rates were 34.452–39.815 MiB/s inline (median 35.948) and
40.001–40.005 MiB/s pooled (median 40.002). **Delivered loads did not match**;
this comparison cannot establish CPU regression at 40 MiB/s. Uncapped producer
medians were 45.714 MiB/s inline and 72.071 pooled (+57.7%); ranges were
42.024–58.860 and 62.448–72.341. This is descriptive producer-admitted
throughput, not transport maximum or rendered bytes. All 6 instances and 12
phases validated with zero errors, and cleanup left no instances.

A lower-rate run at `/tmp/opencode/hollow-gui-worker-ab-20261020-090051`
provided the matched-load comparison: three 20-second capped phases per mode,
each flood actually at 10 MiB/s (20 MiB/s aggregate) in both modes. Results:

| Metric (CPU/switch medians; rate/FD ranges) | Inline | Pool |
| --- | ---: | ---: |
| Aggregate producer rate, observed range (MiB/s) | 20.000–20.004 | 20.000 |
| Linux agent CPU (cores) | 0.374 | 0.657 |
| Windows GUI CPU (cores) | 1.215 | 1.147 |
| Owner user / system CPU (cores) | 0.029 / 0.348 | 0.039 / 0.391 |
| Reader user / system CPU (cores) | 0 / 0 | 0.023 / 0.269 |
| Owner + reader voluntary switches/s | 5,849 | 13,096 |
| Owner + reader nonvoluntary switches/s | 53.96 | 148.1 |
| File descriptors | 9 | 14–16 |

Linux agent CPU was about 75.7% higher pooled at matched 20 MiB/s. GUI CPU was
lower in this run, so it does not establish an overall cross-OS CPU comparison;
do not add CPU across operating systems. Thread windows covered 23–24 seconds
while proc windows covered 20, so median components need not sum exactly.
Mostly-system owner/reader CPU is consistent with overhead on the pooled path
and warrants syscall-level profiling, but does **not** prove redundant notification reads,
eventfd, descriptor handoff, or any other specific root cause. The larger
uncapped pool throughput is why inline is not a justified default fix.

All six lower-run phases passed validation; windows were present, non-minimized,
and not foreground in recorded samples, and cleanup removed all instances.
The earlier 20 MiB/s-per-
flood capped comparison remains an invalid CPU fairness comparison, not discarded
data. Windows sample gaps reached 0.85–1.02 seconds; RSS maxima are observed
samples, not true peaks. Neither
run qualifies startup, leaks, faults, teardown, or release gates; no latency test
was added. The lower-run historical `summary.jsonl` has a stale hardcoded
`rate_mib_s=20` per worker; `run.json` and progress records correctly show 10
per worker and 20 aggregate, and `run-audit-notes.json` documents correction.
Future helper output is fixed. Raw roots contain `worker-analysis.json`, raw
resource samples, and thread samples. Local harnesses
`/tmp/opencode/hollow-gui-worker-ab.py`, `...-summary.py`, and
`/tmp/opencode/hollow-agent-thread-sample.py` are not fixtures.

Next, profile syscall-level owner/read-worker/notification/FD handoff costs and
sample mixed-load latency before any candidate change. Do not increase buffers
or change production defaults; keep `read_workers=4`, `batch_jobs=2` opt-in.

### Eventfd drain cleanup: fewer calls, no demonstrated CPU gain

An isolated five-second syscall capture identified redundant eventfd reads in
the pooled path: owner reads had 2,708 successes and 2,705 `EAGAIN` results;
reader threads had 2,710 of each. Non-semaphore eventfd reads clear the whole
accumulated counter. `drainNotification` now retries only `EINTR`, returning
after one successful read; later notifications remain readable for the next
level-triggered poll. A real-eventfd unit test covers aggregated writes, later
notifications, and empty counters.

A candidate trace confirmed the mechanism: 2,760 successful owner reads and
2,763 successful reader reads, with **zero eventfd `EAGAIN` reads** in the
recorded window. These are different traced workloads, not matched timing
measurements. Ptrace affects scheduling and throughput; syscall durations are
not CPU-cost evidence. Descriptor duplication, notification writes, polling,
and per-job close operations remain profiling targets, not proven root causes.

Three alternating fresh-GUI baseline/candidate pairs used four readers, paired
jobs, and a requested 10 MiB/s per flood. Linux-agent CPU medians were both
approximately **0.680 cores** (baseline range 0.657–0.714, candidate
0.665–0.773). Candidate admitted rates were 19.599, 18.664, and 20.000 MiB/s
against approximately 20.000 for baseline, so these runs do **not** establish
matched-throughput CPU improvement. No GUI latency qualification was performed.
The change removes demonstrably redundant calls, not the established pool CPU
gap. Defaults, buffer bounds, and installed user GUI remain unchanged.

All six GUI phases passed process/window/cleanup validation. Pool unit tests,
`test-agent-loop`, and all five `test-agent-mux` configurations passed (23
integration cases each). Baseline agent SHA-256 was `dbd16af…`; candidate was
`3eb95b…`, supplied only through isolated configs' `agent_path` overrides.
Raw local artifacts: `/tmp/opencode/hollow-gui-syscall-profile-20261020-091435/`,
`/tmp/opencode/hollow-gui-eventfd-candidate-trace-20261020/`, and
`/tmp/opencode/hollow-gui-eventfd-ab-20261020-091925/eventfd-analysis.json`.

### Descriptor-duplication bypass: measured, not adopted

The pooled trace also showed one `F_SETFD(FD_CLOEXEC)` immediately after each
successful `F_DUPFD_CLOEXEC`. Bundled musl's compatibility implementation issues
both calls. A candidate replaced only this duplication call with the direct
Linux syscall, preserving atomic CLOEXEC and independent descriptor ownership.
A five-second candidate trace recorded 2,950 successful owner-thread
`F_DUPFD_CLOEXEC` calls and no `F_SETFD` calls in its scoped window; the earlier
eventfd-cleanup trace had 2,763 of each. This confirms removal of a call, not a
CPU benefit; traced workloads and scheduling differ.

Three alternating fresh-GUI pairs compared the eventfd-cleanup baseline with
this candidate, both using four readers and paired jobs. Each flood requested
5 MiB/s; observed aggregate rates were approximately 10 MiB/s (baseline range
9.957–10.000, candidate 9.979–10.000). Twenty-second process CPU measurements:

| Median CPU cores | Baseline | Direct-syscall candidate |
| --- | ---: | ---: |
| Linux agent | 0.421 | 0.581 |
| Linux workload workers | 0.528 | 0.751 |
| Windows GUI | 1.070 | 1.133 |

Candidate agent and GUI CPU were higher in all three pairs. Agent ranges were
0.380–0.562 and 0.419–0.584 cores respectively. Three pairs do not establish
significance or root cause; the concurrent worker/GUI changes also prevent
attributing this difference solely to the duplication implementation. These
separate OS/process scopes must not be added into a machine CPU total.
The user subsequently reported that a Teams meeting with screen sharing was
active during these measurements. Treat this first comparison as confounded,
not evidence that the candidate caused the CPU increase.

After the meeting ended, five fresh-GUI pairs repeated the same binaries,
four-reader/paired-job settings, 20-second phases, and 5 MiB/s cap per flood.
Both variants delivered approximately 10.000 MiB/s in every phase; all ten
phases passed identity/window/cleanup validation. Results were substantially
more stable:

| Post-meeting median CPU cores | Baseline | Direct-syscall candidate |
| --- | ---: | ---: |
| Linux agent | 0.3775 | 0.3770 |
| Linux workload workers | 0.4245 | 0.4235 |
| Windows GUI | 1.0431 | 1.0439 |

Agent ranges were 0.3725–0.3885 and 0.3370–0.3860 cores. Candidate agent CPU
was lower in four of five pairs, but medians differ by only about 0.13%; this
does not demonstrate a meaningful gain. The earlier increase did not reproduce.
Meeting activity is a reported confound, not an experimentally isolated cause;
other background activity was not controlled. Post-meeting raw data and all
five paired comparisons are in
`/tmp/opencode/hollow-gui-dup-post-meeting-20261020/dup-analysis.json`.

The direct-syscall production change was **not adopted**: removing this call
has no demonstrated performance benefit, rather than a proven CPU regression.
Existing libc duplication remains.
New unit tests retain coverage for CLOEXEC, shared nonblocking flags, duplicate
usability after source close, and failure leaving batch accounting unchanged.
Candidate unit/integration tests and Linux x86_64/aarch64 cross-builds passed;
all six GUI phases passed identity/window/cleanup checks. No GUI latency or
uncapped-throughput qualification was performed for this candidate.

Raw local artifacts and rejected candidate patch are retained under
`/tmp/opencode/hollow-gui-dup-ab-20261020/` (`dup-analysis.json`,
`candidate.patch`); syscall captures are under
`/tmp/opencode/hollow-gui-dup-candidate-trace-20261020/`. Defaults, buffer bounds,
and installed user GUI remain unchanged. Next investigation should distinguish
notification/scheduling work from producer/host variation rather than infer
CPU savings from syscall counts alone.

An Opus 5.5 read-only review recommended untraced diagnostics (jobs, batches,
reads, polls, and writes per MiB) plus process-scoped kernel profiling before
larger changes. Its lowest-risk proposed experiment is an immediate nonblocking
transport write after staging, retaining POLLOUT polling for backpressure.
Futex worker wakeups, conditional completion notifications, and delayed master
close to avoid per-job duplicates require dedicated lost-wakeup/lifecycle tests.
The immediate-write candidate is evaluated below; the higher-risk changes remain
hypotheses, not implemented or demonstrated optimizations. In the
existing traced two-flood/four-reader case, lifetime diagnostics had equal job
and batch counts, so configured batch size two did not imply actual pairing;
untraced measurements must establish bytes and jobs per handoff.

### Immediate nonblocking transport write candidate

The next candidate attempts one nonblocking write when bytes are freshly
staged, instead of first polling for POLLOUT. Partial writes, EINTR, and EAGAIN
retain the exact offset; subsequent attempts wait for POLLOUT. Control staging
still precedes new output, input is serviced every owner turn, and queued local
control/read results force a zero-timeout turn rather than a 10 ms idle wait.
No buffers, worker settings, flow-control bounds, or defaults changed.

Five alternating fresh-GUI pairs compared the eventfd-cleanup baseline
(`3eb95b…`) with this candidate (`833d69…`), four readers and paired-job
configuration, two idle echo panes and two repaint floods. Each 20-second phase
requested 5 MiB/s per flood; all phases delivered approximately 10.000 MiB/s
aggregate. Both variants enabled `HOLLOW_MUX_DIAGNOSTICS` through isolated
agent wrappers, redirecting stderr to per-run files without ptrace. Reported
process CPU uses the resource phase, while normalized diagnostic counters cover
the **whole agent lifetime**, including startup and teardown, not exactly the
same time window.

| Median metric | Baseline | Immediate write |
| --- | ---: | ---: |
| Linux agent CPU cores | 0.3670 | 0.3620 |
| Linux workload-worker CPU cores | 0.4065 | 0.4070 |
| Windows GUI CPU cores | 1.0537 | 1.0548 |
| Owner polls / output MiB | 802.46 | 556.64 |
| Transport write attempts / output MiB | 291.46 | 290.48 |
| PTY read attempts / output MiB | 639.92 | 638.49 |
| Read jobs / output MiB | 305.15 | 304.85 |

Agent CPU was lower in all five pairs; median reduction was approximately
1.4%, while polls/MiB fell approximately 30.6%. Agent CPU ranges were
0.3630–0.3740 and 0.3330–0.3670 cores. These small-sample results support fewer
poll calls, not a large CPU win, statistical significance, or pool/dedicated
parity. GUI and Linux measurements are separate scopes, not additive. Diagnostic
instrumentation itself may affect execution. Jobs equaled batches in each run,
confirming that batch size two did not produce actual pairing for this topology;
untraced jobs were much smaller than in the earlier ptrace capture.

All ten phases passed identity/resource/cleanup validation. Tests covered a full
nonblocking pipe, retained offsets on EAGAIN, successful partial writes and
completion, and control bytes before later bytes; `test-agent-loop` and all five
`test-agent-mux` configurations passed (23 integration cases each). Linux
x86_64/aarch64 cross-builds passed; ARM64 runtime remains untested. Read-only code
review found no actionable correctness issue. GUI echo latency and uncapped
throughput remain unqualified for this candidate. Kernel profiling was attempted
but blocked by `perf_event_paranoid=2`; no system settings were changed.

Raw local data, lifetime diagnostics, process/thread samples, binary hashes,
and validated analysis are under
`/tmp/opencode/hollow-gui-write-ab-20261020/write-analysis.json`. Harnesses are
`/tmp/opencode/hollow-gui-write-ab.py` and `hollow-gui-write-summary.py`.
The installed user GUI remains unchanged; only isolated instances used candidate
agents through explicit `agent_path` wrappers.

### Immediate-write follow-up: throughput and loaded GUI echo

After committing immediate writes as `fc9685a`, qualification compared the same
pre-write (`3eb95b…`) and immediate-write (`833d69…`) agent binaries in fresh
isolated GUIs, with four readers and batch size two. Unlike the diagnostic run
above, these agents had diagnostics **disabled**. Defaults, buffer bounds, and
the installed user GUI remained unchanged.

The resource harness completed four pairs, each with 20-second capped and
uncapped phases and no echo-input observer. The cap was 5 MiB/s per flood
(approximately 10 MiB/s aggregate). An outer-command timeout interrupted the
fifth trial: its isolated GUI was explicitly closed, all tracked identities
were subsequently verified gone, and all trial-five data is excluded. One
candidate uncapped phase in trial two had a foreground-window sample; the
entire pair is excluded from the primary uncapped comparison, not silently
treated as an equally isolated run. Earlier complete data is retained.

For the three valid uncapped pairs (trials 1, 3, 4), baseline producer-admitted
throughput median was **62.945 MiB/s** (56.416–68.215), versus **63.227 MiB/s**
(62.210–68.463). Candidate paired changes were +10.269%, +0.364%, and +0.449%:
a noisy small-sample result, not strong evidence of a transport-throughput win.
These rates count admitted producer bytes, not rendered pixels or a transport
maximum. Uncapped agent CPU medians were 0.898 versus 0.932 cores, but different
delivered rates prevent treating this as a matched-load CPU comparison.

All four complete capped pairs delivered approximately 10.000 MiB/s aggregate.
Without diagnostics, agent CPU medians were **0.391 baseline versus 0.390
candidate cores**, with ranges 0.363–0.413 and 0.353–0.420. Paired CPU changes
ranged from −14.508% to +15.838% (median −0.189%). Thus the earlier approximately
1.4% diagnostic-run reduction was not reproduced as a robust CPU advantage.
The demonstrated reduction in poll calls remains, but ordinary matched-load
CPU benefit is unresolved. Windows/Linux CPU scopes remain separate.

Loaded echo was measured separately in three fresh-GUI pairs with 1,000 echoes
per run and target switching every 100 samples between two echo panes while
two flood siblings each requested 5 MiB/s. The existing PowerShell/socket
observer checked ACK tokens in GUI-parsed text. Its latency includes command
IPC, PowerShell parsing, and text queries: it is **not keyboard-to-display
latency**, transport-only latency, or a comparison against dedicated PTYs.
These echo runs did not sample OS foreground state continuously; only pane
focus and the isolated launch location were validated.

All six echo runs passed validation: 3,000 unique, successful echoes per
variant, correct alternating target panes, completed observer metadata, and
cleanup of all tracked identities. Each flood made positive byte progress at
every recorded checkpoint interval, approximately 5 MiB/s per worker.

| GUI echo observation latency (ms) | Baseline | Immediate write |
| --- | ---: | ---: |
| Pooled 3,000-sample p50 | 10.05 | 9.86 |
| Pooled p95 | 14.63 | 14.14 |
| Pooled p99 | 17.30 | 16.42 |
| Pooled maximum | 43.59 | 37.69 |
| Median of three run p95 values | 14.61 | 14.22 |
| Median of three run p99 values | 17.44 | 16.24 |

This sample showed no echo-tail regression; it does not establish significance
or latency parity with dedicated PTYs. Pooled percentiles and median per-run
percentiles are different summaries, not interchangeable. Raw send-call and
final-query timings and poll counts remain in `echo-analysis.json` to expose
observer overhead rather than subtracting it as if it were a constant.

Raw data and validation are retained under
`/tmp/opencode/hollow-gui-write-throughput-20261020/` and
`/tmp/opencode/hollow-gui-write-echo-20261020/`. All experiments used explicit
isolated command endpoints; the original GUI was left running.

### Opus follow-up: config-only pairing pilots

An Opus 5.5 follow-up review recommended testing one reader with batch size two
against four readers with batch size two before writing an adaptive scheduler
or changing wakeup primitives. Both arms used the same immediate-write agent
(`833d69…`); only isolated test configuration changed. Two paired 20-second
diagnostic trials were attempted at each aggregate target, 10 and 20 MiB/s.
All counter ratios below cover agent lifetime, including startup/cleanup, not
exactly the resource sampling phase. These are mechanism pilots, not CPU or
latency qualification.

| Aggregate rate / summary | Four readers | One reader |
| --- | ---: | ---: |
| 10 MiB/s, two-pair median jobs/batch | 1.000 | 1.131 |
| 10 MiB/s, batches/output MiB | 302.13 | 261.30 |
| 10 MiB/s, jobs/output MiB | 302.13 | 295.66 |
| 20 MiB/s, valid pair jobs/batch | 1.000 | 1.295 |
| 20 MiB/s, batches/output MiB | 289.07 | 221.73 |
| 20 MiB/s, owner polls/output MiB | 453.62 | 462.90 |

Both arms delivered the requested aggregate rates. Pairing increased with load,
but owner turns did not decrease at 20 MiB/s. The second 20 MiB/s pair lacked
the four-reader shutdown diagnostic record; both runs of that pair are excluded
from primary paired counter comparisons. The single-reader record from that
pair showed 1.299 jobs/batch but is not substituted into a synthetic pair.
The two 10 MiB/s pairs passed validation; the 20 MiB/s pilot records one explicit
missing-diagnostics issue. All tracked processes were cleaned up.

The exploratory screen proposed after the first pilot required at least 25%
fewer batches/MiB and 10% fewer owner polls/MiB in both higher-load pairs before
a larger CPU/echo sweep. Available results do not meet that screen. No adaptive
in-flight limit, worker-count default, futex wakeup, or descriptor-lifetime
change was implemented. Limited diagnostic evidence does not rule out benefits
under other workloads, and fewer batches alone do not demonstrate CPU savings.

The review also corrected two reasoning errors: pairing primarily changes
**batches/MiB**, not necessarily jobs/MiB; submission/collection timing counters
are elapsed time including blocked scheduling, not attribution of kernel CPU.
The earlier hypothesis that handoff elapsed time proves dominant CPU cost is
not supported. In a subsequent review, Opus also withdrew owner-poll reduction
as a necessary gate: fewer batches could save worker-wake CPU even if owner
turns stay flat. The pilot therefore leaves CPU benefit unmeasured, not disproven.
Any future inline/pool adaptation needs actual matched-load CPU,
echo-tail, uncapped-throughput, and lifecycle validation before adoption.

Local artifacts: `/tmp/opencode/hollow-gui-pairing-pilot-20261020/` and
`/tmp/opencode/hollow-gui-pairing-pilot20-20261020/`, each with
`pairing-analysis.json`. Legacy directory slot names are explicitly mapped in
analysis: `inline` means four-reader baseline and `pool4` means one-reader arm;
use `run.json.read_workers`, not these names, to identify configuration.

### Current-binary inline versus pooled reads

The next config-only comparison used the same immediate-write agent
(`833d69…`, corresponding to committed `fc9685a`) with zero versus four read
workers. Batch size stayed two in both configurations; it is inert with no
workers. Diagnostics were disabled. Four alternating pairs (inline/pool,
pool/inline, inline/pool, pool/inline) each used fresh isolated GUIs with two
idle echo panes and two repaint floods. Each variant ran a 20-second phase
capped at 5 MiB/s per flood (10 MiB/s aggregate), followed by 20 seconds uncapped.
There was no echo-input observer during resource measurements.

Per-process CPU and producer progress use their respective actual timestamps.
Normalizing agent cores by admitted MiB/s is an approximate cost comparison,
not precisely matched CPU-window byte accounting. Thread sampling spans a
slightly different window from process CPU and is descriptive attribution only;
Windows GUI CPU remains a separate scope, not added to Linux CPU. Uncapped
producer-admitted throughput is neither rendered-pixel throughput nor a proven
transport maximum. No production code, user configuration, or defaults changed.

All eight runs completed both phases. All 16 phase validations passed, windows
were present/non-minimized/non-foreground in recorded samples, all tracked
identities disappeared after cleanup, and no paired data was excluded. Capped
actual rates matched within 1% in every pair (one pooled run measured 9.957
MiB/s; others approximately 10.000).

| Median metric | Inline (0 readers) | Pool (4 readers) |
| --- | ---: | ---: |
| Capped Linux agent CPU cores | 0.1925 | 0.3697 |
| Capped Windows GUI CPU cores | 1.0966 | 1.0557 |
| Capped Linux workload-worker CPU cores | 0.4505 | 0.4177 |
| Uncapped admitted throughput, MiB/s | 49.277 | 69.429 |
| Uncapped Linux agent CPU cores | 0.5770 | 0.9017 |
| Uncapped Windows GUI CPU cores | 1.4221 | 1.2602 |

Inline agent CPU was lower at matched capped load in all four pairs. The median
paired ratio of approximate agent CPU cost per admitted MiB was 0.521
(inline/pool), or approximately 48% less inline agent CPU per byte. Capped
agent CPU ranges were 0.1720–0.2205 inline and 0.3615–0.3810 pooled. However,
GUI CPU was higher inline in every capped pair; these separate measurements
do not establish net machine CPU savings.

Pooled uncapped throughput was higher in all four pairs, with broad observed
ranges: 37.043–70.177 MiB/s inline and 47.881–72.649 pooled. The ratio of
throughput medians was 0.710 (inline/pool), so inline did not meet the proposed
within-5% throughput screen. Uncapped CPU values are not matched-load comparisons.
These repeated observations support a low-load agent-CPU versus bulk-throughput
tradeoff, not statistical significance, a kernel root cause, or choosing inline
as the universally better path.

Thread counters describe where CPU was accumulated, not why: at capped load,
median owner user/system cores were 0.0151/0.1768 inline versus 0.0247/0.2220
pooled, plus 0.0117/0.1135 pooled reader cores. The separate timing windows and
medians must not be summed as an exact reconciliation to process CPU. Most
measured thread CPU was system time, but syscall/kernel attribution remains
unavailable. No echo-latency comparison between zero and four readers was run.
Adaptive inline/pool selection would require a separately designed candidate
and loaded-echo, switching/fairness, backlog, and shutdown validation; this
experiment does not implement or approve that change.

Raw resource/thread samples, launch/config/binary identities, validation, and
analysis are retained under
`/tmp/opencode/hollow-gui-inline-current-20261020/`. Harness:
`/tmp/opencode/hollow-gui-inline-current.py`; analyzer:
`/tmp/opencode/hollow-gui-inline-current-summary.py`, producing
`inline-analysis.json` in the artifact directory.

### Persistent readers with reader-side transport flush

The per-job pool (`pty_read_pool.zig`) paid, per roughly 4 KiB PTY read, a
descriptor duplicate, an eventfd wake, a worker poll, a result handoff, and an
owner wakeup. PTY master reads are capped near 4 KiB by the kernel line
discipline (about 250 reads/MiB in both modes), so that fixed overhead per read
was the gap to dedicated `pty`, which costs one poll, one read, and one write
per chunk. `src/agent/pty_readers.zig` replaces the pool when
`HOLLOW_MUX_READ_WORKERS=1..4`; zero keeps the inline owner path unchanged.

Design:

- Each stream is pinned on spawn to the least-loaded of N persistent reader
  threads. A reader owns an epoll set (level-triggered, one read per readiness,
  focused stream first) and reads straight into a per-stream 64 KiB SPSC ring,
  never more than the stream's remaining output credit. Credit plus ringed
  plus unacknowledged bytes never exceed the wire window, so a ring cannot
  overflow. Readers debit credit before publishing ring bytes, so another
  flusher can send them and the owner can accept their ACK immediately.
  A stream without credit leaves epoll (`parked`) until a grant;
  whichever side clears `parked` re-adds it, so no grant is lost.
- After a read, the reader frames ring bytes onto stdout itself under a futex
  transport lock (control first, then alternating focus-first and background
  byte-DRR turns, within the unchanged 16 KiB staging bound). Scheduler state
  survives full staging buffers, so a flooding focus or low-index stream
  cannot drain its whole window ahead of ready siblings. It never waits for the
  lock: a busy holder sees `flush_pending` after unlocking and flushes for it.
  After EAGAIN or a partial write the transport is `blocked` and only the owner
  retries, on POLLOUT; readers keep ringing until credit runs out.
- The owner still parses input, dispatches credit/close/focus, spawns, reaps,
  and emits control. It appends control and attaches/detaches slots under the
  transport lock, so `spawned` precedes a stream's output, no output is framed
  after `close`, and `exit` follows every framed byte (EOF counts only once the
  ring is empty). It wakes only for client input, EOF, detach acknowledgement,
  or a blocked/failed transport; steady output needs no owner wakeup.
- Detach is a reader command (eventfd); the reader closes the master. Epoll
  data carries a slot generation so stale events after reuse are ignored.
  `HOLLOW_MUX_READ_BATCH_JOBS` is still validated (1..2) but no longer changes
  behavior. Pool counters (`read_jobs`, `read_batches`, phase timings,
  `read_pool_reserved_high_water`) were removed; `reader_wakes`,
  `reader_parks`, and `owner_wakes` were added.

Per-MiB diagnostics (16 MiB/pane, four readers):

| Panes | owner polls | PTY reads | transport writes | reader wakes | owner wakes |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1, owner-framed intermediate | 152 | 246 | 166 | 246 | 138 |
| 1, reader flush | 30 | 246 | 250 | 247 | 0.1 |
| 4, reader flush | 28 | 236 | 200 | 236 | 2.8 |
| 32, reader flush | 30 | 254 | 86 | 87 | 0.3 |

Remaining owner polls are client credit frames (half-window batches).

Local bulk results, `scripts/agent_mux.py --mode both --runs 3 --bytes
16777216 --samples 5`, ReleaseFast, four readers, batch two, WSL2 with six
CPUs. `agent_cpu_seconds` is the agent process alone (utime+stime from
`/proc`, excluding children); the tree figure also counts Python producers.

| Panes | pty MiB/s | mux MiB/s | pty agent CPU s | mux agent CPU s |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 75.9 | 74.8 | 0.150 | 0.150 |
| 4 | 289.3 | 293.6 | 0.360 | 0.380 |
| 16 | 331.1 | 358.2 | 1.340 | 1.290 |
| 32 | 252.5 | 388.9 | 3.190 | 2.500 |

For reference, the previous pool binary (`fc9685a`, same settings) measured
mux 81/233/305/310 MiB/s against pty 75/295/367/280, and the owner-framed
persistent-reader intermediate spent 0.215 s agent CPU at one pane. Client CPU
is also lower with mux at 16–32 panes (one connection instead of N). Mixed
workload (`--workload mixed --runs 2 --samples 100`) focused-echo p99, mux
versus pty: 0.73/0.62 ms at 4 panes, 1.59/3.69 at 16, 2.98/4.64 at 32. The host
was shared and noisy; single runs varied by up to ±30%, so treat these as
parity-level observations, not significance. The isolated GUI capped-load
scenario was still unmeasured at that point; see the post-review measurements
below. Remote/SSH paths remain unmeasured.

`test_focused_echo_and_background_progress_with_output_flood` can fail under
heavy parallel host load (background `yes` makes no progress during eight fast
echoes). Under the same 12-way parallel stress it failed 5/48 on the previous
binary and 1/48 on this one; it passes in serial runs of all five configs.

Review follow-up fixed credit publication ordering and scheduling across full
staging buffers. Regression tests cover concurrent ACKs, background rotation,
and focused-flood alternation. The measurements above predate these fixes.

### Post-review persistent-reader measurements

The corrected ReleaseFast agent (`dfabad2a65ce…`) was remeasured with four
readers and batch two (accepted but inert). Headless bulk used 16 MiB per pane,
three runs, five startup echo samples, and alternating dedicated/mux order.
Values below are medians; the host was shared, with no CPU pinning or
statistical-significance claim. Agent CPU is process user+system time through
bulk completion, including startup/echo but excluding children, measured with
procfs clock-tick granularity.

| Panes | pty MiB/s | mux MiB/s | pty agent CPU s | mux agent CPU s |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 77.4 | 75.7 | 0.150 | 0.160 |
| 4 | 293.2 | 299.4 | 0.350 | 0.400 |
| 16 | 355.3 | 393.7 | 1.330 | 1.220 |
| 32 | 276.1 | 402.4 | 3.130 | 2.570 |

Thus the fixes retain the observed multi-pane throughput benefit, but these
runs show higher mux agent CPU at 1–4 panes and lower CPU at 16–32; do not
carry forward the earlier 1–4-pane CPU parity claim unchanged.

Headless loaded echo used three runs and 100 echoes per run with sustained
floods in every other pane. Median **per-run p99** was 0.72/1.06 ms mux/pty
at four panes, 1.83/4.63 ms at 16, and 1.93/3.29 ms at 32. These are not pooled
percentiles, GUI observation timings, or keyboard-to-display measurements.
Every flood made positive byte progress.

Raw repetitions, summary, source snapshots, binary/GUI hashes, and provenance:
`/tmp/opencode/hollow-mux-fixed-20261020/` (`bulk.jsonl`, `mixed.jsonl`,
`headless-analysis.json`, `provenance.json`). Capped-load GUI and GUI echo
measurements are separate experiments; headless results do not qualify them.

#### Fixed-reader GUI resource comparison

Four alternating inline/readers pairs used the same corrected agent, with
diagnostics disabled, in fresh isolated native Windows GUIs and WSL2 workers.
The four-pane layout had two idle echo panes and two repaint floods, each
capped at 5 MiB/s for 20 seconds, followed by 20 seconds uncapped. The installed
user GUI and defaults were left unchanged. `pool4` in artifact names is a
legacy label for **four persistent readers**, not the deleted per-job pool.

All eight runs and 16 phases passed resource, process/thread identity, Lua
configuration, binary identity, window, and cleanup checks. Recorded windows
were present, non-minimized, and non-foreground. All tracked workers and agents
were verified gone after each run. No pair was excluded. Capped admitted rates
matched within 1% in every pair (both variants approximately 10.000 MiB/s).

| Median GUI experiment metric | Inline (0 readers) | Persistent readers (4) |
| --- | ---: | ---: |
| Capped Linux agent CPU cores | 0.1790 | 0.1717 |
| Capped Windows GUI CPU cores | 1.0491 | 1.0574 |
| Uncapped producer-admitted throughput, MiB/s | 69.78 | 81.46 |
| Uncapped Linux agent CPU cores | 0.6242 | 0.8160 |
| Uncapped Windows GUI CPU cores | 1.4792 | 1.6490 |

At matched capped load, readers used less agent CPU in every pair: reductions
were 3.63%, 4.20%, 5.59%, and 5.69% (median paired reduction 4.89%). Agent CPU
ranges were 0.1785–0.1845 inline and 0.1690–0.1740 reader cores. The earlier
pool's roughly doubled capped-load CPU did not recur in this same-binary
inline/readers comparison; that historical pool series was not rerun here.
GUI CPU showed no consistent paired advantage at capped load. Windows and
Linux CPU remain separate measurements, not summed as machine CPU.

Uncapped reader throughput improved in three pairs (+17.52%, +17.66%, +15.96%)
and regressed in the fourth (−19.78%): **54.43 versus 67.85 MiB/s**. This valid
slow run is retained, not discarded as noise. Both floods slowed together
(27.12 and 27.31 MiB/s), with no observed per-pane starvation. Reader throughput
ranged 54.43–82.97 MiB/s versus inline 67.85–70.52. The 16.74% ratio-of-medians
gain is therefore not a universal win or statistical-significance claim.
Higher uncapped CPU is not a matched-throughput comparison. Admitted producer
bytes are not rendered pixels or a proven transport maximum; CPU and producer
progress use slightly different sampling windows.

Artifacts: `/tmp/opencode/hollow-gui-readers-fixed-20261020/`, including
`inline-analysis.json`. Reproducible wrappers:
`/tmp/opencode/hollow-gui-readers-fixed.py` and
`/tmp/opencode/hollow-gui-readers-fixed-summary.py`. Loaded echo was measured
separately below. Dedicated-versus-mux GUI qualification remains separate;
defaults remain unchanged.

#### Fixed-reader loaded GUI echo

Three alternating fresh-GUI pairs compared zero versus four readers using the
same corrected agent and two 5 MiB/s repaint floods. Each run completed 1,000
unique echoes, switching focus between the two echo panes every 100 samples.
All six runs passed validation: complete ordered tokens and metadata, correct
pane/focus targets, positive flood progress in every checkpoint interval, actual
per-flood rates within 1% of 5 MiB/s, and cleanup of all tracked identities.
The original user GUI remained running with its original process identity.

| GUI echo observation latency (ms) | Inline (0 readers) | Persistent readers (4) |
| --- | ---: | ---: |
| Pooled 3,000-sample p50 | 12.11 | 11.83 |
| Pooled p95 | 17.01 | 16.63 |
| Pooled p99 | 19.76 | 19.70 |
| Pooled maximum | 65.31 | 54.75 |
| Median of three run p99 values | 19.46 | 19.69 |

Individual reader/inline p99 pairs were 19.69/19.32, 18.92/19.46, and
20.72/20.25 ms. Tail directions are mixed and pooled p99 is nearly identical;
this sample establishes neither a clear tail improvement nor regression.
Pooled percentiles and median per-run percentiles are different summaries.

The observer measures GUI command IPC and PowerShell parsing/text-query time
from `pane_send_text` through an ACK visible in parsed pane text. It is **not
keyboard-to-display latency**, isolated PTY latency, or a dedicated-PTY
comparison. Raw send/query/poll timings are retained, not subtracted as a
constant. The isolated GUI launched on DISPLAY2 while the user's foreground
screen was DISPLAY1; unlike the resource runs, these echo runs did not sample
OS foreground/window state continuously.

Artifacts: `/tmp/opencode/hollow-gui-readers-fixed-echo-20261020/`, including
`echo-analysis.json`; wrappers:
`/tmp/opencode/hollow-gui-readers-fixed-echo.py` and
`/tmp/opencode/hollow-gui-readers-fixed-echo-summary.py`. Legacy directory names
`baseline` and `candidate` mean inline and four readers of the **same binary**.
Defaults remain unchanged; remote/SSH and dedicated-versus-mux GUI results are
still not qualified.

### Fixed mux versus dedicated PTYs in the GUI

The next experiment compared **dedicated `pty` versus mux with four persistent
readers**, using the same corrected ReleaseFast agent (`dfabad2a65ce…`) and the
same installed native Windows GUI. Both domain definitions explicitly selected
that agent; startup checks verified each live agent executable's SHA-256,
command, process topology, and thread count. Dedicated used four one-thread
agents; mux used one five-thread agent. Diagnostics were disabled.

Four fresh-GUI pairs alternated dedicated/mux order (AB, BA, AB, BA). Each
four-pane layout had two echo panes and two repaint floods: 20 seconds capped
at 5 MiB/s per flood, then 20 seconds uncapped. All eight runs and 16 phases
passed process identity, rate, sampling, non-minimized/non-foreground window,
and cleanup checks. Every capped pair matched actual admitted throughput within
1%. No completed pair was excluded.

| Median resource metric | Dedicated `pty` | Fixed mux (4 readers) |
| --- | ---: | ---: |
| Capped admitted throughput, MiB/s | 10.000 | 10.000 |
| Capped Linux agent CPU cores | 0.1717 | 0.2024 |
| Capped Linux workload CPU cores | 0.4192 | 0.5017 |
| Capped Windows GUI CPU cores | 1.0082 | 1.1075 |
| Uncapped admitted throughput, MiB/s | 68.57 | 65.40 |
| Uncapped Linux agent CPU cores | 0.8279 | 0.8211 |
| Uncapped Windows GUI CPU cores | 1.2341 | 1.6516 |
| Capped sampled peak summed agent RSS, MiB | 3.375 | 0.719 |
| Capped sampled peak GUI working set, MiB | 167.58 | 153.68 |

At matched capped load, mux GUI CPU was higher in all four pairs (+10.53%,
+14.74%, +6.43%, +5.63%). Agent CPU directions were mixed (+22.84%, +23.63%,
−0.47%, −1.42%), as were workload CPU directions. Therefore the earlier
reader-versus-inline CPU improvement does **not** establish dedicated-versus-mux
GUI CPU parity or an overall CPU win. Linux and Windows scopes remain separate.

Uncapped mux throughput changes were −31.79%, −2.80%, +22.45%, and +9.82%:
two wins and two losses, with ranges 56.38–84.31 MiB/s mux and 58.01–83.39
dedicated. All runs are retained. The ratio of throughput medians is about
4.62% lower for mux; this noisy sample is not a general parity result. Uncapped
CPU is not matched-load CPU, and admitted producer bytes are not rendered pixels
or a transport maximum. CPU and producer progress windows differ slightly.

Sampled summed agent RSS was about 78.7% lower with mux, with 75% fewer agent
processes. These are short-run RSS snapshots, potentially double-counting
shared pages in the dedicated sum, not a long-term leak or machine-memory claim.

An earlier dedicated-only pilot is retained separately under
`/tmp/opencode/hollow-gui-dedicated-mux-fixed-20261020/`. Its two phases completed,
but the harness incorrectly treated PowerShell's "process already absent"
exit status as a cleanup failure after the GUI had closed. All tracked Linux
identities were gone. The checker was corrected and the entire paired series
restarted fresh; the pilot is excluded from primary results.

Primary artifacts: `/tmp/opencode/hollow-gui-dedicated-mux-fixed-20261020-v2/`
(`analysis.json`); wrappers:
`/tmp/opencode/hollow-gui-dedicated-mux-fixed.py` and
`/tmp/opencode/hollow-gui-dedicated-mux-fixed-summary.py`. Loaded echo and soak
are separate experiments. Defaults remain unchanged.

#### Dedicated-versus-mux loaded GUI echo

Three alternating fresh-GUI pairs used the same fixed agent in dedicated and
mux modes, with two independent 5 MiB/s repaint floods and 1,000 echoes per
run. Focus switched between the two echo panes every 100 samples. All six runs
passed validation: 3,000 ordered, unique successful echoes per mode, correct
pane targets, complete observer metadata, positive progress at every flood
checkpoint interval, actual per-flood rates within 1% of the cap, and cleanup
of all tracked identities. Agent command/topology/thread counts matched each
mode; both domain configurations selected the same explicit agent binary.

| GUI echo observation latency (ms) | Dedicated `pty` | Fixed mux (4 readers) |
| --- | ---: | ---: |
| Pooled 3,000-sample p50 | 9.98 | 9.60 |
| Pooled p95 | 14.85 | 13.89 |
| Pooled p99 | 18.82 | 16.31 |
| Pooled maximum | 38.67 | 55.37 |
| Median of three run p99 values | 18.89 | 15.69 |

Per-run mux/dedicated p99 pairs were 15.26/17.02, 15.69/18.89, and
19.61/19.31 ms. The pooled p99 is about 13.3% lower with mux, but the third
pair's p99 and the pooled maximum were higher. This descriptive sample is not
a universal tail-latency win or statistical-significance claim, and does not
erase the separate matched-load GUI CPU cost.

Timings include GUI command IPC and PowerShell parsing/text observation through
an ACK visible in pane text, **not keyboard-to-display or isolated PTY latency**.
Raw send/query/poll timings are retained. GUI panes/focus were validated, but
OS foreground/window state was not continuously sampled during these echo
runs; the stricter window checks apply to the resource experiment above.

Artifacts: `/tmp/opencode/hollow-gui-dedicated-mux-fixed-echo-20261020/`, including
`echo-analysis.json`; wrappers:
`/tmp/opencode/hollow-gui-dedicated-mux-fixed-echo.py` and
`/tmp/opencode/hollow-gui-dedicated-mux-fixed-echo-summary.py`. Legacy directory
labels `baseline`/`inline` mean dedicated PTYs and `candidate`/`pool4` mean
four-reader mux in this experiment; use `run.json.mode`, not those labels.

#### GUI soak blocked by focused-pane close use-after-free

The planned 600-second GUI soak **did not complete**. It was intended to keep
two repaint floods at 5 MiB/s each while checking ACKs, switching focus,
requesting resizes, and repeatedly creating/closing temporary panes, with
process, RSS, descriptor, and Windows memory telemetry. Do not treat the A/B
resource snapshots or subsequent agent-only tests as a passed GUI soak.

The first attempt stopped after about 38 seconds at a temporary worker
readiness timeout; original floods still progressed and tracked processes were
cleaned up. A file-backed churn worker removed inline Python/shell quoting
from the protocol. Follow-up preflight attempts reached temporary-pane output
but lost the GUI when closing that focused pane. Capturing the GUI's actual
stderr and exit status confirmed **exit code 3 / segmentation fault**, not a
mere focus-readiness delay:

```text
src/term/program_status.zig:116  State.setFocused
src/app.zig:1518                syncActivePaneChange
src/app/session_controller.zig:305  closePaneById
```

Current source confirms a stale-pointer path: `closePaneById` saves
`mux.activePane()` as `previous`, calls `mux.closePaneById` (which reaches
`Tab.closePane`, deinitializing and destroying that pane), then calls
`syncActivePaneChange(previous, mux.activePane())`. That function dereferences
the freed previous pane in `program_status.setFocused(false)` and also in
render-cache invalidation. The installed GUI and current source agree on the
failing path. No GUI source fix was made during this measurement task.

A simple dedicated control closing an original pane did not crash. A matched
**dedicated-mode** control with focus changes, resize requests, a temporary
split, and focused close reproduced the same stack and exit code 3. Thus this
is a shared GUI lifecycle defect, not unique to mux readers; failure depends
on the exercised lifetime/allocation sequence. It blocks lifecycle
qualification until fixed and retested.

Artifacts:

- Initial incomplete run: `/tmp/opencode/hollow-gui-mux-fixed-soak-20261020/`.
- Preflights: `/tmp/opencode/hollow-gui-mux-fixed-soak-preflight-20261020/` and
  `/tmp/opencode/hollow-gui-mux-fixed-soak-preflight-20261020-v2/`; the latter
  retains `gui/gui-stderr.log`, `gui/gui-exit.json`, and pre-close pane state.
- Matched dedicated reproduction:
  `/tmp/opencode/hollow-gui-focused-close-dedicated-churn-control-20261020/`.
- Protocol and runner: `/tmp/opencode/hollow-gui-mux-fixed-soak-protocol.json`
  and `/tmp/opencode/hollow-gui-mux-fixed-soak.py`; file-backed worker and
  stderr-capturing launcher are alongside them.

Tracked test workers/agents were verified gone, and only the original user GUI
remained, with its unchanged process identity. Because the GUI soak was blocked,
the agent-only fault/lifecycle suites were run **separately**, serially: ten
repetitions at each reader count 0, 1, 2, 3, and 4, batch two, against the same
fixed agent. All **50 suites / 1,150 test invocations passed**, covering stopped
consumers, blocked child input, close/slot reuse, final output, malformed
credits, and disconnect cleanup. Logs and summary:
`/tmp/opencode/hollow-mux-fixed-serial-faults-20261020/`.

Those passes do not qualify GUI pane teardown, SSH/container faults, ARM64,
long-term leaks, or the failed 600-second soak. Defaults remain unchanged.

#### Pane-close lifetime correction

The follow-up fix in `src/app/session_controller.zig` prevents the stale pointer
from reaching focus synchronization: when the close target is the active pane,
`previous` is set to null **before** `mux.closePaneById` destroys it. A surviving
previous pane is still retained when closing a background pane. The new active
pane still receives program-status focus, attention clearing, render-cache
invalidation, and terminal callback registration through the existing helper.

An App-level regression exercises three focused split/close cycles, a background
close, and an invalid ID using a real terminal runtime. App allocations use the
testing allocator; mux/pane allocations use the page allocator so closing a pane
immediately unmaps its storage. The initial small-object-allocator version also
passed with old code because the freed storage stayed mapped; it was strengthened
to expose the invalid access rather than depend on incidental heap layout.
The strengthened regression passes with the fix and crashes at the original
`State.setFocused` access when only the old close implementation is restored in
an isolated source copy. That negative control recorded 331 passes and one
crash; it is an expected regression-test failure, not a failure of fixed code.
Logs: `/tmp/opencode/hollow-pane-close-tests-guarded.log` and
`/tmp/opencode/hollow-pane-close-regression-old-guarded.log`.
It checks surviving focus and attention acknowledgement, rather than merely
testing pointer selection in isolation. The native Debug test graph passed all
332 tests (238 main tests plus renderer/dependency tests); the final strengthened
test also passed the ReleaseFast graph's 332 tests. This machine needed
existing Nix library/header search prefixes; earlier missing-library/header
attempts were build-environment failures, not test failures. The helper is
`/tmp/opencode/hollow-pane-close-native-tests.py`, with successful output in
`/tmp/opencode/hollow-pane-close-tests-nix-complete.log`.

A new ReleaseFast/PDB Windows GUI was built under
`/tmp/opencode/hollow-pane-close-fixed-20261020/`, without replacing the installed
GUI. Its SHA-256 is `abd4166e0c691a66bb11f3218e34fb12877da42e93694e2b321fbf018a1a8c6f`.
The mux agent remains the previously measured fixed binary (`dfabad2a65ce…`).
The isolated mux preflight and matched dedicated temporary-pane control both
completed the previously crashing sequence and closed cleanly; all tracked
process identities were gone. Artifacts:
`/tmp/opencode/hollow-gui-pane-close-fixed-preflight-20261020/` and
`/tmp/opencode/hollow-gui-pane-close-fixed-dedicated-control-20261020/`.
The first fixed-GUI soak ran for 603.47 seconds without a GUI crash, with 12
successful lifecycle cycles and a clean exit. Agent descriptors returned to 18
after each close (sampled maximum 19), and warm/late median agent RSS was
884,736 bytes in both windows. However, it **failed its coverage gate** of at
least 13 cycles: serial CLI/PowerShell calls plus an extra 15-second idle delay
limited cycle density. That failed-gate run is retained under
`/tmp/opencode/hollow-gui-pane-close-fixed-soak-20261020/`; its post-GUI fault
phase did not run. Removing the extra post-cycle idle delay increases churn
without lowering the original gate. Passing short controls or the first run's
runtime alone is not a passed full protocol.

The denser rerun **passed the full protocol**: 604.03 seconds, 1,206 Linux
samples, **18 successful split/close lifecycle cycles**, 36 unique echo ACK
checks, and 36 resize requests. Every temporary worker was verified gone after
close, focus returned to the original echo pane, and the agent descriptor count
returned to its baseline of 18 after every cycle (sampled peak 19). Five agent
threads remained live. Both floods progressed throughout, averaging 4.9957 and
4.9967 MiB/s, within the unchanged 1% cap tolerance.

Warm and late median agent RSS were both **753,664 bytes** (zero delta). Windows
telemetry recorded 352 GUI samples, all with a present, non-minimized window and
none foreground. GUI working set changed from 150.20 to 161.43 MiB, private
bytes from 340.78 to 358.42 MiB, and handles from 1,091 to 1,089. These are
recorded observations, **not proof of no GUI leak**: no post-hoc GUI memory
threshold was imposed, and ten minutes does not establish long-term stability.
The requested Windows sampling cadence was one second, but per-sample process
enumeration made actual intervals longer; these are sampled values, not
continuous memory or window-state observations. Resize commands were issued;
exact terminal dimensions remain covered by separate integration tests.

The isolated GUI exited with code zero, with no new crash in stderr, and all
tracked workers/agents were verified gone. The subsequent serial fault phase
passed **50 suites / 1,150 test invocations**: ten repetitions at each reader
count 0–4 with batch two. The original installed GUI remained running with its
unchanged PID/start identity. No installed binary or backend default changed.

Successful-run artifacts:
`/tmp/opencode/hollow-gui-pane-close-fixed-soak-20261020-v2/` (`result.json`,
`gui/lifecycle-events.json`, Linux/Windows samples, GUI exit/stderr, cleanup, and
`faults/` logs). Native final test logs:
`/tmp/opencode/hollow-pane-close-tests-guarded.log` and
`/tmp/opencode/hollow-pane-close-tests-releasefast-final.log`. Source/binary
hashes and the fix patch are under
`/tmp/opencode/hollow-pane-close-validation-20261020/`. Only the regression
test's allocator was strengthened after the isolated GUI build; production fix
and measured agent were unchanged.

This closes the focused-pane crash and the measured ten-minute WSL GUI soak
gate, not the outstanding SSH/container, ARM64, extended soak/fault, tooling
reproducibility, or performance/default-rollout gates.

### Windows client notification experiments

Thread CPU measurements localized the matched-load Windows mux overhead to
background transport workers rather than the main GUI thread. These are thread
CPU counters with symbolized thread entry points, not sampled call stacks; they
do not attribute individual instructions or establish that rendering never
contributes under other workloads. Windows/Linux CPU scopes remain separate.

Two client-only experiments retained the same explicit Linux agent and two
5 MiB/s floods in isolated fresh GUIs. Builds used Windows ReleaseFast with PDBs;
the installed GUI and user defaults were not changed.

1. **Credit-boundary notifications:** skip writer/watchdog wakeups on output
   frames except at existing credit boundaries. Across two alternating triplets,
   median Windows process CPU was 1.007 cores dedicated, 1.075 mux, and 1.045
   candidate; candidate/mux changes were -4.43% and -1.01%. However, two
   alternating loaded echo pairs (1,000 samples per run) showed median run p50
   increasing from 9.06 to 9.77 ms and p99 from 15.69 to 16.78 ms. This version
   was removed, not promoted.
2. **Separate watchdog condition:** preserve every writer notification, but wake
   the watchdog only for lifecycle changes and its existing 50 ms timeout.
   Across two alternating triplets, median process CPU was 0.987 cores dedicated,
   1.044 mux, and 1.016 candidate; candidate/mux changes were -4.86% and -0.49%.
   Transport-worker CPU fell from 0.120 to 0.090 cores. In the first pair,
   watchdog CPU fell from 0.0146 to 0.0008 cores. Initial loaded echo pairs still
   showed higher median run p50 (8.80 to 9.28 ms) and p99 (14.36 to 15.54 ms).
   Confirmation could not start: the launcher found no separate 1920-wide
   monitor and stopped before creating a GUI. This is an environment blocker,
   not a candidate failure or an additional latency sample. Latency parity is
   not established; neither candidate is retained in production source. The
   watchdog-only patch is saved externally for further investigation.

All reported phases passed rate and cleanup validation. Echo values measure the
GUI IPC/PowerShell ACK observer, not physical keyboard-to-display latency. Two
pairs are insufficient to establish exact performance effects or explain the
latency difference causally. A fresh baseline rebuild reproduced the original
executable SHA-256 exactly, ruling out a stale baseline binary for this check.

The watchdog-only candidate passed 36 ReleaseFast client integration tests, two
Python pane-benchmark tests, and 17 directly imported Zig unit tests, including
watchdog frame classification. Those unit tests were run separately rather than
assuming the integration target includes them.

Artifacts under `/tmp/opencode/`:

- `hollow-win-mux-cpu-clean-20261020/analysis.json` and
  `hollow-win-mux-notify-echo-20261020/analysis.json`: first experiment.
- `hollow-win-mux-cpu-watch-20261020/analysis.json` and
  `hollow-win-mux-watch-echo-20261020/analysis.json`: watchdog-only experiment.
- `hollow-win-mux-watch-confirm-20261020/`: blocked confirmation attempt,
  launcher error and executable provenance; no measurement completed.
- `watch-candidate.patch`: watchdog-only patch, not an installed or qualified fix.

Follow-up exploration keeps the watchdog-only binary as a candidate rather than
treating a sub-millisecond observer shift as a proven user-visible regression.
The follow-up ran two alternating identical-binary A/A pairs, followed by
four alternating baseline/candidate A/B pairs, with 1,000 ACK samples per run.
All runs must share window geometry, two 5 MiB/s floods, and verified cleanup.
Compare pair-level percentile shifts; do not treat thousands of correlated ACKs
as independent experimental runs. Two A/A pairs provide an exploratory noise
check, not a reliable noise bound or statistical equivalence test.

Windows now reports the spare landscape display as 1536 pixels wide in the
launcher's coordinate space. The temporary follow-up launcher accepts a separate
non-primary landscape monitor instead of requiring exactly 1920 pixels. It
still refuses to use the foreground user's display. These new measurements
must not be pooled with the earlier geometry. Artifacts:
`/tmp/opencode/hollow-win-watch-aa-20261020/`,
`/tmp/opencode/hollow-win-watch-ab-20261020/`, and
`/tmp/opencode/hollow-win-watch-noise-analysis.json`.

All 12 runs completed, with 1,000 unique ACKs per run, validated load and cleanup,
and identical reported geometry `{X=-1920,Y=227,Width=1536,Height=912}`. Binary
hashes confirmed A/A really used the same executable and A/B used distinct
baseline/candidate executables. One A/A run averaged about 4.985 MiB/s per flood,
within the pre-existing 0.05 MiB/s tolerance; it was retained, not excluded.

| Statistic | A/A paired shifts (ms) | A/B paired shifts (ms) | Median A/B paired shift (ms) |
| --- | --- | --- | --- |
| p50 | -0.300, -1.444 | +0.158, +0.531, -0.355, -0.093 | +0.0325 |
| p95 | -0.335, -3.823 | +0.774, +0.220, -0.228, -0.065 | +0.0771 |
| p99 | -1.152, -10.844 | +4.544, +0.308, -0.716, -0.339 | -0.0154 |

Positive means the candidate-labelled run was slower. These are differences of
run percentiles within each pair, not pooled ACKs or differences of group
medians. The latter are p50 13.904 -> 14.144 ms and p99 19.733 -> 20.479 ms for
A/B. Both summaries matter: one candidate run had a +4.54 ms p99 shift, despite
near-zero median paired change. Two A/B pairs favored each binary at every
reported percentile. The identical-binary controls show material observer/run
variation, so the earlier small shift is not sufficient evidence of a consistent
candidate regression. This does not prove equivalence or establish a safe tail
latency bound. The watchdog-only candidate remains worth exploring.

A four-triplet CPU recheck completed at this same geometry under
`/tmp/opencode/hollow-win-watch-cpu-recheck-20261020/analysis.json`, using dedicated,
baseline mux and watchdog-only mux binaries. All 12 phases passed validation;
all launch records reported the same 1536-by-912 geometry as the echo follow-up.

| Windows CPU scope (median cores) | Dedicated | Baseline mux | Watchdog-only mux |
| --- | --- | --- | --- |
| Whole process | 0.74954 | 0.81170 | 0.76800 |
| Main thread | 0.60104 | 0.61304 | 0.58683 |
| Transport workers | 0.05442 | 0.11263 | 0.07401 |

Whole-process candidate/mux changes by pair were -9.30%, -3.40%, -5.10%, and
+2.27%; the median paired change was -4.25%. The ratio of group medians instead
shows a 5.38% reduction; these are different statistics, not conflicting claims.
Transport worker CPU fell in every pair, with group medians down 34.3%. Baseline
watchdog CPU ranged from 0.0119 to 0.0197 cores; candidate watchdog deltas were
zero at the counters' resolution, not proof that the watchdog does no work.
Main-thread and driver variation still affect the whole-process result, and one
candidate process used more CPU despite its lower transport-worker cost.

The evidence supports retaining watchdog separation as an experimental
candidate: reduced transport work is repeatable, while the new A/B latency
pairs do not show a consistent penalty beyond the observed A/A variation.
It does not qualify default rollout, prove latency equivalence, or imply
full mux/dedicated parity. No further scheduling or reader/writer changes have
been made. The remaining candidate transport cost is primarily in the reader
thread; thread entry-point counters alone cannot distinguish copying, locking,
parsing or notification costs inside that thread. Sampled Windows call stacks
or controlled instrumentation are needed before choosing the next optimization.

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
| 12 focus | client → agent | nonzero | Empty; select focus-first scheduling and doubled byte quantum |

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
  frames. Inline mode has no per-stream output ring.
- Separate 64 KiB logical control queue, not charged against data windows.
- With persistent readers, one 64 KiB SPSC ring per attached stream (at most
  2 MiB at 32 streams), bounded by each stream's existing output credit.
  Inline mode allocates none of these rings; there is no per-job result pool.
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
Focus-first selections alternate with background selections without moving the
background cursor; focused traffic therefore need not wait for a complete
background round, while background byte progress remains bounded.
Persistent readers instead pin each stream to one reader's epoll set and read
directly into its credit-bounded ring. Readers flush complete frames under the
shared transport lock; the owner retries blocked transport writes. Focus and
background rotation remain bounded; `batch_jobs` does not create read jobs.
See [reader ownership and scheduling](#persistent-readers-with-reader-side-transport-flush).
In inline mode, ready output frames share the staging bound, with at most 32 read
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
The GUI pool supplies effective-host identity, concurrent bootstrap/cancellation,
failure fan-out, and application shutdown ownership. It retains no idle
connection after the last live pane closes; a later pane starts a fresh one.
