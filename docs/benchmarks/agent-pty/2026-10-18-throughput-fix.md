# Dedicated PTY throughput investigation

Scope: Linux client inside WSL2, one connection per agent PTY, no window/GPU or
legacy WSL bypass. Native means the existing POSIX PTY. Production defaults are
unchanged. All numbers below are local evidence, not rollout approval.

## Root cause and fixes

The agent dispatched `WINDOW_UPDATE` at the end of its loop. If a PTY capture
buffer was already full, its master was excluded from the next read poll. When
credit restored readiness, no new kernel event was required or guaranteed: the
agent could sleep for its 20 ms poll timeout with DATA already ready to send.

Optional counters confirmed this: five 100 MiB runs showed 102–115 poll stalls
of at least 1 ms while credited output was buffered, totaling 2.27–2.54 seconds
inside those ready-output polls per run. Scheduling bounded buffered output
**before** constructing the next poll set removed all such waits in the repeated
experiment. It preserves the 16 KiB DATA ceiling, existing credit and queue caps,
and connection-scoped cleanup. A deterministic loop regression restores credit
to a full 64 KiB capture and verifies queued DATA before the next poll.

A second cost came from transient host allocations: every DATA payload and every
8-byte credit update was allocated/freed. DATA now borrows a 16 KiB reader scratch
buffer until copied into bounded owner storage; credit payloads live inline in
the bounded outbound queue. Metadata ownership is unchanged. Allocation-failure
tests verify both hot paths require no allocation, and a full queue does not
consume output. This is not the rejected read-ahead experiment: no additional
bytes are read or credited early.

## Allocator correction

The original benchmark used `page_allocator`, while Hollow GUI uses
`DebugAllocator(.{ .thread_safe = true })`. The page allocator exaggerated the
cost of allocating each frame, so its 16–17% ratio must not be described as a
measurement of GUI runtime performance. The benchmark now labels and selects
`debug`, `page` or `smp`; the default matches the GUI's `debug` allocator. Original
raw data remain intact. Matching allocator alone did **not** solve the problem:
before the scheduling fix, instrumented GUI-allocator runs achieved only about
33–37% of native throughput.

## Controlled scheduling experiment

Five independent paired runs per stage, 5,000 recorded prompt exchanges and
10/100 MiB output, `--allocator debug --telemetry`, `HOLLOW_AGENT_PROFILE=1`.
Same release optimization, frame pointers and diagnostics in both stages.
The second stage contains the scheduling fix only, before host allocation removal.
Numbers are medians of per-run statistics, not pooled samples.

| Stage | Native p99 ms | Agent p99 ms | Native 10/100 MiB output MiB/s | Agent 10/100 MiB output MiB/s |
| --- | ---: | ---: | ---: | ---: |
| Instrumented before | 0.333 | 0.761 | 70.94 / 71.19 | 23.44 / 26.09 |
| Schedule before poll | 0.310 | 0.729 | 72.64 / 70.77 | 66.30 / 65.46 |

The 100 MiB agent throughput improves **2.51×** in this controlled comparison;
all five post-fix runs record zero ready-output poll waits/stalls. Instrumentation
timings include blocking time and must not be interpreted as CPU time.

## Final changes, diagnostics disabled

Five more paired GUI-allocator runs with scheduling and allocation fixes, without
`--telemetry` or `HOLLOW_AGENT_PROFILE`:

| Metric | Native median (range) | Agent median (range) | Ratio of medians |
| --- | --- | --- | ---: |
| Prompt p99 ms | 0.304 (0.284–0.363) | 0.578 (0.544–0.648) | +0.274 ms |
| 10 MiB output MiB/s | 71.47 (69.22–73.86) | 70.10 (64.10–71.61) | 98.1% |
| 100 MiB output MiB/s | 70.90 (70.13–72.51) | 71.87 (69.43–73.53) | 101.4% |

This establishes near-native **median** local throughput, not a universal 95%
gate pass. Individual paired 10 MiB runs fall below 95%; raw variability is
preserved. Windows client/WSL-bypass comparisons, loaded latency, GPU timing,
noisy-neighbor fairness and multiplexed scalability remain unqualified.

Repeating with the original **page allocator**, diagnostics disabled, gives
96.0% / 100.1% of native median throughput at 10/100 MiB (agent 67.31 / 70.25 MiB/s).
Thus the improvement is not achieved merely by changing the allocator: the old
page-allocator path itself improves from about 16–17% to near-native medians.
Individual paired page-allocator 10 MiB runs also vary below 95%.

Raw datasets (five runs each):

* [Instrumented before](2026-10-18-profile-before.jsonl.gz)
* [Scheduling fix only, instrumented](2026-10-18-profile-after.jsonl.gz)
* [Final GUI allocator, diagnostics off](2026-10-18-final-debug.jsonl.gz)
* [Final original page allocator, diagnostics off](2026-10-18-final-page.jsonl.gz)

[Machine-readable summary](2026-10-18-throughput-summary.json) contains raw-file
SHA-256, exact executable hashes, per-run ratios and agent profile counters.
The base revision is `1c2acdb`; uncommitted source hashes in each raw dataset
identify the measured implementation stages.

## Reproduce and inspect

```sh
zig build --build-file build-agent.zig agent agent-pty-bench -Doptimize=ReleaseFast -Dagent-profile=true
HOLLOW_AGENT_PROFILE=1 python3 scripts/agent_pty_bench.py --allocator debug --telemetry --runs 5 --samples 5000 --size-mib 10 100 --output profile.jsonl
python3 scripts/agent_pty_bench.py --allocator debug --runs 5 --samples 5000 --size-mib 10 100 --output final.jsonl
```

`-Dagent-profile=true` keeps symbols/frame pointers; it does not enable runtime
counters. `--telemetry` enables fixed-size atomic host counters and forwards agent
stderr. `HOLLOW_AGENT_PROFILE=1` separately enables fixed-size agent counters and
one bounded, connection-cumulative `AGENT_PROFILE` stderr summary per completed PTY. Stdout remains
framed protocol only. Counters distinguish pipe API calls/bytes/time, DATA frame
counts, short frames, credit updates, queue waits, buffer high-water marks and
avoidable ready-output polls. Pipe API counts are **not** kernel syscall counts.
Profiler captures also showed significant system time and transient allocation
cost; these diagnostic observations alone do not isolate all remaining overhead.
The agent snapshot precedes queuing the terminal response, so `bytes_written`
may exclude the final DATA already queued for stdout; client byte/hash/exit checks,
not that snapshot, establish transfer completeness.

Conclusion: **keep the scheduling/allocation fixes; keep backend rollout opt-in**.

Correctness checks after the changes: 104 native test executions across the
standalone agent/host graph (including imported tests), 50 Python harness unit
tests, all 16 local fs/exec conformance cases, 11 real PTY cases, native Lua tests
in both installed layouts, and real pane/terminal integration. Native PTY adapter
cases also pass through Podman, WSL interop and the fragmented mock socket;
Windows adapter cross-compilation and static x86_64/aarch64 builds pass. None of
these substitute for native Windows GUI execution.
