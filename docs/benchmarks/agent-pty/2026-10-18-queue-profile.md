# Agent-side queue and dispatch diagnostics

Follow-up to the [mixed-load experiment](2026-10-18-mixed-8.md).
The mixed step is committed as `d89ec67`; this step adds independently opt-in
diagnostics, **not a scheduling fix or backend switch**.

## Instrumentation

`HOLLOW_AGENT_QUEUE_PROFILE=1` allocates one fixed-size profiler inside the agent.
With the flag absent, no profiler is allocated and no new diagnostic clocks run.
At most 1,024 pending output spans retain timestamps. Overflow drops timings,
never frames; untracked, discarded and still-pending spans are explicitly counted.
No per-frame timing allocations occur.

Positions count successfully queued and successfully written wire bytes, not
indices into the compacted output buffer. This covers partial writes and the
filesystem worker path that appends already-framed responses without `frame()`.
Each entire filesystem reply is one opaque span. Classes separate PTY DATA,
exec DATA, filesystem replies, successful PTY input/resize/close ACKs and other
frames. All streams on a connection are aggregated; there is no foreground tag.

Per-class counters retain queued bytes ahead and enqueue-to-first/complete-write
timings. Dispatch and per-request handler durations are separate from asynchronous
job completion. Poll calls made with a complete command already buffered in agent
memory are counted separately. Fixed 64-bucket histograms are approximate log2
distributions, not exact percentiles. Full semantics, units and censoring rules:
[benchmark methodology](../../architecture/host-agent-benchmarks.md#opt-in-agent-dispatchoutput-queue-diagnostics).

Snapshots are cumulative over startup, priming and prompt warmups. A completed
PTY emits `AGENT_QUEUE_PROFILE` on stderr before its terminal response/error.
Stderr must be drained; serialization/emission can add teardown delay. A connection
closed before any PTY finalization may emit no snapshot. The runner requires
`--telemetry` for stderr inheritance, validates snapshots, and preserves both raw
stderr and parsed records. The older `HOLLOW_AGENT_PROFILE` remains independent.
Protocol stdout, scheduling, queue/admission limits and defaults remain unchanged.

## Controlled local measurements

Three runs with eight shared PTYs, one stalled consumer, bulk off/mixed, 1,000
recorded prompt samples and 10 MiB output: **12 measurements with queue profiling
off, then 12 on**. Host transport telemetry is enabled in both stages. Same
ReleaseFast agent/client binaries and GUI-matched thread-safe DebugAllocator.
No concurrent build/test jobs; machine-wide load/power mode are uncontrolled.
Stage ordering is not randomized, so this is not a tight instrumentation-overhead
bound. These are Linux headless measurements inside WSL2, not native Windows,
legacy WSL-bypass or GUI qualification.

Median per-run p99 and foreground throughput:

| Bulk | Prompt p99, profiler off/on, ms | Output, profiler off/on, MiB/s |
| --- | ---: | ---: |
| Off | 7.095 / 7.868 | 10.59 / 10.52 |
| Mixed | 9.513 / 9.805 | 6.86 / 6.58 |

Profiling is **not free**: these stage medians shift by +0.77/+0.29 ms p99,
and output throughput shifts by about −0.7%/−4.0%. Do not silently substitute
instrumented numbers for diagnostics-off parity data or interpret the differences
as precisely isolated overhead. Every checked consumer and bulk operation makes
progress; the stopped shared consumer remains exactly 65,536 pending bytes.

### Internal observations

The following are maxima across the three **profiled prompt runs**, not p99:

| Observation | Bulk off | Mixed |
| --- | ---: | ---: |
| Wire bytes ahead of an input ACK | 65,624 | 590,710 |
| Input ACK enqueue-to-complete-write, ms | 5.075 | 17.289 |
| Wire bytes ahead of a resize ACK | 65,624 | 590,710 |
| Resize ACK enqueue-to-complete-write, ms | 5.652 | 3.020 |
| PTY DATA enqueue-to-first-write, ms | 5.624 | 16.911 |
| PTY DATA enqueue-to-complete-write, ms | 9.342 | 22.748 |
| Dispatch handler duration, ms | 0.555 | 1.545 |

The ~64 KiB PTY batch cap does not cap exec bursts or opaque filesystem replies.
The increased queued-ahead bytes directly demonstrate **control head-of-line
backlog** under mixed load. Max queued-ahead bytes and max queue residence need
not describe the same message; resize maxima illustrate why backlog size alone
is not a latency measurement.

This does **not** establish that a specific foreground echo waited 17 ms: input
ACK means queued, not child-consumed, and the prompt loop does not wait for each
ACK. PTY DATA includes every background stream. Queue timing also excludes earlier
credit/scheduler wait before enqueue and bytes not yet read from the kernel pipe.
Per-prompt/stream correlation and ready-to-enqueue instrumentation remain missing.

Across all 12 profiled measurements, the pending-record high-water mark is **40**,
with **zero untracked spans** and **zero polls entered with a complete buffered
command**. Snapshots can retain pending background spans; those are censored,
not treated as instant or completed writes. The zero buffered-command count does
not rule out kernel/WSL scheduling or pre-enqueue delays.

**Decision: retain opt-in diagnostics; no scheduling/default change.** Next
experiment should bound bulk issuance at frame boundaries and measure explicit
focus/session priorities or split lanes, while preserving background fairness.
Do not claim ACK prioritization alone solves input-to-echo latency. Shared rollout,
full resource/fault/scale testing and Windows/WSL GUI parity remain blocked.

## Dedicated E1 recheck, diagnostics disabled

Five additional native/dedicated runs, 5,000 recorded prompt samples per run,
10/100 MiB output, both queue profiling and host telemetry disabled:

| Metric | Native median | Dedicated median |
| --- | ---: | ---: |
| Prompt p99, ms | 0.301 | 0.575 |
| 10 MiB output, MiB/s | 71.02 | 73.89 |
| 100 MiB output, MiB/s | 71.30 | 72.91 |

Agent/native median throughput is 104.0%/102.3% in this run, retaining near-native
median evidence rather than proving an optimization. One 10 MiB pair still falls
below 95%: 64.07 versus 73.02 MiB/s. Preserve that slow pair. This is neither a
universal throughput pass nor the plan's required legacy WSL-bypass comparator.

## Evidence and validation

* [Queue profiling off: 12 measurements](2026-10-18-queue-profile-off.jsonl.gz), raw SHA-256
  `a6e91a00f023023a858cd4b78a7af8b878ec6609059319f3db433e88fbd8d502`.
* [Queue profiling on: 12 measurements](2026-10-18-queue-profile-on.jsonl.gz), raw SHA-256
  `0c332c62d007ab70e8f342d3c5d0c811c9349c190f50f304973366d40a220ae2`.
* [Dedicated E1: 30 measurements](2026-10-18-queue-profile-e1.jsonl.gz), raw SHA-256
  `103f30ea66c90fcc8fb290b6e50156c12bb7861298da569e21a07e9b18b93b7e`.
* [Reconstructable measured source patch](2026-10-18-queue-profile.patch.gz), against
  `d89ec67`; all 12 measured-source hashes verified after reconstruction.
* [Per-run summary](2026-10-18-queue-profile-summary.json), including trace maxima,
  coverage and dedicated recheck values. Raw histograms remain in the datasets.
* Measured agent SHA-256:
  `87878eba7991bbd6810932743efbf0f80a16e2cc6606fc59d13d26715a18613c`.
* Unchanged benchmark SHA-256:
  `ded70caa8d596400641740dec834413e34320d653df52c3c7731a25566fca47c`.

Validation: 127 native test executions across standalone targets, including
imported tests; 57 Python harness tests; 16 fs/exec conformance cases with queue
profiling enabled; local adapter/transport regressions with profiling off/on.
Tests cover partial spans, exact frame boundaries, overflow/recovery, discard
censoring, complete versus partial commands, filesystem raw replies and input ACKs.
Target-enabled adapter tests pass through rootless Podman and real WSL interop.
A checked mixed Podman smoke captures valid filesystem/exec/control traces.
Both real pane/terminal integration tests pass. Correctness builds restore the
installed agent to ReleaseSafe after measurement; raw hashes identify the actual
ReleaseFast executables used above.
Static x86_64/aarch64 agent builds pass; ARM64 execution is not claimed. The exact
four-measurement CI diagnostic smoke passes locally; hosted CI is not claimed.

## Reproduce

Use Zig 0.16.0; write to new output names:

```sh
zig build --build-file build-agent.zig agent agent-pty-bench -Doptimize=ReleaseFast
python3 scripts/agent_pty_bench.py --telemetry --backend shared --sessions 8 --load stalled --bulk off mixed --resize-every 16 --runs 3 --samples 1000 --size-mib 10 --output queue-off.jsonl
HOLLOW_AGENT_QUEUE_PROFILE=1 python3 scripts/agent_pty_bench.py --telemetry --backend shared --sessions 8 --load stalled --bulk off mixed --resize-every 16 --runs 3 --samples 1000 --size-mib 10 --output queue-on.jsonl
python3 scripts/agent_pty_bench.py --runs 5 --samples 5000 --size-mib 10 100 --output dedicated-e1.jsonl
zig build --build-file build-agent.zig test-agent-loop test-agent-pty test-host-transport -Doptimize=ReleaseSafe
python3 -m unittest discover -s scripts/tests
```

Ensure both profiling flags are absent for the first/E1 commands. For a prepared
remote connector, supply the queue flag explicitly in target argv/environment;
client environment does not attest remote settings. Remote executable identity
and native Windows/WSL-bypass qualification remain separate gates.
