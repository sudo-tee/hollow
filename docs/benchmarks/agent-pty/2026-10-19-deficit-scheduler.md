# Hierarchical wire-byte deficit scheduling experiment

Base revision: `ef8410c` (separate-bulk experiment committed). This prototype
compares hierarchical DRR with weighted **visits**, retaining both as explicit
research paths. No default routes, admission limits, credit rules or production
GUI focus policy change. The separate-bulk experiment remains available but is
not used in this matrix: all shared variants keep fs/exec co-located with PTYs.

## Contract and implementation

DRR requires all three target flags `HOLLOW_AGENT_BOUNDED_BULK`,
`HOLLOW_AGENT_FOCUS_SCHEDULER`, `HOLLOW_AGENT_DEFICIT_SCHEDULER`, all three HELLO
booleans `experimental_pty`, `experimental_focus`, `experimental_deficit`, and ACK
capability `experimental.deficit`. Native options reject deficit without explicit
focus; requested clients fail closed if peer only offers weighted focus.
Otherwise the established focus capability, positive logical session grouping,
generation/sequence validation and `FOCUS_UPDATE` response contract stay unchanged.
Server flag alone cannot change an ordinary or weighted-visit connection.

`src/agent/deficit_scheduler.zig` holds fixed-capacity group/pane budgets and
cursors. Outer groups get wire-byte quantum **16,406** (16 KiB plus 22-byte header),
weighted four for selected session versus one for other sessions and aggregate
bulk class. Within selected session, selected pane gets four versus siblings one;
other groups/bulk workers use equal leaf weights. Session-only focus prioritizes
the group without selecting a leaf. A single busy group can consume capacity
unused by unready groups; no artificial wall-clock pacing is added.

Each successful selection emits one PTY DATA or whole bulk frame. Scheduler
eligibility uses its known next wire size; terminal/error frames use conservative
278-byte reservation. **Only actual enqueued bytes are charged**, including frame
header; a partially batch-fitted PTY DATA charges only what was emitted. This is
scheduled-output wire fairness, not equal payload bytes, CPU, RPC completions or
wall time. HELLO, input/resize/close/focus ACKs and other immediate control frames
remain outside these output budgets. No control-flood limiter is added.

Unready/zero-credit panes and wholly unready groups reset budget, so idle flows
cannot bank unbounded priority. Slot release clears leaf residuals and retry;
reused stream IDs still cannot alias old focus. New focus preserves cursors and
never refills positive deficit. Residuals clamp to one base quantum **or the
previously observed next indivisible frame size**, whichever is larger, so focus
churn cannot repeatedly erase the accumulation needed for large metadata. This
exception is bounded by maximum wire frame size, not a new payload allowance.

Large atomic metadata accumulates sufficient byte budget across bounded virtual
rounds; failed batch fit reserves that exact slot before smaller DATA can steal
an empty batch. The existing oversized metadata-alone exception remains: byte
charging cannot preempt an indivisible frame already queued to stdout. Separate
group/pane searches are capped by capacity and maximum legal frame/quantum ratio;
at most **64 successful selections** occur per scheduling call. These bounds
prevent unbounded storage/work, not prove negligible dispatch cost or a latency
guarantee. Ready-empty handling returns without repeatedly scanning virtual rounds.

The deterministic fixed-ready test uses unequal frame sizes, multiple sessions
and two bulk leaves to check byte proportions independent of pane count/visit
count. Further tests cover maximum-size metadata, retry/focus churn, zero-credit
budget reset, slot release and actual terminal-byte charging. Agent loop fixtures
exercise all 16 mixed PTY/exec slots and metadata-alone retries in flat, weighted
and deficit modes. All 64 combinations of server/HELLO opt-ins are checked. Native
full-admission control/completion isolation and capability failure tests also run.

## Workloads and provenance

Three rotating orders of four variants: native POSIX, frozen prior weighted agent,
current weighted agent and current DRR. This is not all 24 permutations. Fixed
load/bulk/workload order: noisy/stalled, bulk off/mixed, prompt/output. Each case
uses eight PTYs/two logical groups of four, static pre-load focus, 1,000 recorded
prompts after 32 warmups, resize every 16, and 10 MiB foreground output. Mixed
bulk repeats checked 16 KiB FS_READ and 512 KiB EXEC. Diagnostic and host telemetry
flags are off; no separate-bulk option, live regrouping or target switching.

An independent default E1 recheck runs all six native/prior/current permutations,
5,000 recorded prompts followed by 10/100 MiB output, fresh processes and every
scheduler/profile flag cleared. Same new benchmark for all agents. A four-case
correctness smoke uses eight stalled PTYs, bulk off/mixed, 200 prompts/10 MiB,
64 KiB EXEC and resize every eight. These smoke results are not performance gates.

```sh
HOLLOW_AGENT_BOUNDED_BULK=1 HOLLOW_AGENT_FOCUS_SCHEDULER=1 \
HOLLOW_AGENT_DEFICIT_SCHEDULER=1 python3 scripts/agent_pty_bench.py \
  --focus-scheduler --deficit-scheduler --backend shared --sessions 8 \
  --load noisy stalled --bulk off mixed --samples 1000 --size-mib 10 \
  --resize-every 16 --runs 3 --output deficit-research.jsonl
```

Omit deficit option and clear only deficit flag for current weighted control;
select frozen prior binary explicitly for prior weighted control. Native uses
`--backend native` with all scheduler flags cleared. Paths in archived local
orchestration need adapting. Linux headless WSL observations cannot qualify
native Windows GUI or actual legacy WSL bypass. Fixed owner-loop consumption,
unequal native/agent reader capacities, uncontrolled host load/power and finite
static-focus cohorts remain limitations. Report per-stream and bulk rates, not
foreground medians alone. Existing failed gates remain evidence independently of
whether a new cohort passes.

## Results

**154 measurements validated**, no harness correctness failures: 96 loaded,
54 default E1 and four smoke cases. This does not mean every comparison passed.

### Loaded foreground comparisons

Median of three independent run-level values. Each cell is echo p99 in ms /
foreground output in MiB/s, not pooled prompt samples:

| Variant | Noisy / off | Noisy / mixed | Stalled / off | Stalled / mixed |
| --- | ---: | ---: | ---: | ---: |
| Native POSIX | 1.648 / 58.60 | 4.461 / 43.27 | 0.833 / 57.98 | 3.526 / 54.54 |
| Frozen prior WRR | 5.839 / 31.76 | 6.100 / 24.46 | 5.510 / 35.92 | 6.032 / 26.80 |
| Current WRR | 5.799 / 33.97 | 6.682 / 24.79 | 4.853 / 35.13 | 5.881 / 27.01 |
| Current DRR | 5.430 / 32.87 | 6.471 / 25.80 | 4.599 / 35.48 | 6.293 / 23.87 |

DRR versus current WRR echo p99 medians change **−0.368 / −0.211 / −0.254 /
+0.412 ms** in table order. Foreground output changes **−3.2% / +4.1% / +1.0% /
−11.6%**. Byte accounting is more explicit, but this is not a broad latency or
throughput win. Keep the stalled/mixed loss rather than describing DRR as faster.

Round-matched local native +5 ms checks: **DRR 12/12 pass**, maximum +4.284 ms;
**current WRR 10/12**, **prior WRR 11/12**. Failed pairs:

| Variant / round / load | Bulk | Excess p99, ms |
| --- | --- | ---: |
| Current WRR / 1 / stalled | Off | +5.033 |
| Current WRR / 2 / noisy | Off | +6.238 |
| Prior WRR / 2 / noisy | Off | +7.594 |

Current WRR noisy/off round 2 reaches **70.651 ms maximum echo** (p99 7.886 ms);
prior WRR there reaches 43.298 ms (p99 9.241 ms). Largest observed DRR echo is
11.457 ms in noisy/mixed round 0. These are finite observations, not a promise
DRR removes spikes or identification of WRR's root cause. Prior/current WRR
medians also differ, so isolate neither source-layout nor host-load causality from
this matrix. Earlier DRR-unavailable baseline failures remain evidence.

### Background and bulk costs

Output-phase median checked EXEC rates, current WRR → DRR:
**6.20→7.74 MiB/s** noisy/mixed and **5.83→7.16 MiB/s** stalled/mixed
(about +25%/+23%). FS rates **2.94→3.34** and **3.17→3.02 MiB/s**.
DRR gives bulk more output progress in these cases; that is not free capacity.

Aggregate consumed background rate during foreground output changes
**46.94→48.40 / 39.23→41.44 / 44.49→46.64 / 38.96→37.22 MiB/s** in table
order. In stalled/mixed, continuously consuming non-selected-session panes fall
from roughly **3.52–3.55→3.04–3.09 MiB/s**. Their bytes still advance in these
finite checks, but bulk's improved EXEC rate accompanies worse foreground output
and background rates there. No sustained per-stream QoS gate passes from this.

Median run-level worst background output gaps change **15.78→17.07 /
20.31→22.53 / 16.57→15.62 / 19.42→21.66 ms**. Three groups worsen; a byte-fair
service rule does not inherently reduce wall-clock waiting. Every per-stream
counter, rate and maximum gap remains in the summary. Rate denominators include
warmup/background load, unlike foreground output timing. Unfinished bulk and
background bytes are canceled at teardown, not counted as successful completions.

### Default E1: another retained individual throughput miss

All scheduler/profile flags and host telemetry off, six source-order permutations:

| Variant | Median prompt p99, ms | 10 MiB, MiB/s | 100 MiB, MiB/s |
| --- | ---: | ---: | ---: |
| Native POSIX | 0.294 | 74.89 | 77.46 |
| Frozen prior agent | 0.643 | 76.99 | 79.98 |
| Current agent | 0.650 | 76.46 | 80.60 |

Current/prior median throughput ratios **99.3% / 100.8%**, current/native
**102.1% / 104.0%**. Nevertheless current/native fails **one of 12** output
pairs: round 4, 10 MiB, **91.98%**. Prior/native also fails one: round 1, 10 MiB,
**83.97%**. Median performance does not erase individual misses or prior failed
datasets. No absence-of-regression, host-load explanation or default rollout
qualification is established; agent code now includes an additional opt-in path
and fixed state even when it is not selected.

### Correctness, builds and provenance

Local Zig 0.16 ReleaseSafe: **159** standalone native executions, **91** opt-in
loop/adapter/transport executions with all scheduler/queue-profile flags,
**66** Python unit tests, **six weighted + six DRR** focus wire cases, **11**
ordinary PTY lifecycle cases, **16** fs/exec conformance cases and **two** real
pane/VT cases pass. Both static x86_64/aarch64 musl builds pass. Native Windows
adapter/transport compile-only checks pass; the adapter check supplies an empty
`build_options.embedded_powershell_integration` stub, not full GUI build/runtime.
Initial ad-hoc Windows commands omitted that dependency / named a nonexistent
test file; corrected entry points pass. Installed local agent/benchmark restored
to ReleaseSafe. Hosted CI has not been observed running the added wire/smoke steps.

Frozen ReleaseFast current agent:
`d8c35147b131fd27e552f75093984a6991cb1a05aa9972bd6c99e18464db2828`.
Frozen prior:
`a9fbdca6b44e043ab8113bba80e588c31bb35bfde21ccae46e680d6bbbd58b5d`.
Common benchmark:
`783730bfdbb2b3b7657bd809bd07907181f28f77a6252f273dabd32e9334f511`.

`2026-10-19-deficit-scheduler.json.gz` preserves all 154 measurements, raw
prompt samples, metadata/stderr, manifests, original per-file hashes and exact
orchestration. Uncompressed SHA-256:
`ee13cafc9954b216281b9a7daf94a895ef996c34bdd9ebaee6639f94aa71f742`.
Adjacent `.summary.json` retains individual background/bulk rates, results and
round-matched gates without raw prompt samples; `.patch.gz` reconstructs all
**16** runner source hashes on `ef8410c`, including the new module. Later CI/docs
edits are not part of the measured patch. Source hashes describe runner checkout,
not selected prior executable. All performance stages ran serially, without
concurrent builds/tests/benchmark jobs; correctness validation followed separately.

### Decision and remaining gates

Retain DRR as explicit research API and comparison, **not default scheduler**.
Its fixed-ready unequal-frame tests establish intended byte proportions; this
matrix supplies promising local tail results but mixed bulk/background/output
tradeoffs. Default E1 still fails an individual pair. Do not adjust acceptance
thresholds or silently replace weighted scheduling from these medians.

Still untested: sustained CPU/RSS/fairness/flood/arrival/fault behavior, genuine
loaded focus switches, 40/100/200 PTYs, ARM64 execution and native Windows GUI /
actual legacy WSL bypass parity. Separate focused/control transport remains a
competing design, not implemented by this step. These untested gates are distinct
from retained failed throughput/latency comparisons.
