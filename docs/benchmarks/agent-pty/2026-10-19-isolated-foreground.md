# Static foreground-isolation topology experiment

Base revision: `a515459` (DRR prototype committed). New benchmark-only option
`--separate-foreground` pins foreground to an independent instance of the same
agent. Background PTYs and fs/exec retain their original shared connection.
No agent/protocol/production routing changes, automatic defaults, same-agent
control lane or live pane migration are introduced.

## What changes, and what does not

Two agents/transports instead of one remove foreground DATA and input/resize
traffic from the background/bulk pipe and agent loop. They also change OS process
scheduling and host transport resources. This is not a clean attribution of
improvements solely to head-of-line blocking. No CPU/RSS, cold-install/startup,
remote establishment or sustained fault behavior is qualified by finite timing.

WRR and DRR remain selectable. Both experimental PTY connections negotiate the
same requested capabilities and preserve connection-scoped generation/stream
ownership. Eight panes still represent **two logical groups of four** across the
workload: foreground group 1 is split across processes. Foreground connection
selects its pane, while background connection independently selects group 1 with
stream zero (session-only focus). Thus its three foreground-session siblings
retain group priority, but no background pane impersonates focused pane. There
is no coordinated cross-connection budget or global byte fairness guarantee.

Logical grouping is metadata, not moving PTYs. Foreground is pinned at spawn;
focus-refresh probes refresh only this same stream and do not measure switching
or migration. Both pre-load focus ACKs are separately retained. Their sequences
may both start at one because their nonce/generation domains are independent.
Foreground echo/output timing starts after setup, greetings, one checked bulk
operation per active kind and initial focus ACKs. Extra connection startup is not
included in that timed throughput/echo and remains a deployment cost.

The explicit option requires shared backend, at least two PTYs and no simultaneous
`--separate-bulk`. Existing conservative admission rejects shared PTY count plus
bulk jobs above 16 even though a foreground slot moved to another connection.
It does not silently extend overall capacity. Other routes are unchanged.
`foreground_lane`, `separate_foreground`, active `bulk_lane:"shared_background"`
and separate background ACK identify this topology. Owned connections outlive
their panes and are destroyed independently during normal teardown; this finite
probe still fails the entire invocation on transport errors, not a GUI recovery
policy. No claim of graceful independent supervisor failure/reconnect is made.

Host `telemetry` describes foreground; `background_telemetry` describes shared
background. `bulk_telemetry` can repeat that same background connection snapshot;
do not count it twice. Queue-profile stderr currently lacks connection identity,
so both local flag and received snapshots are rejected with this option. This
avoids pooling the two agents' equal sequence numbers as one causal stream.
Remote target queue profiling must be disabled too; host telemetry remains valid.

## Comparisons

Three rotating orders of five variants: native POSIX, shared WRR, isolated WRR,
shared DRR and isolated DRR. Not all 120 permutations. Load/bulk/workload order
stays fixed: noisy/stalled, off/mixed, prompt/output. Each case uses eight PTYs,
1,000 recorded prompts after 32 checked warmups, resize every 16, 10 MiB output,
checked 16 KiB FS_READ and 512 KiB EXEC when mixed. All diagnostic and host
telemetry flags off. No focus refresh or migration in performance comparisons.

Native bulk still uses a separate ordinary agent, as in previous experiments.
All agent selections use the **same frozen binary**, unchanged from DRR work.
All variants use the same new benchmark/owner loop: foreground first, bounded
background reads and bulk polling. Native readers retain roughly 4 MiB versus
64 KiB per agent PTY, so native and agent resources are not equivalent. Per-stream
background rates/gaps and checked bulk completion rates must accompany foreground
numbers. Those rates include warmup in their denominator; foreground output time
does not. Incomplete bulk/background work is canceled rather than counted.

A four-case correctness smoke uses isolated DRR, eight stalled PTYs, bulk
off/mixed, 200 prompts, 10 MiB, 64 KiB EXEC and resize every eight. These short
smoke results are not latency/throughput qualification. Additional final validation
checks host telemetry and explicit rejection boundaries separately.

```sh
HOLLOW_AGENT_BOUNDED_BULK=1 HOLLOW_AGENT_FOCUS_SCHEDULER=1 \
HOLLOW_AGENT_DEFICIT_SCHEDULER=1 python3 scripts/agent_pty_bench.py \
  --backend shared --focus-scheduler --deficit-scheduler --separate-foreground \
  --sessions 8 --load noisy stalled --bulk off mixed --samples 1000 \
  --resize-every 16 --size-mib 10 --runs 3 --output isolated-foreground.jsonl
```

Omit isolation for shared control; omit deficit option/flag for WRR. Native uses
`--backend native` without scheduler flags. Remote use needs a prepared connector
supporting concurrent connections to the same intended target and an explicit
zero fixture path. No deployment or target-identity attestation is performed.
This is headless Linux inside WSL, not native Windows GUI/legacy-bypass parity.

## Results

**124 ReleaseFast measurements validated**: 120 matrix and four initial smoke
cases, with no harness correctness failures. **Four additional ReleaseSafe
correctness measurements** cover isolated DRR with separately labeled host
telemetry/same-target refreshes, and isolated flat mode without focus negotiation.
No queue traces are pooled across connections.

### Foreground improves substantially in this static topology

Median of three run-level values; cells show echo p99 in ms / foreground output
in MiB/s, not pooled samples:

| Variant | Noisy / off | Noisy / mixed | Stalled / off | Stalled / mixed |
| --- | ---: | ---: | ---: | ---: |
| Native POSIX | 1.806 / 63.70 | 4.794 / 43.22 | 1.071 / 60.20 | 2.911 / 47.62 |
| Shared WRR | 4.934 / 36.16 | 6.060 / 27.03 | 5.037 / 35.86 | 5.697 / 28.94 |
| Isolated WRR | 0.987 / 67.90 | 1.307 / 68.89 | 0.957 / 69.64 | 1.363 / 66.43 |
| Shared DRR | 5.177 / 33.30 | 6.065 / 26.13 | 4.693 / 35.57 | 6.148 / 25.89 |
| Isolated DRR | 0.863 / 70.03 | 1.372 / 63.05 | 0.908 / 72.85 | 1.351 / 69.01 |

Isolation lowers echo p99 medians to **0.86–1.37 ms** versus corresponding shared
**4.69–6.15 ms**, with **1.88–2.67×** foreground output throughput. This is much
stronger foreground evidence than separate-bulk placement, which previously did
not improve foreground p99. It supports further investigation of pinned/hybrid
topology, not automatic production routing or a claim WRR/DRR alone fixes tails.

All **48/48** round-matched local agent/native +5 ms comparisons pass here:
12 per agent variant. Maximum excess is **+4.036 ms shared WRR**, **+4.640 ms
shared DRR**; all 24 isolated pairs are below their native pair's p99 in this
cohort. Co-located controls passing too means no earlier latency failure has been
erased or retroactively explained by isolation. Same offered workload is not same
achieved load: native consumes substantially more background/bulk output, with
different buffering and resources. Do not interpret negative local deltas as
proof an agent intrinsically outperforms native PTYs or real WSL bypass.

### Background and bulk are not free

Prompt-phase aggregate background throughput falls **7–11%** versus matching
shared policy. Mixed checked EXEC completion rates during prompts:

| Policy / load | Shared EXEC, MiB/s | Isolated EXEC, MiB/s | Change |
| --- | ---: | ---: | ---: |
| WRR / noisy | 6.69 | 4.98 | −26% |
| WRR / stalled | 7.65 | 6.11 | −20% |
| DRR / noisy | 8.09 | 7.04 | −13% |
| DRR / stalled | 8.87 | 7.99 | −10% |

Mixed prompt FS rates also fall: WRR **3.30→2.77 / 3.32→2.83 MiB/s** and DRR
**3.30→2.86 / 3.39→3.06 MiB/s** noisy/stalled. Lower background/bulk progress
alongside better foreground latency is a real tradeoff, not erased because every
active flow completes some work. No CPU contention or scheduling root cause is
established without resource/dispatch evidence.

Output-phase aggregate background rates instead rise: WRR **47.54→68.55 /
41.92→59.74 / 44.44→71.58 / 40.62→59.92 MiB/s**, DRR **48.79→68.87 /
41.35→55.44 / 46.90→75.35 / 40.50→63.34 MiB/s** in table order. This aggregate
increase is uneven: noisy/mixed WRR non-selected-session panes fall from roughly
**3.58–3.63→3.01–3.09 MiB/s**, DRR from **3.37–3.39→2.65–2.84 MiB/s**, while
foreground-session siblings get more shared-background service. Splitting that
logical group across agents does not preserve one global service budget.

Noisy/mixed output worst-gap medians change **19.23→18.13 ms WRR** and
**20.11→21.97 ms DRR**. Per-pane byte counters, rates and all run-level gaps are
retained in the summary, not replaced by aggregate improvements. Short 10 MiB
transfers finish much faster with isolation, changing background observation
window and complete-EXEC granularity; these finite output rates are not steady
state. Some output bulk comparisons worsen, including WRR noisy EXEC
**6.31→3.44 MiB/s**. Unfinished work is canceled, never counted as progress.

### Validation and retained release boundaries

Local ReleaseSafe agent/benchmark build, **91** loop/adapter/transport executions,
**68** Python unit tests and four direct native-runner rejection checks pass.
The four later ReleaseSafe measurements verify independent foreground/background
host counters, background session-only ACK, foreground-only refresh, flat mode
without ACKs and checked bulk/echo/output. CI adds the labeled-telemetry smoke;
hosted execution is not claimed. Installed agent/benchmark restored to ReleaseSafe.

No agent/transport implementation changed; frozen ReleaseFast agent is byte-for-
byte identical to the DRR dataset. Therefore no new default E1 repeat or new
Windows/ARM64 build qualification is claimed for this benchmark-only step.
Latest default evidence remains DRR-stage current/native **one of 12 below 95%**
(91.98%), with earlier failed datasets retained. This matrix does not replace
10/100 MiB dedicated/default or actual legacy-bypass throughput gates.

Still untested: sustained CPU/RSS/thread/transport cost, starvation/flood/arrival
behavior, genuinely loaded focus switching or live migration, independent
transport death/reconnect/recovery, 40/100/200 PTYs, native Windows GUI and actual
legacy WSL-bypass parity. Queue/focus causal traces need connection identity
before supporting this topology; rejecting ambiguous traces is intentional.

### Reproducibility

Frozen ReleaseFast agent:
`d8c35147b131fd27e552f75093984a6991cb1a05aa9972bd6c99e18464db2828`.
Common frozen benchmark:
`1838c6aa4b5d97aeb0c61f5e636c66b309c2db32455e0360ed57c1b6f131191e`.

`2026-10-19-isolated-foreground.json.gz` retains 124 validated measurements,
raw prompt samples, metadata/stderr, raw-file hashes, manifests and exact
orchestration. Uncompressed JSON SHA-256:
`c231162fbbd02e508295bbf592abbc3d9ca80053599172bfda0154e16677ff36`.
Adjacent `.summary.json` retains run-level results, individual background rates,
checked bulk rates and all 48 local pair results; `.patch.gz` reconstructs all
**16** runner source hashes on `a515459`. Later CI/docs edits are not part of the
measured patch. Three rotating orders are not all permutations; uncontrolled
host load/power remains a limitation. All performance runs were serial with no
concurrent builds/tests/other benchmark jobs. Final correctness checks followed.

`2026-10-19-isolated-foreground.safe-checks.json.gz` separately retains four
ReleaseSafe correctness measurements, source/binary hashes and original raw-file
digests. Uncompressed SHA-256:
`296a956db3fc9f87601ddf114bd85f523a1e1f50d023880d14150c7d893950e7`.
Safe agent `82ca8fde34ce8703ba735703c036c2e71fa85902928edafdc63f2c736380c09c`;
benchmark `db9bd10230b7d52feabd6a6ef8f2b6b1a958e5b4e3498d7d65574db29c30c0a3`.
All 16 final runner source hashes match main measured reconstruction.

**Decision:** retain explicit pinned-foreground research option and promising
local result. Do not change default routes, claim equal-resource performance or
add automatic focus migration. Next evidence should measure resource/fault costs
and real focus transitions before selecting a production hybrid transport design.
