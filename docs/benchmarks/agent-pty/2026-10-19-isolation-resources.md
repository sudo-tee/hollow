# Foreground isolation: finite resource and transport-fault probes

Base revision: `e410fb0`. Defaults remain unchanged. These probes address costs
left open by [static foreground isolation](2026-10-19-isolated-foreground.md),
not production routing, persistent sessions or a new reconnect policy.

## Linux process-tree observer

`scripts/agent_pty_resources.py` launches an explicit argv and samples its local
`/proc` tree, including children forked by non-main threads. Process identities
are `(pid, start_ticks)`, with pidfds acquired and identity rechecked before
retention. Descendants already observed remain tracked after reparenting. This
does not discover previously unseen descendants after they leave the observed
tree. Remote connector processes are local costs only: remote workloads require
an observer on that target, not interpretation of local RSS as remote memory.

Per sample: elapsed monotonic time, live/zombie process counts, summed RSS,
threads, and sum of maximum observed user+system CPU ticks per retained identity.
Separate per-process observations retain first/last times, CPU maximum, peak
RSS/threads and last state/parent. **Summed RSS double-counts shared pages**; it
is neither physical memory footprint nor PSS. Sampled CPU includes each observed
process's lifetime ticks, not its children's aggregated wait accounting. Final
CPU tails and short-lived processes between samples may be missed. CPU totals
are an observational lower bound, not exhaustive workload CPU accounting.

Reaped-child `getrusage` CPU and maxrss are recorded separately, never added to
sampled CPU. Propagated descendant accounting depends on intermediate reaping;
maxrss is not simultaneous tree RSS. Observer CPU is also separate. All sampler
time, including `/proc` traversal, can perturb the measured process. Sleep is
after sampling, so 50 ms is a requested interval, not exact sample spacing.

Bounds: 4,096 retained identities, 16,384 retained samples, 256 task entries per
process per discovery, interval 10–1,000 ms, command timeout 1–600 s. Capacity
loss/task censoring and disappearing-process read races are explicit. File-backed
stdout/stderr cannot fill undrained pipes; output files are created exclusively,
not overwritten. File sizes are not bounded by this wrapper; only use trusted,
finite probes with adequate disk space. This is not a general resource limiter.

On timeout/interruption or observed survivors after root exit, cleanup signals
only verified owned identities through pidfds; directly owned unreaped root is
also terminated as needed. Such cleanup is recorded, not silently accepted as
successful teardown. No guarantee covers unseen processes, uninterruptible sleep,
OOM, remote process trees or exhaustive post-kill descendant reaping. Fault
containment must still use the existing guardian tests and dedicated probes.

```sh
python3 scripts/agent_pty_resources.py --interval-ms 50 --timeout 120 \
  --output /tmp/opencode/probe-resources.json -- \
  /path/to/hollow-agent-pty-bench '{"backend":"native","workload":"prompt"}'
```

Full benchmark configuration must provide required fields/connector for the
intended workload. The wrapper observes any explicit trusted command, does not
configure target environment flags and does not validate benchmark results.
Use `agent_pty_bench.validate` on captured result JSON separately.

## Finite matched matrix

Same frozen ReleaseFast agent and benchmark as the isolation experiment; no
agent/transport runtime implementation changed. Direct native benchmark launch
avoids Python benchmark runner inside observed tree. Eight PTYs, noisy/stalled,
mixed checked FS/EXEC, 3,000 recorded prompts after warmup or 100 MiB output,
resize every 16, default 512 KiB EXEC, static focus and no diagnostic/host
telemetry flags. Native bulk still runs through its ordinary separate agent.

Five variants: native POSIX, shared/isolated WRR, shared/isolated DRR. Two rotating
orders; monitor-off/on order varies across variants but stays fixed within each
variant across both rounds, **not** exhaustive or fully counterbalanced ordering.
The orchestration manifest's "alternating" description refers to positions, not
within-variant crossover. Order effects remain a confound.
Each command starts fresh processes. Observer interval is 50 ms; all runs serial
without concurrent tests/builds. Off/on timings expose observer perturbation;
on-run resource values cannot be treated as zero-observer-cost production data.
Resource windows cover setup, warmup, timed work and teardown; they are not just
foreground output timing. Shorter isolated prompt runs change both duration and
total completed background/bulk work. This is not equal-work CPU efficiency.

Finite runs are not a sustained-load/soak gate: neither steady-state CPU/RSS
growth nor 40/100/200-PTY scale is qualified. Resource comparisons require
simultaneous aggregate peaks, CPU per observation time and achieved work, not
adding unrelated per-process peaks or declaring lower CPU-seconds alone a win.

## Independent transport-fault checks

`src/agent_pty_test.zig` creates two independent shared owners with focus,
selects their panes, closes either connection asynchronously and waits for its
disconnected state. Dead pane must reject writes. Surviving pane must accept
focus sequence 2, resize, exact echo and checked EXEC, then exit cleanly. Both
directions run under WRR and DRR. Owners outlive panes; normal cleanup remains
unchanged. This exercises native owner isolation, not arbitrary kernel faults.

`scripts/agent_focus_tests.py` independently SIGKILLs the exact local agent
subprocess through pidfd, waits for signal exit and verifies other connection's
focus, resize, exact echo, EXEC and normal PTY exit. Both directions run under
WRR and DRR. READY/output handling accepts legal DATA fragmentation. Existing
guardian containment probes separately cover workload cleanup after agent death;
this new test does not claim to re-prove descendant cleanup or OOM containment.

These are idle, established two-connection failure probes, not loaded recovery
or same-connection survival. No failed pane is rebound, retried or migrated. No
claim covers shared host OOM, remote daemon failure, kernel resource exhaustion,
GUI state/reconnect behavior, automatic split routing or independent failure
domains on a shared target machine.

## Results

**80/80 measurements validate**, with 40 monitored commands and 40 unmonitored
controls. No timeout, cleanup signal, retained-sample/process capacity loss or
task-capacity censoring. Disappearing-process read races are retained, not
interpreted as complete process coverage. Only two observations per cell; all
following values are medians, not robust steady-state estimates.

### Extra concurrent CPU and threads, similar sampled RSS

Monitored prompt-phase whole-command values, noisy / stalled:

| Variant | Sampled average CPU cores | Peak summed RSS, MiB | Peak threads |
| --- | ---: | ---: | ---: |
| Native POSIX | 3.11 / 3.00 | 207.34 / 171.74 | 56 / 56 |
| Shared WRR | 1.60 / 1.60 | 139.51 / 138.62 | 39.5 / 39 |
| Isolated WRR | 2.16 / 2.13 | 140.21 / 141.23 | 44 / 44.5 |
| Shared DRR | 1.61 / 1.62 | 139.41 / 138.96 | 39.5 / 39.5 |
| Isolated DRR | 2.20 / 2.15 | 139.68 / 141.22 | 44 / 44 |

Half threads/processes in medians mean two integer run maxima averaged, not
fractional live threads. Isolation increases sampled average CPU by roughly
**33–37% during prompts**, with about **4.5–5.5 additional peak threads** across
workloads. Output-phase sampled cores rise from **1.44–1.48** to **2.04–2.06**,
roughly **39–43%**. Peak live-process medians are roughly 35–36 shared and 36–37
isolated; sampled transient EXEC activity means observed peaks are not an exact
account of the one extra agent. Per-identity observations remain archived.

Across agent workload cells, median peak summed RSS is **138.62–147.03 MiB
shared** and **139.68–147.91 MiB isolated**. This finite sampler resolves no large
RSS regression here, but is not a PSS/physical-memory bound. Native's
**171.74–224.89 MiB** uses different buffering and achieves different background
and bulk output; it is not an equal-resource or native Windows comparison.

Isolation reduces whole-command sampled CPU-seconds because fixed prompt/output
work finishes faster: prompt observations last roughly **1.68–1.70 s isolated**
versus **9.76–10.72 s shared**. Background/bulk work completed in those windows is
not equal. Lower total CPU-seconds cannot establish equal-work efficiency; higher
average CPU and extra threads are costs that foreground timing alone concealed.

### Observer perturbation remains material

Observer itself consumes about **0.084–0.102 average cores**, outside observed
tree CPU, with actual sample gaps exceeding requested 50 ms. Across 20 prompt
pairs, monitor-on/off p99 ratios range **0.954–1.573**, median **1.052**. Across
20 output pairs, throughput ratios range **0.848–1.043**, median **0.987**.
Pair differences mix observer cost, fixed order and ordinary host variation;
they are not a causal overhead estimate or a number to subtract from latency.

Median-of-two monitor-off echo p99 is **1.42–1.53 ms isolated**, versus
**5.76–6.39 ms shared**. Monitored isolated p99 rises to **1.65–1.93 ms**, with
shared **6.05–6.63 ms**. Monitor-off foreground output is **67.61–69.00 MiB/s
isolated**, versus **25.48–28.33 MiB/s shared**. Foreground isolation remains
promising in this different finite cohort, but raw on/off results both remain
evidence. No new native +5 ms or default E1 qualification is inferred from
resource monitoring or medians.

### Validation and release boundaries

Local validation: **92** ReleaseSafe native loop/adapter/transport executions,
**74** Python unit tests, **seven** focus wire tests under each of WRR/DRR. New
native test covers four close-direction/policy combinations; new real-wire test
covers two SIGKILL directions under each policy. Both suites verify surviving
focus, resize, exact echo and EXEC; they do not implement reconnect. Observer
unit coverage includes stat parsing, PID reuse, monotonic CPU, simultaneous RSS,
explicit capacity loss, real child exit/output, exclusive files, non-main-thread
child discovery and owned-process timeout cleanup. CI runs these through existing
unit/native/focus suites; hosted execution is not claimed. Windows native adapter
cross-compile check passes with the local build-options stub; this is not a full
Windows GUI build or execution qualification.

No production agent/transport source changed. Installed local agent/benchmark
remain ReleaseSafe. Default E1 throughput misses, prior loaded-latency misses,
background/bulk tradeoffs, sustained resources, fault/OOM/soak, real focus
switching, 40/100/200 PTYs and native Windows GUI/legacy WSL bypass remain open.
An idle established connection surviving peer death is not loaded recovery,
same-agent prioritization or host-wide OOM isolation.

### Evidence and decision

`2026-10-19-isolation-resources.json.gz` archives all **80** validated raw
benchmark results, per-process identities, resource samples, observer-off controls,
stdout/stderr, raw-file hashes, exact configuration/order, orchestration and
measured monitor source. Adjacent `.summary.json` includes all 40 on/off pairs,
40 resource-run summaries and per-cell values. Uncompressed archive SHA-256:
`e9dda498424320f6fda0b847450a4b2bcd9cfd133d055d6e4fc31147aba1e4ed`.
Frozen binary identities are unchanged from previous isolation report; monitor
source SHA and frozen agent/benchmark SHA are retained in both manifest/summary.
All **16** benchmark source hashes match their unchanged `e410fb0` versions.
Adjacent `.patch.gz` reconstructs the final observer, observer unit tests,
native-close regression and Python SIGKILL regression on `e410fb0` (CI/docs
changes excluded). Uncompressed patch SHA-256:
`248fa62c3308f11a4b72e464bfa45bb13175faed5f68a7feb8fbd499e0b84250`.
All measurements use local Linux inside WSL, not native Windows GUI execution.

**Decision:** retain explicit pinned-foreground experiment, with concurrent CPU
and thread costs now visible. Do not enable default split routing or call similar
sampled RSS equal-resource parity. Next validation should cover genuinely loaded
focus transitions, sustained per-stream fairness/resources and loaded failure;
global routing/migration policy still requires an independent design decision.
