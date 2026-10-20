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
Focus-first selections alternate with background selections without moving the
background cursor; focused traffic therefore need not wait for a complete
background round, while background byte progress remains bounded.
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
