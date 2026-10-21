# Windows mux client CPU investigation

Mux remains opt-in. This investigation changes only Windows-client notification
routing, not protocol credits, buffers, writer scheduling, deployment defaults,
or the installed application.

## Watchdog notification separation

The mux writer and watchdog previously waited on the same condition. Every
received output frame and UI consumption notification woke both threads, even
though normal output traffic does not change a watchdog deadline.

The watchdog now has a separate condition. Registration, pane close, shutdown,
connection completion, and hello/exit/error frames wake it. Its existing 50 ms
timeout still checks bootstrap deadlines, stalled writes, and overdue closes.
All writer notifications remain unchanged, including every output frame.

A prior experiment batching writer notifications at credit boundaries was
discarded. It is not part of this change.

## Measurements (October 20, 2026)

Fresh Windows ReleaseFast GUIs used the same explicit Linux agent, four panes,
and two output producers capped at 5 MiB/s each. Windows thread CPU counters and
symbolized thread entry points locate work by thread, not by sampled instruction
or call stack. Linux and Windows CPU scopes must not be added together.

### CPU

Four alternating dedicated/mux/candidate triplets used 20-second measurements
and identical reported window geometry, 1536 by 912. All phases passed load,
window, and cleanup validation.

| Median Windows CPU (cores) | Dedicated | Mux before | Mux after |
| --- | ---: | ---: | ---: |
| Whole process | 0.74954 | 0.81170 | 0.76800 |
| Main thread | 0.60104 | 0.61304 | 0.58683 |
| Transport workers | 0.05442 | 0.11263 | 0.07401 |

Transport-worker CPU fell in every pair, with group medians down 34.3%.
Whole-process changes were -9.30%, -3.40%, -5.10%, and +2.27%: median paired
change -4.25%. The ratio of whole-process group medians instead shows -5.38%;
these are different summaries. Main-thread and graphics-driver variation affect
process totals. Watchdog CPU fell below the counters' measured resolution, not
literally to zero work. Remaining transport cost is primarily in the reader.

### Latency and observer noise

Two alternating identical-binary A/A pairs and four alternating baseline versus
candidate A/B pairs used the same geometry and load, with 1,000 unique ACKs per
run. Executable hashes, geometry, producer rates, and cleanup were validated.
One A/A run averaged 4.985 MiB/s per producer, within the existing 0.05 MiB/s
tolerance; it was retained.

| Run-pair percentile difference | p50 | p95 | p99 |
| --- | ---: | ---: | ---: |
| Median A/B paired change (ms) | +0.0325 | +0.0771 | -0.0154 |
| A/A pair 1 (ms) | -0.300 | -0.335 | -1.152 |
| A/A pair 2 (ms) | -1.444 | -3.823 | -10.844 |

Two A/B pairs favored each executable. One candidate run had a +4.54 ms p99
shift, so tail variation must not be hidden by the near-zero median paired
change. These values measure GUI IPC/PowerShell ACK observation, not physical
keyboard-to-display latency. Thousands of ACKs are not thousands of independent
experimental runs. The controls expose substantial variation, but two A/A pairs
do not establish a reliable noise bound or prove latency equivalence.

The evidence supports retaining this narrowly scoped optimization, not claiming
full mux/dedicated parity or changing defaults. Earlier runs at a different
window geometry must not be pooled with this follow-up.

## Validation and artifacts

```sh
zig build --build-file build-agent.zig test-agent-pty test-agent-pane-bench \
  -Doptimize=Debug -j1 --prefix /tmp/opencode/hollow-watch-commit-tests --summary all
```

The client suite passed 36 tests, including watchdog frame classification and
bounded bootstrap, close, shared shutdown, and backpressure checks. Two Python
pane-benchmark smoke tests passed. ReleaseFast client tests and a Windows
ReleaseFast build with PDBs also passed during qualification.

Local investigation artifacts (not portable benchmark fixtures):

- `/tmp/opencode/hollow-win-watch-cpu-recheck-20261020/analysis.json`
- `/tmp/opencode/hollow-win-watch-aa-20261020/analysis.json`
- `/tmp/opencode/hollow-win-watch-ab-20261020/analysis.json`
- `/tmp/opencode/hollow-win-watch-noise-analysis.json`

Next work: distinguish reader copying, locking, and notification costs using
sampled call stacks or controlled diagnostic instrumentation before choosing
another scheduling change.

## Reader follow-up

A temporary diagnostic binary sampled every sixteenth output admission in two
30-second capped-load runs. Both passed load and cleanup validation. Connection
lifetime counters include setup and drain beyond the measurement checkpoints.
The diagnostic binary is not installed; its instrumentation was removed from
production source after compilation and saved in
`/tmp/opencode/hollow-reader-diagnostics.patch`.

| Sampled mean elapsed time per output frame | Run 1 | Run 2 |
| --- | ---: | ---: |
| Connection mutex acquisition | 0.187 us | 0.265 us |
| Session mutex acquisition | 0.045 us | 0.049 us |
| Output admission | 0.428 us | 0.447 us |
| Pane wake | 0.183 us | 0.173 us |
| Writer broadcast | 3.449 us | 2.829 us |
| Entire `accept()` | 4.613 us | 4.068 us |

These are instrumented elapsed-time samples, including preemption and clock
overhead, not CPU attribution. Transport reads and frame decoding are excluded.
Periodic sampling may also bias frame selection. No prefix compaction occurred;
only 22 and 18 append-buffer growth events occurred across roughly 354 MiB per
run. Mean output frames were 2555 and 2262 bytes. The writer had a registered
waiter on 97.4% and 95.9% of output notifications.

This motivates testing notification coalescing across complete frames already
buffered by the reader. Unlike the discarded credit-boundary experiment, it
must flush before a read that could block, on control frames, and at bounded
frame/byte limits; it must never wait for more data to form a batch. Uninstrumented
CPU and loaded echo measurements must qualify it separately against the committed
watchdog-only baseline before retaining another change.

Diagnostics:
`/tmp/opencode/hollow-win-reader-diagnostics-20261020/reader-analysis.json`.

### Already-buffered notification experiment: not retained

The follow-up candidate deferred writer notifications only when another complete
frame was already buffered. It flushed at control frames, before reads that
could block, or after 16 frames/64 KiB. Debug validation passed 37 client tests
and two pane-benchmark tests; the Windows ReleaseFast build passed.

Four alternating uninstrumented CPU pairs compared it to the committed
watchdog-only baseline at matched 10 MiB/s load and 1536-by-912 geometry. All
eight CPU phases passed validation. Whole-process changes were -1.41%, +11.97%,
+17.18%, and +2.61% (median paired change +7.29%). Transport-worker changes were
+4.52%, -12.96%, +11.21%, and -6.45%: two better, two worse. Group medians were
0.80930 -> 0.82430 process cores and 0.09531 -> 0.09122 transport-worker cores.
The latter small aggregate decrease does not establish a repeatable win, and
main-thread variation prevents attributing the process regressions specifically
to notification code.

The loaded echo comparison did not complete: its first baseline run finished,
but the candidate launcher constructed a nonexistent executable path and failed
before starting the candidate. This was a harness bug, not a candidate crash or
latency result. The temporary harness was corrected to accept explicit executable
paths and check their existence, but no rerun was justified by the inconclusive
CPU result. Do not infer a latency outcome from that incomplete pair.

The experiment was removed from source. Commit `24f83ae` remains the retained
watchdog optimization; no additional writer scheduling change is retained.
Temporary instrumentation, binaries and raw artifacts remain under
`/tmp/opencode/` for further investigation:

- `hollow-buffered-notify.patch`
- `hollow-buffered-notify-cpu-20261020/analysis.json`
- `hollow-buffered-notify-echo-20261020/` (incomplete)

Further optimization needs a more direct CPU attribution or measured reduction
in actual notification work, rather than assuming lower elapsed time or fewer
potential notifications guarantees lower process CPU.
