# Default-path source isolation after bounded-bulk scheduling

Follow-up to [the bounded-bulk experiment](2026-10-18-bounded-bulk.md), committed
as `1df1b67`. **No agent, protocol, scheduling, admission or pane-default changes
in this investigation.** The candidate remains unqualified; earlier slow runs
are retained, not superseded by a faster repeat.

## Question and controls

The earlier diagnostics-off source check reported candidate/native median ratios
of 92.0%/96.3% at 10/100 MiB versus prior/native 104.1%/99.8%. Matching instrumented
runs did not reproduce that gap. Before attempting a speculative hot-path change,
test whether the difference follows the binary under better-balanced order and
different CPU/workload contexts.

Freeze the exact same ReleaseFast agents and unchanged headless benchmark:

| Binary | SHA-256 |
| --- | --- |
| Prior agent, `9120249` source | `87878eba7991bbd6810932743efbf0f80a16e2cc6606fc59d13d26715a18613c` |
| Current agent, `1df1b67` measured source | `e0ab364efe57af3cdfe62ea4fb50cd77b2686bd8761b8cce6392f374f321e7d4` |
| Benchmark, unchanged | `ded70caa8d596400641740dec834413e34320d653df52c3c7731a25566fca47c` |

Each stage runs all six permutations of **native POSIX / prior agent / current
agent**. Each variant occupies each position twice. Each invocation starts its
own processes and performs one checked 10 MiB transfer followed by one checked
100 MiB transfer. Thus sizes are not order-balanced. Native is a separate
invocation in the same round, not a simultaneous measurement or a Windows bypass.
Both agents use dedicated PTY connections with the bulk flag absent.

Keep GUI-matched DebugAllocator, exact binary output length/all-zero verification,
SHA-256 and clean exits. Clear `HOLLOW_AGENT_BOUNDED_BULK`, both agent profiling
flags and `HOLLOW_TEST_CONNECTOR_ARGV`; do not enable host telemetry. No concurrent
builds/tests or other benchmark jobs. This remains headless x86_64 Linux inside
WSL2 with uncontrolled Windows/host load and power state, not release qualification.

Record effective inherited CPU affinity, load averages and aggregate Linux CPU
ticks before/after each invocation. `RUSAGE_CHILDREN` deltas record user/system
CPU seconds, voluntary/involuntary context switches and minor/major faults for
the **entire completed subprocess tree**, including Python runner and checksum
verification, benchmark, agent, guardians and workload. They do not isolate agent
CPU or the timed transfer, and cannot establish causality or a machine-wide load
bound. Do not add maximum RSS values or infer per-process RSS from these deltas.

## Output-only, normal affinity

36 measurements; six rounds, effective affinity CPUs 0–5. Medians of independent
rates (not pooled bytes/time):

| Variant | 10 MiB, MiB/s | 100 MiB, MiB/s |
| --- | ---: | ---: |
| Native POSIX | 68.09 | 68.94 |
| Prior agent | 69.11 | 72.07 |
| Current agent | 70.35 | 71.15 |

Current/prior ratios of medians are **101.8% / 98.7%**. Current/native ratios are
103.3% / 103.2%, versus prior/native 101.5% / 104.5%. This stage does **not**
reproduce the earlier candidate-specific 8–12 percentage-point loss. It does not
prove absence of a regression or qualify throughput: there are only six runs,
the environment remains uncontrolled, and earlier failures still count.

Median whole-invocation CPU seconds: native 2.071, prior 2.205, current 2.237.
Median voluntary switches: 42,344 / 44,947 / 44,848; involuntary switches:
342 / 201 / 135. Similar totals do not explain the earlier slow transfer.

## Output-only, single-CPU diagnostic topology

Repeat all six permutations with the runner pinned to **CPU 0**, inherited by
benchmark, agents and child workloads. This deliberately changes available
parallelism, cache/wakeup behavior and competition between client SHA-256 and
transport. It is a diagnostic variable, **not** a proposed product affinity policy
or a substitute for the normal-affinity baseline. Stage order is normal-affinity
then pinned, not randomized across topology.

| Variant | 10 MiB, MiB/s | 100 MiB, MiB/s |
| --- | ---: | ---: |
| Native POSIX | 65.92 | 65.83 |
| Prior agent | 61.60 | 65.17 |
| Current agent | 60.47 | 64.92 |

Current/prior ratios are **98.2% / 99.6%**. Both agents miss the local 95% native
comparison at 10 MiB (prior 93.5%, current 91.7%); 100 MiB ratios are 99.0%/98.6%.
This shows that a short-transfer miss can also occur in the prior binary under
changed scheduling conditions. It does not prove topology caused the earlier
unpinned loss or exonerate the candidate.

Median whole-invocation CPU seconds: native 1.802, prior 1.731, current 1.736.
Median voluntary switches: 54,512 / 46,831 / 46,991; involuntary switches:
30,001 / 22,646 / 22,573. CPU use falls while elapsed throughput generally falls;
more serialized execution/preemption is observable, but these aggregate counters
cannot locate ready-to-enqueue/credit waits or Windows scheduling delays.

## Normal affinity, preceding prompt workload

54 additional measurements; six permutations, each invocation first runs 5,000
recorded prompt samples after 32 checked warmups, then the two output sizes. Each
case still creates fresh benchmark/agent/child processes; this tests recent
workload context on the machine, **not** warm connection reuse. Stage follows the
two output-only stages rather than randomly interleaving them.

| Variant | Median prompt p99, ms | 10 MiB, MiB/s | 100 MiB, MiB/s |
| --- | ---: | ---: | ---: |
| Native POSIX | 0.326 | 68.89 | 70.13 |
| Prior agent | 0.654 | 66.82 | 69.63 |
| Current agent | 0.731 | 68.60 | 69.20 |

Median rates again do not show the earlier persistent candidate loss:
current/prior 102.7% / 99.4%, current/native 99.6% / 98.7%. But **retain severe
candidate outliers**: round 1 returns 24.64/50.75 MiB/s and round 2 returns
46.55/52.98 MiB/s at 10/100 MiB, with prompt p99 1.102/1.229 ms. Nearby prior runs
are faster. Current whole-invocation involuntary switches rise to 1,825/1,211 in
those rounds, versus 205–386 in its other four rounds. Whole-invocation CPU also
rises to 6.07/6.67 seconds versus 4.82–5.21 seconds in its other rounds.

This is correlation, not proof of external scheduling noise: counters aggregate
three workloads and their process trees, and CPU-frequency effects, contention,
code behavior and kernel waits are not separately measured. Native round 1 also
has 2,544 involuntary switches without a corresponding transfer collapse. Do not
delete outliers, label all candidate misses harmless variance, or treat six-run
medians as establishing default-path regression absence.

## Software CPU sampling: concrete compaction target, not loss attribution

Separate 18-case diagnostic stage: prior/current order alternates over three
rounds; each variant runs prompt/10 MiB/100 MiB in that order. Wrap only the agent
in `perf record -q -e cpu-clock:u -F 997`, retaining inherited workload samples.
Enable matching host telemetry to inherit diagnostic stderr, but keep agent
profiling and bounded-bulk flags absent. Sampling/telemetry change the measured
system; these runs do **not** replace the diagnostics-off stages above.

Perf's default report leaves these static ELF addresses unresolved. Resolve
absolute agent instruction pointers from `perf script -F ip,dso` with
`addr2line -f -i -e <exact-agent>`; do not interpret report file offsets as virtual
addresses or assign child-image samples to the agent.

Across three 100 MiB runs per variant, inlined `std.mem.copyForwards` accounts for
**178/276 prior and 186/274 current agent-image user-space samples** (64.5%/67.9%).
The complete inherited trees have 377/366 samples. Disassembly confirms the hot
PTY queue-tail compaction is an unrolled byte-load/store loop in both binaries;
current address `0x1034296` resolves to `mem.zig:243` inlined at
`main.Agent.streamPty`, `main.zig:407`. Neither the samples nor this shared hot spot
establishes why only some unprofiled candidate invocations collapse.

Diagnostic median 10/100 MiB rates are prior 65.20/66.26 MiB/s versus current
62.49/67.05 MiB/s; prompt p99 medians 0.661/0.629 ms. Low sample counts, user-space
only sampling, inherited child work and no client/kernel/off-CPU profiles limit
attribution. All recordings/reports are preserved, with zero lost samples reported.

**Next bounded optimization:** replace just the overlapping PTY-tail copy with
Zig 0.16 `@memmove`, using equal-length source/destination slices. Preserve the
same 64 KiB queue, credit, DATA sizes, scheduler and terminal ordering. Verify
nonuniform payloads with overlapping tails, one-byte credit, empty tails and
partial quanta; compare frozen pre/post binaries before accepting a performance
claim. This targets measured CPU work, **not** an asserted root cause or a
speculative priority/topology change.

## Evidence and decision

`2026-10-18-default-source-isolation.json.gz` preserves all **126 diagnostics-off
measurements**, original per-invocation metadata, raw SHA-256 values, resource/load
manifests and the orchestration script. Its uncompressed SHA-256 is
`5779614ce23d27f0d85d3118a16fcdbc5ef1d0296c2580714827c702c41c2917`.
`2026-10-18-default-source-isolation-summary.json` keeps per-run rates/tails,
ordering and resource deltas without duplicating raw samples.

`2026-10-18-default-source-perf.tar.gz` contains all **18 additional diagnostic
measurements**, original recordings, reports, invocation manifest, orchestration
and symbolized address counts. The uncompressed tar SHA-256 is
`93c9008d70d9bf81b23d8a2aaa03b053ad81b02d6ad654da2c7661a91c564baf`.
The adjacent `2026-10-18-default-source-perf-summary.json` summarizes those runs.
All 144 results were revalidated; all 13 workspace source hashes match `1df1b67`.
As before, workspace hashes describe the runner checkout; frozen explicit agent
hashes identify the actual selected binary, not that checkout's agent source.

Archived orchestration scripts contain this machine's absolute paths. Reproduce
with the same exact frozen binaries and benchmark, adapting root/output paths;
the source-order script supports `--tag`, `--cpu`, `--workload` and `--samples`.
Use fresh output names, clear all three agent flags, and run each stage alone:
output-only at normal affinity; output-only with `--cpu 0`; then normal affinity
with `--workload both --samples 5000`. Manifests retain every original command.
Sampling is separate and requires Linux perf with software CPU-clock permission.

**Conclusion:** no stable candidate/prior median loss reproduced under balanced
order, but intermittent severe candidate losses remain unexplained. Do not mark
default performance preserved or change pane/backend defaults. Retain failed
gates; test the measured compaction optimization independently, then resume
focus/session QoS and split-lane research with controlled resource/latency evidence.
