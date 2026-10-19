# Measured PTY queue compaction optimization

Follow-up to [default-path source isolation](2026-10-18-default-source-isolation.md).
The investigation found overlapping queue-tail copies consuming roughly two-thirds
of sampled agent-image user CPU in both frozen binaries. This experiment changes
**one hot copy** in `main.Agent.streamPty` from `std.mem.copyForwards` to Zig 0.16
`@memmove`, with equal-length source and destination slices.

The PTY queue remains 64 KiB. Credit, frame sizes, scheduling, terminal ordering,
protocol and pane selection are unchanged. No ring buffer, queue enlargement,
focus policy, transport lane, or default bounded-bulk enablement is introduced.
Other compactions remain unchanged to keep the experiment narrow. This is not
an asserted fix for the intermittent default-path losses recorded previously.

## Frozen builds and correctness

Base: `1df1b67`. ReleaseFast, same Zig 0.16.0 and unchanged headless benchmark
SHA-256 `ded70caa8d596400641740dec834413e34320d653df52c3c7731a25566fca47c`.

* Pre-change agent: `e0ab364efe57af3cdfe62ea4fb50cd77b2686bd8761b8cce6392f374f321e7d4`.
* `@memmove` agent: `c6bd236f441f930775a38a960f0db576368c3b31a312290ea5a58ff8aa581370`.

Disassembly replaces the unrolled byte-load/store compaction loop with a call to
`compiler_rt.memmove.memmoveFast`. New deterministic test checks nonuniform
payloads and exact retained tails for six cases: 64 KiB with 16 KiB credit,
32,769 bytes with one-byte credit, 16,385 bytes with 16 KiB credit, exactly 16 KiB,
full four-frame 64 KiB draining, and an 8,193-byte partial quantum. Headers, payload
order, chunk limits and remaining credit are verified, not just zero-filled sizes.

Initial ReleaseSafe agent-loop and real PTY-adapter rerun: 25 + 30 test executions
pass. This includes existing bounded-bulk ordering, retained-lifecycle and exact
large stdout/stderr/metadata cases. Further validation is recorded below.

## Dedicated, diagnostics-off comparison

54 measurements: all six permutations of **native POSIX / pre-change / memmove**,
with each variant occupying each position twice. Each variant invocation runs
5,000 recorded prompt samples after 32 checked warmups, then 10/100 MiB output.
Each case creates fresh processes, not a reused warm connection. Fixed output
size order is not balanced. Same DebugAllocator, effective CPUs 0–5, no bulk,
agent flags or host telemetry. No concurrent builds/tests or benchmark jobs;
Windows load and power state remain uncontrolled.

Medians of independent per-run statistics, not pooled samples:

| Variant | Prompt p99, ms | 10 MiB, MiB/s | 100 MiB, MiB/s |
| --- | ---: | ---: | ---: |
| Native POSIX | 0.298 | 67.82 | 70.76 |
| Pre-change | 0.563 | 74.79 | 73.86 |
| `@memmove` | 0.596 | 72.48 | 76.45 |

The optimized variant is **96.9% / 103.5% of pre-change medians** at 10/100 MiB,
and 106.9% / 108.0% of native medians. Thus do **not** claim a general throughput
win: short-transfer median falls 3.1%, while long-transfer median rises 3.5%.
Prompt p99 median also rises about 0.033 ms in this stage. These differences are
small relative to observed between-run variability and do not establish causality.

Preserve every slow run: optimized 100 MiB has a 69.61 MiB/s minimum, compared with
that round's native 64.39 MiB/s; optimized 10 MiB
minimum 64.90 MiB/s versus that round's native 68.24 MiB/s is about 95.1%.
All 12 optimized/native output pairs stay above the **local POSIX** 95% check in
this dataset, not the required Windows/legacy-WSL gate. Pre-change results also
pass this check here. Neither invalidates earlier failed datasets or proves the
intermittent candidate losses fixed.

Whole-invocation CPU medians are native 2.602 seconds, pre-change 4.741, optimized
4.720. User CPU medians fall 0.688 → 0.627 seconds, while system medians rise
4.025 → 4.089 seconds. These include Python checksumming, client, agent and child
workloads across three cases, not isolated agent or transfer CPU. Do not add
separate medians as though they described a single representative run.

## Dedicated evidence

`2026-10-18-pty-compaction.json.gz` preserves all 54 results and original
invocation/source/binary/resource manifests. Its uncompressed SHA-256 is
`d8f1ffe4ced159450f431da071509ef43c78c6a313d3256d11d337792ee5ec36`.
`2026-10-18-pty-compaction-summary.json` keeps per-run rates/tails and resource
deltas. `2026-10-18-pty-compaction.patch.gz` reconstructs measured sources against
`1df1b67`; all 13 workspace source hashes were checked. Explicit frozen agent
hashes, not runner-workspace hashes, identify the selected pre-change binary.

Orchestration is archived alongside the results. Reproduce six balanced rounds
with the frozen pre/post agents, `--workload both --samples 5000`, no profiling or
bounded-bulk flags and fresh output names. Native remains POSIX, not bypass.

## CPU-sampling follow-up

Separate 18 diagnostic measurements compare the pre-change and optimized agents
with the same `perf record -q -e cpu-clock:u -F 997` wrapper and host telemetry as
the source-isolation sampling stage. Three rounds alternate binary order; each
variant runs prompt/10 MiB/100 MiB. Both agent profiling flags remain absent.

Across three 100 MiB runs, pre-change has 249 agent-image samples, including 164
at `mem.copyForwards`; optimized has 94 agent-image samples, none at
`mem.copyForwards` and 14 at the compiler-runtime memmove implementation. Complete
inherited-tree sample counts are 346/197, including child workload/guardian work.
Absolute IPs were resolved against each exact binary, not guessed from unresolved
perf report offsets. Zero lost samples reported in all 18 recordings.

This supports removing the targeted scalar-copy CPU work. It is **not** a 62%
wall-time improvement: samples exclude kernel and off-CPU time, counts are small,
and telemetry/sampling affect the system. Diagnostic median 10/100 MiB rates are
67.60/69.18 MiB/s before versus 68.70/70.53 after; prompt p99 0.559/0.542 ms.
Use the diagnostics-off comparison above for throughput observations.

`2026-10-18-pty-compaction-perf.tar.gz` preserves all 18 raw results, original
recordings, reports, manifests, orchestration and full per-IP symbolization.
Uncompressed tar SHA-256:
`8589c31013ac3b565276f0e947b19172ecbaaa45f7e59789e05e15a8fd1124f6`.
The adjacent `2026-10-18-pty-compaction-perf-summary.json` keeps per-run summaries.

## Mixed shared-contention check

48 further diagnostics-off measurements: three pre/post rounds, binary order
alternating, eight shared PTYs, noisy/stalled neighbors, mixed checked fs/exec,
1,000 recorded prompt samples, 10 MiB foreground output, resize every 16 prompts.
Within each binary invocation group the bounded-bulk flag is tested off then on;
this flag order and noisy-before-stalled order are **not** randomized. No native
or dedicated comparator is included here, so this cannot pass a loaded parity
gate. No concurrent builds/tests or benchmark jobs ran.

Median per-run p99, with arrows indicating pre-change → optimized:

| Bounded bulk | Load | Prompt p99, ms | Foreground PTY, MiB/s | Aggregate PTY, MiB/s | Completed fs, MiB/s | Completed exec, MiB/s |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Off | Noisy | 9.977 → 9.108 | 6.10 → 6.14 | 48.85 → 49.23 | 4.28 → 4.55 | 26.25 → 30.41 |
| Off | Stalled | 9.154 → 9.148 | 6.89 → 6.91 | 48.16 → 47.92 | 4.26 → 4.51 | 26.51 → 29.71 |
| On | Noisy | 6.827 → 6.855 | 8.09 → 7.99 | 64.78 → 63.70 | 2.79 → 2.71 | 6.32 → 6.39 |
| On | Stalled | 7.101 → 6.557 | 9.03 → 9.28 | 63.04 → 64.75 | 3.02 → 3.09 | 6.77 → 7.42 |

CPU savings do not remove shared contention. The bounded scheduler still shifts
bandwidth away from bulk; the copy change does not establish a bulk QoS floor.
All consuming PTYs progress with checked distinct bytes, fs/exec completions
remain byte/length checked, and the stopped shared buffer remains exactly 65,536
bytes. Counters include warmups; unfinished bulk/background work is cancelled at
teardown, not counted as a completed background transfer.

Keep adverse observations: bounded/noisy worst background gap worsens
20.67 → 21.33 ms and bounded/stalled 20.27 → 20.31 ms. Default/noisy improves
25.67 → 22.91 ms; default/stalled 20.65 → 20.56 ms. Progress and bounded queues in
these short runs are not proof of zero sustained starvation or an RSS/resource gate.

`2026-10-18-pty-compaction-shared.json.gz` preserves all 48 results with original
metadata and source hashes; adjacent `2026-10-18-pty-compaction-shared-summary.json`
keeps per-run counters and rates. Uncompressed JSON SHA-256:
`bedf536bb66bf7162fb5f65dc5fb2e27ae5def5251082a235764ac3b26fd87a7`.
Reproduce with frozen pre/post agents and fresh filenames, each alone:

```sh
python3 scripts/agent_pty_bench.py --backend shared --agent <frozen-agent> \
  --sessions 8 --load noisy stalled --bulk mixed --resize-every 16 \
  --runs 1 --samples 1000 --size-mib 10 --output <new-file.jsonl>
```

Repeat three rounds alternating binaries; within each binary repeat with
`HOLLOW_AGENT_BOUNDED_BULK=1`. Keep both profiling flags and telemetry off.

## Validation and decision

All **120 compaction measurements** (54 dedicated, 18 diagnostic, 48 shared) were
revalidated. All 13 workspace source hashes match the reconstructed measured patch;
frozen pre/post agent hashes identify the actual binary in each case. Together
with the 144 source-isolation measurements, this follow-up preserves **264** new
measurements, all explicitly `qualification: false`.

Final local Zig 0.16.0 ReleaseSafe correctness:

* 138 standalone native test executions pass, including imports: agent loop now
  25; PTY adapter 30; remaining protocol/fs/transport/operations/manager/local
  targets unchanged.
* Bounded bulk plus queue profiling enabled: loop/PTY/transport rerun 70 pass.
* 58 Python harness unit tests, 11 bounded-flag PTY wire/lifecycle cases, 16
  ordinary local fs/exec conformance cases, and two real pane/VT integration cases pass.
* Both Linux musl architectures cross-build. Installed local agent restored to
  ReleaseSafe; ARM64 execution and native Windows GUI remain unverified.

**Keep the narrow overlap-safe compaction change as a measured CPU optimization,
not a general latency/throughput win or a fix for intermittent source-comparison
losses.** Existing pane backends and default scheduler selection remain unchanged.
Shared rollout stays rejected/unqualified. Next scheduling work still needs explicit
session/focus inputs, background/bulk QoS and competing split lanes; broader
CPU/RSS/fault/scale and Windows/legacy-WSL qualification remain open. Earlier failed
throughput datasets are not invalidated by the passing local pairs in this stage.
