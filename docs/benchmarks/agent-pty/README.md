# Dedicated PTY adapter measurements

The [initial shared-connection experiment](2026-10-18-shared-pty.md) adds a separate
1/4/8/16-session noisy/stalled matrix; it does not change pane defaults.
The [eight-PTY mixed filesystem/exec follow-up](2026-10-18-mixed-8.md) measures
additional contention without changing production scheduling.
The [agent-side queue diagnostics follow-up](2026-10-18-queue-profile.md) adds
opt-in dispatch/write timing, an on/off comparison and a dedicated E1 recheck.
The [bounded-bulk scheduling experiment](2026-10-18-bounded-bulk.md) improves mixed
shared latency by reducing bulk bandwidth, but still fails bulk-free latency
checks. Its candidate default-path short-transfer throughput also misses 95% in
two checks; root cause remains unresolved. Neither candidate nor shared rollout
is performance-qualified. Earlier successful medians below remain historical.
The [balanced source-isolation follow-up](2026-10-18-default-source-isolation.md)
retains intermittent losses without attributing them to an unproven cause.
Its [measured compaction experiment](2026-10-18-pty-compaction.md) replaces one hot
overlapping copy; local throughput medians are mixed, not a general speed claim.
The [explicit focus/session baseline](2026-10-18-focus-scheduler.md) redistributes
foreground output share through hierarchical weighted visits, not byte-fair DRR.
It retains one local loaded-latency miss, bulk/background tradeoffs and a short
smoke `BulkStarved` failure. Defaults and rollout status remain unchanged.
The [per-sequence focus diagnostics](2026-10-19-focus-profile.md) correlate accepted
updates with captured/credited readiness, new DATA enqueue and stdout payload
writes, retaining explicit censoring/overflow. Its 107 measurements do not qualify
rollout; default E1 still has failed individual current/prior comparisons.

**Update:** [profiling and throughput fixes](2026-10-18-throughput-fix.md) bring
local dedicated-agent throughput to roughly 98% / 101% of native medians at
10/100 MiB with GUI-matched allocator, and 96% / 100% with the original page
allocator. Original results below remain historical baselines, not current speed.

These are Linux-client, headless measurements inside WSL2, **not native Windows
GUI or WSL-bypass qualification**. Native means Hollow's existing POSIX PTY;
agent means one dedicated local agent connection through the native Zig adapter.
Both run the same `/bin/sh` workload. The host kernel is
`6.18.54.1-microsoft-standard-WSL2`, x86_64, glibc 2.43.

Build and runner commands:

```sh
zig build --build-file build-agent.zig agent agent-pty-bench -Doptimize=ReleaseFast
python3 scripts/agent_pty_bench.py --runs 5 --samples 5000 --size-mib 10 100 --output /tmp/opencode/agent-pty-local-20261018.jsonl
```

Each dataset has five independent runs per backend/workload/size, 5,000 recorded
prompt samples per run after 32 verified warmups, exact output-byte verification,
SHA-256, and clean exits. Backend order alternates. Metadata retains executable
and source hashes and exact launcher paths; revision points to `8c57cdf` with the
uncommitted measurement implementation represented by source hashes. Raw latency
samples are not pooled. The tables report median per-run statistics and ranges.

## Unbuffered host reader baseline

This original benchmark used `page_allocator`, unlike the GUI's thread-safe
`DebugAllocator`. Later datasets label/select the allocator explicitly; see the
linked investigation rather than interpreting 16–17% as measured GUI performance.

Raw dataset: [`2026-10-18-local-unbuffered.jsonl.gz`](2026-10-18-local-unbuffered.jsonl.gz).

| Metric | Native median (range) | Agent median (range) |
| --- | --- | --- |
| Prompt p99, ms | 0.320 (0.287–0.411) | 0.643 (0.576–0.698) |
| 10 MiB output, MiB/s | 75.04 (48.69–78.51) | 11.80 (9.70–14.62) |
| 100 MiB output, MiB/s | 72.15 (59.53–78.24) | 12.23 (11.37–12.92) |

Uncompressed JSONL SHA-256:
`43f8d2140a7b4adc0f3086f3d7887c54ec3ed60370f2161d323e044fbd98c1a3`.
Benchmark executable SHA-256:
`af61b7307b1be4a4e69cd523b3c47103675cf4ab979f57a91b2042e8a686bc3f`.

Conclusion: **keep native defaults; investigate adapter throughput**. Prompt
overhead is sub-millisecond here, but agent output throughput is only about
16–17% of native median. This is not the plan's WSL-bypass numeric gate, and no
backend switch follows from the latency result. No loaded-neighbor, GPU, CPU/RSS,
power-mode control, or 40/100/200-PTY scalability evidence is established.

## Rejected read-ahead experiment

This experiment predates the scheduling and allocation fixes linked above.

The experiment replaced the host's separate unbuffered frame-header/payload reads
with one 64 KiB streaming reader. No wire format, credit budget or agent changes
were made. Raw dataset:
[`2026-10-18-local-buffered.jsonl.gz`](2026-10-18-local-buffered.jsonl.gz).
The preserved [`buffered-reader-experiment.patch.gz`](buffered-reader-experiment.patch.gz) also includes parser boundary,
truncation and negotiated-limit tests added after measurement; its 13 transport
tests passed. Those tests did not affect the measured executable.

| Metric | Native median (range) | Agent median (range) |
| --- | --- | --- |
| Prompt p99, ms | 0.301 (0.294–0.367) | 0.578 (0.549–0.775) |
| 10 MiB output, MiB/s | 73.09 (50.27–76.09) | 11.30 (9.46–13.44) |
| 100 MiB output, MiB/s | 75.29 (71.40–76.69) | 11.64 (11.19–11.91) |

Uncompressed JSONL SHA-256:
`ba7b6014e450e01131b6ed7515087aba352cc8548845fd21a89bd1b360cfa7e0`.
Benchmark executable SHA-256:
`b723c68af14d7e02023ca0dd2295e6dba4cccf706e12386be88e463d642932e0`.

Conclusion: **reject read-ahead as a throughput fix**. No convincing improvement;
agent throughput medians decreased roughly 4–5%, within a variable environment.
The runtime change was removed, not kept on speculative optimization grounds.
Next investigation should profile actual client/agent I/O, short frame sizes,
credit turnarounds and scheduling, or use bounded instrumentation to distinguish
them. These data do not identify a root cause.
