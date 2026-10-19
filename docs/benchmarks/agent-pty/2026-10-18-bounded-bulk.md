# Bounded completed-job bulk experiment

Follow-up to [queue diagnostics](2026-10-18-queue-profile.md), committed as
`9120249`. **Default scheduling and pane backends remain unchanged.** A separate
`HOLLOW_AGENT_BOUNDED_BULK` flag enables this candidate only on connections that
explicitly negotiate experimental PTYs. Ordinary fs/exec connections ignore it.
No new wire messages/capabilities, focus hints or increased resource limits.

## Candidate and lifecycle boundary

Instead of queueing whole completed fs/exec captures, retain their bounded job
storage and issue one whole frame per rotating job visit alongside PTY quanta.
DATA payloads remain at most 16 KiB. The existing 65,624-byte PTY batch budget now
also constrains bulk issuance; control/error frames retain the existing global
4 MiB safety cap and can exceed that soft budget. Partial writes and per-stream
DATA-before-terminal ordering stay serialized by the same stdout writer.

Filesystem worker buffers contain already-framed replies. Validate and copy each
whole frame without changing its bytes. A single indivisible metadata frame larger
than the soft budget may queue **alone into an empty output buffer**, within
negotiated payload/global limits. Retain the blocked job's scheduling cursor so
smaller PTY chunks cannot indefinitely steal that space. This explicit atomic
exception is not a promise that every metadata frame is at most 16 KiB.

Completed captures retain admission slots and memory until their terminal frame
queues, but no longer own live-child cleanup behavior. Retained completions skip
process cleanup ticks while preserving delivery deadlines/cancellation. Reap
matching ignores already-reaped jobs, so a newly reused PID cannot overwrite an
older exit status. This reap guard also protects the legacy path. Both measured
variants below use the same ownership-safe binary; only the scheduler flag differs.

Cancellation/deadline discards unissued capture and emits one truncated error
after any already queued DATA. Connection teardown directly frees completed
captures. These changes do not prove general PID/process-group hardening, bounded
RSS under all concurrency, or hostile-control-flood fairness; those gates remain.

## Comparison: eight PTYs

Two complete 72-measurement matrices: native POSIX, dedicated agent, shared agent;
noisy or one stopped consumer; bulk off/mixed; three runs; 1,000 recorded prompt
samples after 32 checked warmups; 10 MiB foreground output. Both diagnostic flags
and host telemetry are off. Same ReleaseFast binaries, DebugAllocator, owner loop,
buffer sizes and alternating backend order. Stages themselves are not randomized.
No concurrent build/test jobs; machine-wide load/power mode remain uncontrolled.
These are headless Linux-client results inside WSL2, not Windows/WSL-bypass parity.

Mixed bulk uses checked 16 KiB `FS_READ` and 512 KiB non-PTY exec captures. Shared
mode uses the PTY connection; native/dedicated comparisons use a separate agent.
Both variants issue one alternating-width resize every 16 prompts, including
warmups. Issuance is checked, not acknowledgement or GUI-applied resize latency.
Counters include prompt warmups; pending bulk work is cancelled at teardown.

Medians of three per-run p99 values, not pooled latency:

| Load | Bulk | Shared legacy p99, ms | Shared bounded p99, ms | Bounded native/dedicated p99, ms |
| --- | --- | ---: | ---: | ---: |
| Noisy | Off | 6.990 | 6.420 | 1.577 / 2.553 |
| Noisy | Mixed | 10.157 | 7.332 | 5.286 / 4.240 |
| Stalled | Off | 7.327 | 7.225 | 1.262 / 2.428 |
| Stalled | Mixed | 10.297 | 6.873 | 4.366 / 3.933 |

Mixed medians improve about 28%/33%. Nevertheless, **five of 12 bounded
shared/native pairs still exceed the local +5 ms check**, all with bulk off,
including all three stalled cases. The legacy variant exceeds it in eight pairs.
The six bounded mixed pairs stay within this local check, but the comparator is
POSIX, not the required legacy WSL bypass. A smaller excess against a native
client also contending with separate-agent bulk is not a universal parity pass.

### Bandwidth and fairness tradeoff

Median rates during 10 MiB output runs; arrows mean legacy → bounded:

| Load, mixed bulk | Foreground PTY, MiB/s | Aggregate PTYs, MiB/s | Completed fs, MiB/s | Completed exec, MiB/s |
| --- | ---: | ---: | ---: | ---: |
| Noisy | 5.62 → 7.74 | 45.00 → 61.90 | 4.03 → 2.72 | 24.46 → 6.19 |
| Stalled | 6.61 → 8.92 | 46.14 → 62.51 | 4.11 → 2.96 | 25.12 → 6.69 |

This is **not a free latency improvement**. Exec payload rate falls about
73–75%, fs rate about 28–33%, while PTYs receive more bandwidth. Equal scheduling
visits do not imply equal application-byte throughput: fs reads also issue terminal
metadata, and completed exec captures have dispatch/turnaround gaps. Bulk operations
still complete with checked bytes, but zero starvation is not established by a
nonzero completion count. Admission delay and CPU/RSS scaling remain unqualified.

All consuming PTYs make checked distinct-byte progress. The shared stopped buffer
stays exactly 65,536 bytes. Mixed worst background delivery gaps improve from
21.49/25.58 ms to 19.60/21.41 ms for noisy/stalled loads, but bulk-off noisy worsens
from 19.19 to 25.40 ms. Keep that tail: one bounded bulk-off noisy run has 7.39 ms
p99 and a 25.38 ms individual prompt maximum. No universal fairness claim follows.

## Instrumented follow-up

Separate three-run shared/stalled traces, bulk off/mixed, 12 measurements per
variant. Host telemetry and queue profiling are enabled in both; these numbers
must not replace the diagnostics-off matrix above. Snapshot observations aggregate
all streams and include startup/priming/warmups, not causally matched echoes.

Across the three **mixed prompt** traces:

| Observation, maximum | Legacy | Bounded |
| --- | ---: | ---: |
| Wire bytes ahead of an input ACK | 590,710 | 65,624 |
| Input ACK queue residence, ms | 8.957 | 5.073 |
| Resize ACK queue residence, ms | 3.125 | 1.703 |
| PTY DATA enqueue-to-first-write, ms | 8.814 | 5.096 |
| PTY DATA enqueue-to-complete-write, ms | 10.654 | 8.177 |

Input ACK means queued, not child-consumed; the prompt client does not await each
ACK. Timings end at successful agent stdout writes, not GUI/VT consumption, and
exclude credit/ready-to-enqueue delay. Filesystem spans now represent individual
issued frames instead of whole legacy worker replies; do not directly compare
their span-count/latency histograms as if units were unchanged. PTY/ACK classes
retain their original span units.

Keep the instrumented legacy bulk-off outlier too: p99 27.12 ms, individual prompt
maximum 58.19 ms, ACK queue residence 39.36 ms and PTY DATA completion 44.80 ms.
It is not excluded from summaries or used to claim that bounded bulk fixes all
tails. The unprofiled bulk-off comparisons above show the remaining problem.

## Dedicated E1 checks

Five runs per variant, each with 5,000 recorded prompt samples and 10/100 MiB
output. Diagnostics/host telemetry are disabled. Agent/native ratios are ratios
of backend medians, not pooled observations:

| Scheduler flag | Native/agent prompt p99, ms | 10 MiB agent/native median | 100 MiB agent/native median |
| --- | ---: | ---: | ---: |
| Absent, default | 0.298 / 0.595 | 93.8% | 103.9% |
| Enabled | 0.281 / 0.575 | 100.2% | 101.4% |

**The default 10 MiB median is below 95%.** Preserve every slow pair, including
54.72 versus 70.24 MiB/s in its first run. Enabled mode also has a sub-95% short
pair (62.97 versus 73.03 MiB/s). These short-transfer variations neither qualify
the default nor prove that the scheduling flag repairs dedicated performance.

### Alternating source comparison: unresolved default-path regression

Freeze the exact prior measured agent (`9120249` source, SHA-256
`87878eba7991bbd6810932743efbf0f80a16e2cc6606fc59d13d26715a18613c`) and
candidate (`e0ab364efe57af3cdfe62ea4fb50cd77b2686bd8761b8cce6392f374f321e7d4`).
Run five independent old/new rounds, alternating variant order, with the same
unchanged benchmark binary and diagnostics disabled. Every variant keeps its own
native comparison; each round uses one runner invocation per variant. Backend
order within each invocation is native then agent, so this controls source-variant
order better than native/agent order. These 60 measurements supplement rather
than replace the failed default E1 dataset.

| Agent binary, default flag absent | 10 MiB agent/native median | 100 MiB agent/native median |
| --- | ---: | ---: |
| Prior | 104.1% | 99.8% |
| Candidate | 92.0% | 96.3% |

Candidate short-transfer result again misses 95%. Its worst 100 MiB pair is
46.15 versus 69.64 MiB/s (66.3%). This is a **possible default-path performance
regression**, not evidence that the opt-in flag affects unselected scheduling.
Additional branches/layout/lifecycle changes or external variance remain possible;
no root cause is established. Do not accept the candidate as default-qualified.

Separate diagnostic-only old/new checks, three alternating rounds, enable matching
host telemetry plus existing `HOLLOW_AGENT_PROFILE` counters (18 measurements, no
native comparator). Median 10/100 MiB rates are 70.53/72.48 MiB/s prior versus
72.05/75.75 MiB/s candidate. Every output run reports zero ready-output poll stalls,
with near-full DATA frames. These instrumented runs do not reproduce the loss,
but diagnostic overhead and different timing mean they cannot dismiss unprofiled
failures or identify their cause.

## Evidence and reconstruction

Archives `2026-10-18-bounded-{before,after,trace-before,trace-after,default-e1,enabled-e1}.jsonl.gz`
contain 228 completed measurements. `2026-10-18-bounded-codecheck.json.gz` and
`2026-10-18-bounded-io-check.json.gz` preserve 60 and 18 supplementary measurements
respectively, with each original invocation's metadata and manifest. Total: **306**.
`2026-10-18-bounded-summary.json` retains per-run results/counters/maxima and raw
SHA-256 values; histogram buckets and raw samples remain in compressed originals.
Every result was revalidated for identity, exact bytes/checksum, progress and
diagnostic accounting; all report `qualification: false`.

`2026-10-18-bounded.patch.gz` reconstructs all measured candidate source files
against `9120249`; all 13 source hashes were checked for every dataset. For explicit
old-agent overrides, workspace source hashes describe the current runner workspace,
**not** the selected older agent. Its binary hash matches the independently archived
[prior measured build](2026-10-18-queue-profile.md).

Two interrupted files remain separate, excluded from comparisons:
`2026-10-18-bounded-draft-interrupted.jsonl.gz` has 53 completed measurements before
the ownership fix; matching `2026-10-18-bounded-draft.patch.gz` preserves those
sources. `2026-10-18-bounded-candidate-interrupted.jsonl.gz` has four completed
candidate measurements before the harness's 120-second orchestrator timeout;
its sources match the final measured candidate patch. All interrupted source
hashes were reconstructed too. Neither partial file is silently merged with a
complete stage or used as performance evidence. The completed legacy baseline was
retained; remaining stages restarted with timeout disabled and fresh filenames.

Reproduce the unprofiled matrix after a ReleaseFast build:

```sh
python3 scripts/agent_pty_bench.py --backend all --sessions 8 \
  --load noisy stalled --bulk off mixed --resize-every 16 --runs 3 \
  --samples 1000 --size-mib 10 --output legacy-new.jsonl
HOLLOW_AGENT_BOUNDED_BULK=1 python3 scripts/agent_pty_bench.py --backend all \
  --sessions 8 --load noisy stalled --bulk off mixed --resize-every 16 \
  --runs 3 --samples 1000 --size-mib 10 --output bounded-new.jsonl
```

Run diagnostic stages separately with `HOLLOW_AGENT_QUEUE_PROFILE=1 --telemetry`
and `--backend shared --load stalled`; retain bulk off/mixed and other parameters.
Dedicated E1 uses `--runs 5 --samples 5000 --size-mib 10 100`, no profiling/telemetry.
Explicit source comparisons use `--agent <frozen-agent>` and one invocation per
round/variant; keep binary hashes and ordering as in archived manifests.

## Decision

Keep the candidate explicitly opt-in for further research; **reject shared-pane
rollout and do not change default scheduling**. It bounds mixed bulk backlog and
improves mixed PTY latency by materially redistributing bandwidth away from bulk.
Bulk-free latency still fails local checks, and fairness/throughput tails remain.
Next work needs focus/session-aware priorities, bulk QoS/admission tradeoffs,
per-stream ready-to-enqueue correlation and competing split lanes, followed by the
full resource/fault/scale and native Windows/legacy-bypass/GUI qualification matrix.
