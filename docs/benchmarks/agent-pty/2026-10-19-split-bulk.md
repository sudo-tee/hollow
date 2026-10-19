# Separate bulk-agent topology experiment

Base revision: `9a4dfe9` (focus correlation committed). Benchmark-only option
`--separate-bulk` puts fs/exec on an independent connection to a second instance
of the **same binary**, using the same connector argv and ordinary handlers.
Shared PTYs keep their existing connection, with flat or explicitly negotiated
static focus scheduling. No agent, protocol, production pane routing or defaults
change in this step.

## Scope and limits

This tests **two processes/two transports**, not two lanes in one agent. Removing
bulk from the PTY stdout pipe also removes bulk worker/event-loop contention from
that agent and changes OS scheduling, resources and failure boundaries. Differences
cannot be attributed solely to head-of-line blocking. No dedicated priority
control path, split focused/background PTYs or separate client bulk-consumer
thread exists. The same owner loop services foreground then bounded background
reads and bulk polling. CPU/RSS and connection/bootstrap costs are not measured.

Both topologies warm one checked FS_READ and EXEC before starting load, excluding
cold separate-agent startup from timed workloads. fs/exec pending requests are
abandoned at teardown and an owned separate connection destroyed, never silently
rerouted onto PTYs. Existing 16-job capacity stays **per connection**. Co-located
mixed load still allows at most 14 PTYs; separated mixed load can use 16 PTYs plus
two bulk operation slots elsewhere, spending more total resources. The 16-PTY
checks are correctness-only, not equal-resource comparisons.

`--separate-bulk` rejects non-shared backends and inactive bulk, including a mixed
CLI selection containing `off`. Native/dedicated backends retain their existing
separate-agent bulk placement without this option. Results explicitly report
`separate_bulk` and `bulk_lane`; parser rejects identity mismatches and malformed
booleans rather than relabeling old co-located data.

## Workloads

Three rounds rotate five variants: native POSIX, flat/shared bulk, flat/separate
bulk, focus/shared bulk and focus/separate bulk. Not all 120 permutations are
covered. Within each variant, noisy then stalled load and prompt then output
order stay fixed. Each case uses eight PTYs, 1,000 recorded prompts after 32
warmups, 10 MiB output, resize every 16 prompts, repeated checked 16 KiB FS_READ
and 512 KiB EXEC captures. Focus uses two logical groups of four and only the
initial pre-load update: no refresh, switching or loaded ACK measurement.

All diagnostic/telemetry flags are off. Shared variants explicitly enable bounded
bulk; focus variants additionally enable focus. Separate bulk uses ordinary
HELLO, so inherited scheduler flags do not activate experimental PTY scheduling
there. Native bulk also uses ordinary HELLO. Bulk counts include only complete
checked operations in the load window; priming operations are excluded. Background
and bulk rates use `background_elapsed_ns`, which includes warmup, unlike
foreground throughput or recorded prompt latency. Unfinished background/bulk work
is canceled at teardown, not falsely counted as completed bytes.

Additional correctness cases exercise fs-only/exec-only, flat/focus and both
placements at eight PTYs with 200 prompts/10 MiB, 64 KiB EXEC and resize every
eight; separated mixed load also exercises full 16-PTY admission. Independent
transport death, connector reconnect, remote targets and sustained fault/soak
behavior are not qualified by these finite local cases.

Example (prepared local binary, Zig 0.16):

```sh
HOLLOW_AGENT_BOUNDED_BULK=1 HOLLOW_AGENT_FOCUS_SCHEDULER=1 \
python3 scripts/agent_pty_bench.py --backend shared --focus-scheduler \
  --separate-bulk --sessions 8 --load noisy stalled --bulk mixed \
  --runs 3 --samples 1000 --size-mib 10 --resize-every 16 \
  --output split-bulk.jsonl
```

Run co-located variant without `--separate-bulk`; flat variant also omits
`--focus-scheduler` and clears focus flag. Native variant uses `--backend native`
and clears both scheduler flags. Remote runs need prepared multi-connection
connector argv and explicit target zero fixture; no deployment/target identity
attestation is performed. This dataset is headless Linux inside WSL, not native
Windows GUI or actual WSL-bypass parity.

## Results

**80** ReleaseFast measurements validated: 60 main-matrix, 16 fs-only/exec-only
correctness cases and four full-admission cases. No harness failures, corrupt
bytes, missing required bulk completions or unexpected stalled consumption in
these finite runs. A separate **two-case ReleaseSafe profile smoke** checks full
16-PTY separated mixed load with periodic same-target focus refresh, host telemetry
and queue/focus diagnostics; it is excluded from performance comparisons.

### Foreground: separation is not an interactive-latency fix

Median of three run-level values, main mixed-load matrix only:

| Variant | Noisy echo p99, ms | Stalled echo p99, ms | Noisy output, MiB/s | Stalled output, MiB/s |
| --- | ---: | ---: | ---: | ---: |
| Native POSIX | 3.785 | 3.984 | 46.98 | 58.10 |
| Flat / shared bulk | 6.151 | 6.289 | 9.41 | 10.67 |
| Flat / separate bulk | 7.079 | 7.468 | 9.76 | 11.13 |
| Focus / shared bulk | 5.310 | 4.932 | 28.82 | 29.13 |
| Focus / separate bulk | 6.895 | 5.946 | 25.54 | 29.42 |

Separating bulk worsens all four median echo p99 comparisons at equal scheduling
policy: flat by **0.927/1.179 ms**, focus by **1.584/1.013 ms** (noisy/stalled).
Flat foreground output improves about 4%; focus/noisy falls **11.4%**, while
focus/stalled stays within 1%. This does not support adopting separate bulk as
the foreground-latency solution. No claim of causal attribution to extra CPU
contention, buffering or pipe structure is justified by these measurements alone.

All **24/24** round-matched agent/native loaded prompt comparisons in this
particular matrix meet the local +5 ms rule (maximum **+3.910 ms**). That includes
co-located controls; it is not evidence separation cleared a previously failed
gate. Earlier bulk-free and focus-loaded misses remain unresolved, not erased by
a different workload/repeat passing. Native here is Linux POSIX with seven
background panes and separate bulk, not actual Windows/WSL bypass. Only eight
PTYs/two logical groups and static focus were measured for these comparisons.

### Bulk benefits substantially; background tradeoffs remain

Prompt-phase median checked completion rates (includes warmup in denominator):

| Variant | Noisy FS, MiB/s | Noisy EXEC, MiB/s | Stalled FS, MiB/s | Stalled EXEC, MiB/s |
| --- | ---: | ---: | ---: | ---: |
| Native POSIX + separate bulk | 6.89 | 33.48 | 7.97 | 36.34 |
| Flat / shared bulk | 3.44 | 8.38 | 3.69 | 9.45 |
| Flat / separate bulk | 11.83 | 58.36 | 11.83 | 57.93 |
| Focus / shared bulk | 3.55 | 7.35 | 3.49 | 8.33 |
| Focus / separate bulk | 11.69 | 58.81 | 12.44 | 60.97 |

Separated EXEC completion throughput is **6–8×** its co-located counterpart in
these prompt runs. This is a useful bulk-progress result, not equal-resource
speedup: the second agent has its own stdout queue, loop and workers, and is no
longer subject to the PTY connection's negotiated bounded-bulk rotation.

During output, aggregate consumed background rate rises from **65.84→67.79** and
**63.67→66.83 MiB/s** for flat noisy/stalled, and **42.62→50.41** and
**40.08→50.16 MiB/s** for focus. Focus/noisy non-selected-session panes rise from
roughly **3.68–3.73→4.02–4.22 MiB/s**, while foreground output decreases. Native
background rates are much larger; native readers retain roughly 4 MiB versus
64 KiB per agent pane, so neither equal resources nor aggregate throughput parity
is established. Per-pane counters/rates and maximum observed gaps are preserved
in the summary, not replaced with aggregate numbers alone.

Median run-level worst observed background gap during output changes
**15.85→15.64 ms** / **15.54→15.14 ms** for flat noisy/stalled,
**17.21→18.23 ms** / **21.86→16.70 ms** for focus noisy/stalled. Positive total
bytes and these finite gaps do not prove sustained starvation freedom, flood
resistance or fairness under arrivals. No byte-fair DRR or focused/control lane
was implemented by this experiment.

### Validation and provenance

Local Zig 0.16 ReleaseSafe build and **84** loop/adapter/transport executions pass;
**65** Python unit tests pass. Three direct native-runner checks reject separate
bulk on native/inactive configurations and reject 16-PTY co-located mixed load
before starting a connection. Real separated fs/exec byte checks and both
flat/focus full 16-PTY cases pass. CI adds a full-admission separated-bulk smoke;
hosted CI execution is not claimed. Installed local agent and benchmark restored
to ReleaseSafe. Agent/transport production sources were not modified, so no new
default-path E1 run is claimed: prior **2/12 current** and **3/12 prior** failed
local throughput pairs remain the latest default evidence.

Frozen ReleaseFast agent SHA-256 (identical to focus-profile binary):
`a9fbdca6b44e043ab8113bba80e588c31bb35bfde21ccae46e680d6bbbd58b5d`.
Frozen common benchmark:
`4ca12275bece3611d9307317dbd3f5b98dddcce341ea9836e3609908bb24ddbe`.

`2026-10-19-split-bulk.json.gz` retains 80 validated measurements, original
metadata/stderr, manifests, invocation order, orchestration and per-file digests.
Uncompressed JSON SHA-256:
`640560359bf3b3e1a8fdd74f99e7f1070293095dbf20f7b67b20ea09409cabba`.
`2026-10-19-split-bulk.summary.json` retains run-level results without raw prompt
samples, individual background rates, bulk rates and each round-matched local
gate result. `2026-10-19-split-bulk.patch.gz` reconstructs measured sources on
`9a4dfe9`; all **15** runner source hashes verified. Later CI/docs edits are not
part of that measured patch. Source hashes describe runner checkout; selected
binary identities are independently frozen above. Serial performance runs had no
concurrent builds/tests/other benchmark jobs; uncontrolled host load/power remains
a limitation. Machine-specific orchestration paths need adapting for replay.

The separate `2026-10-19-split-bulk-safe-profile.jsonl.gz` retains both ReleaseSafe
correctness measurements, including repeated queue/focus snapshots. Its
uncompressed SHA-256:
`83140f83b4b29df102e8468241730288ba7e78c63ecd6bd621f53150065bd11e`.
Agent `37daa1dbfdef5c9643d486e025bc40cbaf668321253efaf27a445606df1e8ce5`;
benchmark `63f515b2c265a22eb833a016ec96b47455a4d2702dc3881b78358b3826b0959e`.
All 15 final source hashes match main measured reconstruction.

### Decision: retain research switch, reject automatic split routing

* **Measured benefit:** much faster checked bulk completion with independent
  transport/agent; finite correctness and per-connection admission checks pass.
* **Not improved here:** foreground latency. Automatic separate-bulk placement is
  not justified by this result and remains absent from production routing.
* **Previously failed, unresolved:** intermittent default throughput and earlier
  loaded/bulk-free latency comparisons. This dataset does not requalify them.
* **Still untested:** sustained resources/fairness/faults, genuine loaded focus
  switches, 40/100/200 PTYs, native Windows GUI and actual legacy WSL bypass.

Next comparison should constrain bytes fairly (hierarchical DRR) or genuinely
isolate focused/control transport, not assume a separate bulk process fixes
interactive tails. Preserve this rejected latency approach and its real bulk
benefit. No default routes, scheduler weights or release gates change.
