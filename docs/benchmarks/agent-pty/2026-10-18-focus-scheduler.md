# Explicit focus/session weighted-visit baseline

Base revision: `693e767` (PTY compaction step committed). This follow-up adds an
opt-in **hierarchical weighted round-robin** research scheduler. It is not the
plan's byte-fair DRR or a candidate for default pane rollout. Prior unexplained
throughput outliers and shared bulk-free latency failures remain open.

## Intent and controls

The GUI owns focus and logical session membership; agent may use explicit client
metadata only for prioritization. No GUI/workspace/HostManager policy is added.
Native and WSL bypass defaults stay unchanged. Prepared transports run the same
agent, protocol and handlers; target-side flags are explicit connector settings.
See [full wire/native API contract](../../architecture/agent-pty-experiment.md#explicit-focussession-scheduler-research-only).

Enable only when all four conditions hold: target flags
`HOLLOW_AGENT_BOUNDED_BULK` and `HOLLOW_AGENT_FOCUS_SCHEDULER` are present, and
HELLO sets both `experimental_pty` and `experimental_focus`. ACK then advertises
`experimental.focus`; requested native clients reject peers lacking it. Ordinary
fs/exec and non-focus PTY connections retain their existing scheduler selection.

Negotiated spawns carry a positive caller-assigned `logical_session_id`.
`FOCUS_UPDATE` carries the HELLO nonce as `generation`, monotonic `sequence`,
`active_session_id` and `active_stream_id`. Wrong generation/new invalid target
is a per-request error without advancing sequence. Stale updates return
`applied:false`. Metadata does not restart cursors, replay input, infer focus from
traffic, enlarge queues or change job/request admission. All-zero target clears
focus. Releasing a focused pane/group clears only the dead target, not sequence.

Selected group gets four outer visits versus one for each other group and one
for all completed bulk jobs combined. Within selected group, selected pane gets
four inner visits versus one per sibling. Group weight does not grow with pane
count. Bulk rotates among its members. A visit emits one ≤16 KiB PTY quantum or
one whole bulk frame, retaining existing 64 KiB single-ready-source quantum,
65,624-byte batch budget and oversized atomic metadata exception. Failed metadata
fit reserves next selection across focus changes. No partially written/queued
frames are reordered. No independent control lane or control-flood limiter added.

This is bounded **visit** fairness, not byte QoS: short terminal frames and large
atomic metadata have unequal cost, readiness changes weights, and fixed 16-slot
tests do not prove wall-time fairness, arbitrary churn/arrival behavior or scale.
The implementation has fixed group/slot storage and ≤64 selections per schedule
call, without new workload admission or unbounded pending-focus queues.
Logical membership is spawn-time metadata in this prototype; live pane regrouping
is not implemented. Focus updates change future weighted selections after residual
quota, not necessarily the very next emitted frame. Dynamic application-delay and
queued-per-stream causality instrumentation remain separate missing work.

## Correctness coverage

* All 16 combinations of server flags and client opt-ins, stable weighted visit
  counts independent of pane count, continuously ready background visit gaps,
  focus churn, zero credit, metadata reservation and slot reuse.
* Existing all-16-slot byte/order/terminal and oversized metadata tests run with
  both bounded flat and focus scheduling; metadata retry competes with a newly
  credited PTY after focus changes.
* Native shared adapter tests submit focus at full 16-PTY job admission, poll only
  focus completion IDs, preserve every pane's control/output/exit, reject absent
  group metadata, and fail closed on a peer missing focus capability.
* Five real-wire tests cover nonce/sequence/invalid target handling, independent
  connection generations, closed stream replacement, eight-pane focus churn with
  exact output and completed EXECs, and a stopped zero-credit pane that resumes
  after explicit consumption credit. These are short correctness tests, not soak.

## Exploratory performance methodology

Same ReleaseFast agent/benchmark pair for four loaded variants: native POSIX,
shared legacy scheduling, shared bounded flat scheduling, and shared focus.
Eight PTYs, noisy/stalled loads, bulk off/mixed checked 16 KiB FS_READ plus 512 KiB
EXEC, resize every 16 prompts, 1,000 recorded prompts after 32 warmups, 10 MiB
foreground output, three rounds. Variant order rotates across rounds rather than
covering all 24 permutations; load/bulk/workload order stays fixed.

Eight PTYs mean **two logical groups of four**, not eight logical sessions.
Focus variant explicitly selects measured foreground stream in group one before
load starts, leaving focus static. Initial `focus_ack_ns` is pre-load control RTT,
not loaded scheduler-application delay or focus-to-visible-output causality. The
common owner consumes foreground then ≤16 KiB per consuming background; no GUI
render/parser policy, warm persistent connection or focus-switch latency is modeled.

Retain per-stream bytes/progress gaps, aggregate PTY rates and completed bulk
rates. Completed fs/exec throughput uses full background interval; unfinished
background emitters/captures cancel at teardown. Stopped buffer must stay ≤64 KiB.
Windows/WSL load and power state are uncontrolled, CPU/RSS not measured, only
three runs with fewer than 5,000 prompts: **all results remain unqualified**.

Separate default-path check uses all six permutations of native POSIX / frozen
`693e767` agent / new agent, normal CPU affinity, no scheduler/profiling flags or
telemetry. Each invocation runs 5,000 recorded prompts then 10/100 MiB output with
fresh processes for each case. This repeats default evidence without claiming
previous intermittent losses disappeared; fixed size order is not balanced.

Initial 1 MiB/40-prompt smoke preserves three successful measurements followed by
`BulkStarved` in focus/stalled/mixed output: no completed bulk progress was observed
before that short workload ended. Do not weaken validator, hide failure, claim
fairness from longer runs, or treat those three partial results as a full matrix.
CI focus correctness fixture instead uses 10 MiB, 200 prompts and 64 KiB EXECs;
the performance matrix retains 512 KiB captures.

## Results and qualification

### Static-focus matrix: redistributes bandwidth, not a rollout pass

96 checked measurements. Table entries are medians of independent per-run
statistics, not pooled samples or ratios. The two shared non-focus variants do
not send logical group metadata. Bounded and focus variants use the same two
server flags, but only focus requests the extra HELLO capability.

| Load / bulk | Native p99, ms | Legacy shared | Bounded flat | Focus |
| --- | ---: | ---: | ---: | ---: |
| Noisy / off | 1.113 | 5.331 | 5.975 | 5.446 |
| Noisy / mixed | 5.220 | 8.783 | 6.979 | 6.890 |
| Stalled / off | 0.842 | 5.788 | 5.208 | 5.466 |
| Stalled / mixed | 3.147 | 8.435 | 7.418 | 6.582 |

Focus versus bounded flat does **not consistently improve echo tails**. In paired
round comparisons against native POSIX, focus still exceeds +5 ms once in 12
pairs: noisy/bulk-off round 0 is **+5.017 ms**. Bounded flat fails two pairs and
legacy shared four. These small 1,000-sample local comparisons do not qualify
anything even where below +5 ms; native POSIX is not the required WSL bypass or
Windows GUI reference. Focus's worst prompt maximum is 26.367 ms in noisy/off;
bounded flat has a 26.139 ms maximum in stalled/mixed.

Output throughput, arrows showing **bounded flat → focus**:

| Load / bulk | Foreground PTY, MiB/s | Aggregate PTY, MiB/s | Completed fs, MiB/s | Completed exec, MiB/s |
| --- | ---: | ---: | ---: | ---: |
| Noisy / off | 10.35 → 33.31 | 82.70 → 80.16 | — | — |
| Noisy / mixed | 8.67 → 26.79 | 69.50 → 69.04 | 3.01 → 3.26 | 6.94 → 6.70 |
| Stalled / off | 11.31 → 33.66 | 79.35 → 78.74 | — | — |
| Stalled / mixed | 9.79 → 26.07 | 68.16 → 63.30 | 3.23 → 2.97 | 7.37 → 5.21 |

Foreground's roughly threefold gain is primarily a changed **share**, not new
transport capacity. In noisy/off, each other session's pane falls from roughly
10.3 MiB/s to **4.1–4.2 MiB/s**, while active-session siblings remain around
10.1–10.2 MiB/s. This confirms hierarchical priority is materially different from
flat RR, but does not establish acceptable background or bulk QoS. Stalled/mixed
exec falls about 29% relative to bounded flat. Relative to legacy shared,
bounded/focus already sacrifice substantial bulk throughput; keep that tradeoff.

All consuming streams deliver checked distinct bytes in these runs. Shared stopped
buffers are always **65,536 bytes**; native reader remains approximately 4 MiB,
an existing backend asymmetry. Worst observed consuming-background service gaps
are below, in milliseconds (not a proof the streams were continuously ready):

| Load / bulk | Bounded flat | Focus |
| --- | ---: | ---: |
| Noisy / off | 17.26 | 25.68 |
| Noisy / mixed | 18.79 | 31.57 |
| Stalled / off | 29.51 | 19.78 |
| Stalled / mixed | 89.91 | 21.77 |

Retain the 89.91 ms bounded-flat observation and worsened noisy focus gaps; do
not infer starvation freedom from nonzero totals. Initial static focus ACKs range
0.137–0.391 ms, median 0.180 ms across 24 focus cases, measured **before load**.
No loaded focus-switch delay/p99 or ready-to-enqueue per-stream correlation is
measured. Aggregate queue diagnostics retain their existing schema; focus handlers
appear only in aggregate dispatch timing, not a new per-focus handler class.

### Repeated default-path comparison

54 checked measurements with both scheduler flags and profiling absent. Same new
benchmark for native, frozen prior and frozen current agents:

| Variant | Median prompt p99, ms | 10 MiB, MiB/s | 100 MiB, MiB/s |
| --- | ---: | ---: | ---: |
| Native POSIX | 0.264 | 77.40 | 79.06 |
| Prior `693e767` agent | 0.523 | 79.75 | 81.37 |
| Focus-capable agent, default path | 0.544 | 76.41 | 80.91 |

Current/prior ratios of medians are **95.8% / 99.4%**. Current/native ratios of
medians are **98.7% / 102.3%**; all 12 individual current/native output comparisons
clear local 95% check (minimum **95.29%**). Prior/native also passes all 12.
This neither proves default-path performance preserved across environments nor
explains the earlier intermittent losses. Preserve the short-transfer median
decline and earlier failed datasets; do not use this passing repeat as a release
qualification or substitute for Windows/legacy-bypass comparisons.

### Smoke failure, revised correctness workload and local validation

Initial 1 MiB smoke's three checked measurements and one `BulkStarved` failure are
preserved separately, excluded from matrix/default summaries. The revised CI
fixture has four checked results (200 prompts, 10 MiB, 64 KiB EXEC captures). It
ran alongside correctness suites, not in the isolated performance sequence, and
is **correctness evidence only**. Changing duration/capture size does not prove
absence of sustained starvation or identify why the short smoke failed.

Local Zig 0.16.0 ReleaseSafe results:

* **145** standalone native test executions, including 30 agent-loop and 32
  adapter tests; **77** loop/adapter/transport executions with both scheduler
  flags and queue profiling enabled. Existing ordinary clients do not negotiate
  focus merely because flags are present; dedicated focus cases opt in explicitly.
* **60** Python harness unit tests, **five** new focus wire cases, **11** existing
  PTY lifecycle/wire cases, **16** ordinary fs/exec conformance cases, **two** real
  pane/VT integration cases pass.
* x86_64/aarch64 static musl agents cross-build; bundle checksum verification
  passes. Windows experimental-adapter and host-transport compile checks pass,
  not runtime/GUI/GPU qualification. Installed local agent restored to ReleaseSafe.

### Reproduction and artifacts

Frozen ReleaseFast agent SHA-256:
`492d0913d7a4cfdb0f3b6f936117e93af82c0dc4c76026cf8ca790a7b3b4f0e8`.
New benchmark SHA-256:
`6afe9ce7c7f3827bef16165e03b066a380fe2d814dd296406f6c0d1a59694d56`.
Frozen prior agent:
`c6bd236f441f930775a38a960f0db576368c3b31a312290ea5a58ff8aa581370`.

`2026-10-18-focus-scheduler.json.gz` preserves **157 checked measurements**
(96 matrix, 54 default, three initial smoke and four revised smoke), plus the
one original failure, full metadata/manifests, raw file hashes and orchestration.
Its uncompressed SHA-256 is
`f1f4b37a37f4433b9fa348d0fddd6269363e77bf620f6238530b51ef0c7d05f1`.
Adjacent `2026-10-18-focus-scheduler-summary.json` preserves per-run counters,
tails, background rates and round-matched local comparisons without raw samples.
Every checked result was revalidated; all **14** workspace source hashes match
reconstruction of `2026-10-18-focus-scheduler.patch.gz` on `693e767`.
Workspace hashes describe runner source, not the explicitly selected older agent.

Archived orchestration has machine-specific absolute paths; adapt root/output and
use fresh filenames. Matrix uses `--backend native` or `--backend shared`,
`--sessions 8 --load noisy stalled --bulk off mixed --resize-every 16 --runs 1
--samples 1000 --size-mib 10`. Native/legacy clear scheduler flags; bounded/focus
set both; only focus adds `--focus-scheduler`. Run three rounds rotating variant
order. Default script runs all six native/prior/current permutations with
`--workload both --samples 5000 --size-mib 10 100`, both flags cleared. No other
benchmark/build/test jobs ran alongside either performance stage. Original
commands, environment, hashes and default-stage resource/load snapshots remain
in manifests. Software CPU profiling and host telemetry were off throughout.

**Decision:** preserve as an uncommitted research baseline, **not** shared rollout
or a byte-QoS solution. Explicit focus improves output share but does not resolve
echo serialization, background/bulk tradeoffs or earlier default-path uncertainty.
Next work needs per-update loaded application/ready-to-enqueue correlation,
byte-fair DRR and a competing separated-lane experiment; live regrouping, GUI
policy, sustained resource/fault/scale and 40/100/200-PTY gates remain open. No
default/session-priority/transport rollout is authorized by these results.
