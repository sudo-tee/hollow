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
