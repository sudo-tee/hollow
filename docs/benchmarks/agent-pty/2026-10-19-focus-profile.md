# Per-sequence focus readiness/enqueue/write diagnostics

Base revision: `413c036` (explicit weighted-visit focus baseline committed).
This step adds bounded, opt-in correlation before trying new scheduling or
transport policy. It does **not** change weights, credit, frame sizes, admission,
default backend selection or queue limits. Prior latency/default-throughput,
background/bulk QoS and Windows/WSL qualification blockers remain open.

## What the observations mean

Existing `HOLLOW_AGENT_QUEUE_PROFILE` on a negotiated focus connection now retains
the first **64 accepted focus sequences** in separate fixed storage. Aggregate
1,024-span queue profiler remains independent: overflowing either drops timing
records, never wire bytes. `AGENT_FOCUS_PROFILE` stderr snapshots preserve
accepted/dropped counts, sequence/group/stream, agent-local dispatch, first
observed captured-and-credited readiness, first matching newly enqueued DATA
payload interval, and first/final successful stdout payload-write timestamps.
See [full contract](../../architecture/agent-pty-experiment.md#per-focus-diagnostics-and-loaded-refresh-probe).

Readiness is **not kernel-ready time**; existing captured bytes may satisfy it at
dispatch. New enqueue excludes DATA already queued before focus but may still
contain older child output. Writes exclude headers and end at stdout syscalls,
not client decode/consumption, rendering or echo visibility. Only one matching
frame is tracked per sequence. No cross-clock timestamp subtraction, prompt-token
causal identity or full-output completion is claimed.

Stale/invalid updates create no event. New focus supersedes only unenqueued older
records. Enqueued records retain write correlation across later changes. Explicit
`no_stream`, `superseded`, `released`, `discarded` censoring and nullable pending
timestamps prevent a terminal snapshot or partial write becoming a false
completion. Snapshots precede terminal enqueue and repeat connection history;
deduplicate by sequence within each independent run, never pool duplicate terminal
snapshots as independent events. First-64 storage deliberately does not recover
new updates after overflow; accepted/dropped counters expose this selection bias.

## Workloads and provenance

### Loaded refresh, diagnostics off/on

Three rounds alternate profiling off/on; **host telemetry enabled in both** so
stderr is drained equally. Same explicit focus target refreshed every 32 prompts,
including 32 warmups; 1,000 recorded prompts; eight panes/two logical groups of
four; noisy/stalled neighbors; bulk off/mixed checked 16 KiB FS_READ and 512 KiB
EXEC; resize every 16 prompts; 10 MiB foreground output. Fixed load/bulk/workload
order is not randomized. No concurrent builds/tests/benchmark jobs.

Refresh ACK wait services backgrounds/bulk and stays **outside** echo timer.
Client results retain sequence, warmup-inclusive prompt index and ACK RTT for
each refresh; profile records correlate by accepted sequence, not by clock epoch.
Refresh is an explicit workload change that truncates remaining scheduler quota,
not a transparent profiler side effect. Target stays the **same pane**, so this
does not qualify cross-session/pane focus switching or loaded GUI application
delay. Each output case has only initial pre-load focus, not periodic refresh.

### Overflow and correctness smoke

An additional profiling-on stalled/mixed prompt case refreshes every eight prompts
to exceed capacity. Preserve overflow/dropped events and all pending/censored
records rather than interpolating missing timings. CI correctness fixture uses
100 prompts, refresh every 32, eight stalled panes, 10 MiB, and smaller 64 KiB
EXECs; smoke is separate from performance comparisons.

### Default E1 recheck

All six permutations of native POSIX / frozen `413c036` agent / new agent, same
new benchmark, normal inherited CPU affinity. No focus/bounded/profile flags or
telemetry. Each invocation uses fresh processes for 5,000 recorded prompts then
10/100 MiB output. Fixed size order and uncontrolled Windows load/power remain
limitations. Earlier failed default datasets remain evidence regardless of this
repeat; no native Windows/legacy-WSL-bypass gate can be passed here.

## Correctness coverage

Deterministic tests cover pre-focus queued DATA exclusion, unrelated streams,
header-only versus partial/full payload writes, ready/enqueue ordering, stale
updates, supersession before enqueue versus after enqueue, clear/session-only
focus, release, disconnect discard and diagnostic overflow. Focus correlation
remains correct when aggregate span marks overflow and when output positions
include discarded bytes. A full 64-event snapshot with maximum-size numeric
values fits fixed serialization storage. Real-wire test checks completed payload
correlation and superseded/no-stream/released censoring without blocking stderr.
Parser/unit tests reject inconsistent sequences, timestamps, offsets, counts and
invented completions, while retaining legitimate incomplete records.

## Results and decision

### Loaded refresh: client ACK and echo must stay separate

48 validated measurements. Median of three independent run-level p99 values;
arrows indicate queue profiling **off → on**, with host telemetry in both:

| Load / bulk | Echo p99, ms | Loaded refresh ACK p99, ms | Foreground output, MiB/s |
| --- | ---: | ---: | ---: |
| Noisy / off | 6.453 → 6.233 | 2.421 → 3.253 | 34.46 → 33.32 |
| Noisy / mixed | 6.513 → 6.213 | 3.346 → 3.175 | 27.00 → 26.04 |
| Stalled / off | 5.020 → 5.419 | 2.415 → 2.382 | 35.62 → 36.33 |
| Stalled / mixed | 6.354 → 6.245 | 3.593 → 4.181 | 28.30 → 27.22 |

These are not paired-native gates or proof the profiler is free. Throughput falls
in three groups; echo tails improve in three and worsen in one. Environment and
timing variability remain uncontrolled. Loaded ACK wait excludes initial pre-load
update and warmup refreshes, but **still is not application-to-echo time**; it is
reported separately because the echo timer deliberately starts after that wait.

### Agent-local correlated observations

Deduplicated by sequence **within each run**, the 24 profiling-on cases contain
420 retained events: 12 initial updates superseded before enqueue, 408 records
with first-frame payload writes observed complete by a later terminal snapshot.
Of these, 384 records correspond to refreshes before recorded (not warmup)
prompts: **32 observations per run**. Nearest-rank p99 therefore equals that
run's maximum; do not treat these tiny cohorts as stable tail estimates.

Median of run-level p99, milliseconds, profiling-on only:

| Load / bulk | Dispatch → ready | Ready → enqueue | Enqueue → first payload write | Dispatch → complete first-frame payload write |
| --- | ---: | ---: | ---: | ---: |
| Noisy / off | 7.358 | 0.350 | 1.072 | 7.915 |
| Noisy / mixed | 6.476 | 1.626 | 1.454 | 8.149 |
| Stalled / off | 5.981 | 0.220 | 1.193 | 7.175 |
| Stalled / mixed | 8.183 | 0.562 | 1.283 | 9.293 |

First and complete payload-write p99 match in these small echo frames; partial
and header-only behavior is covered by deterministic tests, not inferred from
this coincidence. Do **not** add column medians as though they described a
single update. Dispatch-to-ready includes waiting for client ACK, sending new
input, child work, credited capture observation and intervening loop activity.
It does not isolate scheduler cost or diagnose the remaining echo-latency miss.
Ready-to-enqueue and enqueue-to-write now have a specific sequence/target/frame
identity, unlike aggregate queue classes, but still do not identify a prompt token
or measure client consumption/rendering.

The overflow case accepts **130** updates, retains **64**, and explicitly drops
**66** timing records: one retained initial update superseded, 63 retained frame
writes completed. Only 59 retained records correspond to recorded prompt-phase
refreshes; later refreshes are censored by capacity, so do not extrapolate their
timing from the retained first half. All prompt bytes, bulk accounting and stopped
buffer checks still pass. Overflow loses observations, not protocol data.

### Default-path E1 still has failed individual comparisons

54 validated measurements, all scheduler/profiling flags and telemetry absent:

| Variant | Median prompt p99, ms | 10 MiB, MiB/s | 100 MiB, MiB/s |
| --- | ---: | ---: | ---: |
| Native POSIX | 0.354 | 72.60 | 71.74 |
| Prior `413c036` agent | 0.754 | 70.23 | 72.72 |
| New agent, diagnostics off | 0.784 | 69.61 | 73.63 |

Current/prior ratios of medians **99.1% / 101.3%**, current/native **95.9% /
102.6%**. But current/native has **two of 12** output pairs below 95%, minimum
**89.39%**; prior/native has **three of 12**, minimum 90.42%. Native 10 MiB round
4 also falls to 48.27 MiB/s, inflating both agents' ratios in that round. New
default prompt p99 includes a 1.473 ms outlier in round 0. Retain all observations.

This repeat does not establish default-path performance preservation, exonerate
candidate code, attribute losses to profiling (which was off), or identify
Windows load/power as the cause. No agent profiling storage is allocated without
its flag, and scheduler semantics are unchanged, but unchanged semantics is not
a timing proof. Earlier default-throughput/loaded-latency failures remain open.

### Validation and provenance

Local Zig 0.16.0 ReleaseSafe: **152** standalone native executions, **84** opt-in
loop/adapter/transport executions with queue profiling, **64** Python unit tests,
**six** focus wire cases, **11** existing PTY lifecycle cases, **16** ordinary
fs/exec conformance cases and **two** real pane/VT cases pass. Both static Linux
musl cross-builds/checksums pass. Installed local agent restored to ReleaseSafe;
ARM64 execution, native Windows runtime/GUI, real legacy WSL bypass and broader
resource/fault/scale qualification remain unverified. CI adds the bounded profile
smoke; these local runs are not evidence hosted CI executed.

Frozen ReleaseFast agent SHA-256:
`a9fbdca6b44e043ab8113bba80e588c31bb35bfde21ccae46e680d6bbbd58b5d`.
Common new benchmark:
`87229d8dd8aa4949ec24e79142d3c40c02d9010860abc8f06c5bb39012038659`.
Frozen prior agent:
`492d0913d7a4cfdb0f3b6f936117e93af82c0dc4c76026cf8ca790a7b3b4f0e8`.

`2026-10-19-focus-profile.json.gz` preserves **107 measurements**: 48 off/on,
54 default E1, one overflow and four CI-smoke cases, plus exact raw hashes,
metadata, original diagnostic snapshots/stderr, invocation manifests and
orchestration. No harness correctness failures occurred in this set; that does
not mean comparison gates passed. Uncompressed JSON SHA-256:
`add3e609b06416dae3d76cb3fd1bc457458639f29a2034a65d0859c4c3ec08fb`.
`2026-10-19-focus-profile.summary.json` retains deduplicated per-sequence events,
per-run client/agent metrics and round-matched local output ratios without raw
prompt samples. `2026-10-19-focus-profile.patch.gz` reconstructs the measured
sources on `413c036`; all **15** runner source hashes were verified. Workspace
hashes describe runner checkout, not the explicitly selected prior agent.

Orchestration contains machine-specific paths; adapt root/output and use fresh
filenames. Loaded matrix uses the command above with `--runs 1`, repeats three
rounds alternating queue-profile off/on, and leaves `--telemetry` on in both.
Overflow changes `--focus-every 8 --load stalled --bulk mixed --workload prompt`.
Default script runs all six native/prior/current permutations with
`--workload both --samples 5000 --size-mib 10 100` and all flags cleared. All
performance stages ran serially without concurrent builds/tests or benchmark jobs.
The four CI-sized smoke cases are correctness evidence, excluded from comparisons.

**Decision:** keep diagnostics/probes as an uncommitted observability step. Do not
change scheduling weights, default routes, admission or rollout status from these
results. Next work can compare byte-fair DRR and split bulk/focused transports with
the same measured boundaries; genuine target switching, per-stream sustained
fairness, CPU/RSS/scale and native-platform qualification remain separate work.
