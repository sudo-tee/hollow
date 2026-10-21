# Windows mux client CPU investigation

Mux remains opt-in. Retained changes separate watchdog notifications and make
frame parsing use the existing 64 KiB read-ahead buffer. Protocol credits,
buffer capacity, writer scheduling, deployment defaults, and the installed
application remain unchanged.

## Current mux versus dedicated PTY head-to-head (October 21, 2026)

**Practical conclusion:** current mux is a solid opt-in option for the measured
four-pane Windows/WSL workload. Throughput and helper-inclusive Windows CPU are
similar, Linux helper memory is substantially lower, and loaded ACK observations
show no consistent responsiveness penalty. Exact equality is not the goal, and
these few runs do not prove statistical equivalence or a universal speedup.

Both arms used the same uninstrumented Windows ReleaseFast executable from the
buffer-first qualification (`59cc049` source) and the same explicit Linux agent
(`dfabad2a65ce6c4d17964d62f8e1768bcee358870a896922be0afe02669759e7`). Only
dedicated/mux mode differed. Four alternating resource pairs measured idle
(10 seconds), capped output (30 seconds, two 5 MiB/s producers), and uncapped
output (30 seconds). Four separate alternating echo pairs used two 5 MiB/s
producers, 1,000 unique ACKs per run, and target-pane switching every 100 ACKs.
All runs used a verified 1280x800 physical client window on DISPLAY1, DPI 120,
outer bounds (-1600,170)-(-320,970), with sampled geometry/focus drift rejection.
Mux used four persistent read workers and two batch jobs.

| Metric, median across qualified runs | Dedicated PTY | Current mux |
| --- | ---: | ---: |
| Linux PTY helper processes for four panes | 4 | 1 |
| Aggregate sampled helper RSS | 3.375 MiB | 0.719 MiB |
| Capped producer-admitted throughput (3 pairs) | 10.00 MiB/s | 10.00 MiB/s |
| Captured Windows-group CPU at capped load (3 pairs) | 1.251 cores | 1.232 cores |
| Hollow-only CPU at capped load (3 pairs) | 1.023 cores | 1.048 cores |
| Linux helper CPU at capped load (3 pairs, separate scope) | 0.388 cores | 0.334 cores |
| Sampled Hollow working-set peak at capped load (3 pairs) | 183.1 MiB | 171.4 MiB |
| Uncapped producer-admitted throughput (4 pairs) | 41.27 MiB/s | 42.08 MiB/s |
| Captured Windows-group CPU while idle (4 pairs) | 0.090 cores | 0.086 cores |
| Loaded ACK observer p50 (4 pairs) | 9.32 ms | 9.05 ms |
| Loaded ACK observer p99 (4 pairs) | 17.55 ms | 15.79 ms |

The RSS saving is 78.7% for Linux PTY helpers, not whole-application memory.
The captured Windows group includes Hollow and recorded Windows descendants,
not shared WSL/VM services or Linux processes. Windows and Linux CPU/RSS must
not be summed as a machine total. A core value of 1.0 means one fully occupied
logical CPU on average, not 100% of the entire machine.

Paired results retain normal variation rather than demanding exact equality:

- Capped Windows-group CPU changed -2.76%, -2.31%, and +7.12% for mux: median
  paired change -2.31%. Hollow-only median paired change was +1.70%; Linux
  helper CPU median paired change was -14.71%, with one +41.44% pair. The ratios
  of group medians in the table are different summaries, not paired effects.
- Uncapped throughput changed -16.80%, +3.88%, +0.98%, and +0.06%: median paired
  change +0.52%. Keep the slower first mux pair visible; this is a mixed result,
  not proof mux is faster. Throughput is producer-admitted bytes, not rendered
  pixels or an isolated transport maximum. Uncapped CPU has unequal throughput.
- Echo p50 paired shifts were -0.271, -2.115, +0.307, and -0.010 ms; median
  -0.140 ms. Echo p99 shifts were -2.001, -13.795, -0.273, and -0.322 ms;
  median -1.162 ms. All four p99 pairs favored mux, but one unusually slow PTY
  pair contributes strongly to that spread. Maximum latency shifts were +5.463,
  -0.356, +2.268, and +2.298 ms; median +2.283 ms. Occasional mux maxima were
  higher despite lower p99. This is GUI IPC/PowerShell ACK observation, not
  physical keyboard-to-display latency; 8,000 ACKs are not 8,000 independent runs.
- Idle Windows CPU varied widely (paired changes -62.38% to +13.34%). Mux Linux
  helper idle CPU had a median ~0.004 cores versus dedicated's counter-resolution
  zero. Ten-second idle phases are not a power-efficiency or long-term leak test.

Qualification: all 16 isolated resource/echo sessions verified tracked Linux
process cleanup. All four idle and uncapped pairs and all four echo pairs passed.
The first capped PTY run admitted 9.843 MiB/s, outside the analysis's 10 MiB/s
±1% matched-load tolerance; the entire capped phase pair is excluded, leaving
three capped pairs. That rate shortfall remains recorded, not treated as a
missing run or a product crash. Overall report is therefore **PARTIAL with an
explicit capped-pair exclusion**, not an unconditional all-attempts PASS.

An external generated echo wrapper initially had a syntax error before launching
any echo session. Correcting the wrapper allowed all four echo pairs to complete;
resource captures were not repeated. Original execution status and correction
are preserved in `execution.json` and `echo-recovery.json`.

No application source change, full test-suite rerun, installed-app update, or
default change was needed. Previous parser tests/build qualification still
applies. These measurements support using mux as an option and continuing toward
session persistence; detach/reconnect, agent lifetime independent of GUI, crash
recovery, cross-connector behavior, and long-duration reliability still require
their own design and validation. Persistence is not implemented by this work.

Artifacts: `/tmp/opencode/hollow-current-head-to-head-20261021/analysis.json`,
raw `resources/` and `echo/` captures, `provenance.json`, and recovery audit.
Runner and read-only analyzer are
`/tmp/opencode/hollow-current-head-to-head.py` and
`/tmp/opencode/hollow-current-head-to-head-summary.py`.

## Historical overview before the current head-to-head

This section preserves the earlier saved-data overview; the new head-to-head
above supersedes its lack of a current direct comparison. The historical
dedicated/mux comparison predates the Windows watchdog/read-ahead fixes; the
latest read-ahead qualification compares new mux against watchdog-only mux,
not against dedicated PTYs. Do not combine percentage changes across different
window geometries to manufacture an updated head-to-head result.

| Historical direct comparison | Dedicated PTY | Mux | Interpretation |
| --- | ---: | ---: | --- |
| Linux PTY helper processes for four panes | 4 | 1 | Mux shares one connector/helper. |
| Sampled aggregate helper RSS | 3.375 MiB | 0.719 MiB | About 79% less helper RSS, not whole-app memory. |
| Capped producer-admitted throughput | 10.0 MiB/s | 10.0 MiB/s | Both sustain offered load. |
| Uncapped producer-admitted throughput, group median | 68.6 MiB/s | 65.4 MiB/s | Wide, mixed paired outcomes; no stable throughput winner established. |
| Linux helper CPU at capped load, group median | 0.172 cores | 0.202 cores | Historical mux helper CPU was higher; not updated by current client-only qualification. |

The earlier untraced helper-inclusive direct Windows comparison, before buffer-first
parsing, measured 0.89254 dedicated versus 0.91174 mux cores by group medians.
Its two paired differences were +15.97% and -8.84%, so the +2.15% ratio of
medians did not establish parity or a precise residual penalty.

The new read-ahead fix has independently reproduced reductions versus
watchdog-only mux: -34.82% transport CPU, -5.91% Hollow process CPU, -6.59%
captured Windows-group CPU (median paired changes), and 64.92% fewer read
operations/MiB in a separate diagnostic. Three loaded-echo pairs were mixed,
with median paired observer shifts +0.423 ms p50 and +1.458 ms p99; latency
equivalence is unproven. At that stage, updated mux-versus-dedicated throughput,
CPU and latency rankings could not be inferred without the new matched run above.

Bottom line: mux has demonstrated process/helper-memory savings and now lower
Windows overhead than earlier mux. Dedicated PTYs remain the conservative
default; no blanket performance win or default change follows from these data.
Historical source: `/tmp/opencode/hollow-gui-dedicated-mux-fixed-20261020-v2/analysis.json`.

## Watchdog notification separation

The mux writer and watchdog previously waited on the same condition. Every
received output frame and UI consumption notification woke both threads, even
though normal output traffic does not change a watchdog deadline.

The watchdog now has a separate condition. Registration, pane close, shutdown,
connection completion, and hello/exit/error frames wake it. Its existing 50 ms
timeout still checks bootstrap deadlines, stalled writes, and overdue closes.
All writer notifications remain unchanged, including every output frame.

A prior experiment batching writer notifications at credit boundaries was
discarded. It is not part of this change.

## Measurements (October 20, 2026)

Fresh Windows ReleaseFast GUIs used the same explicit Linux agent, four panes,
and two output producers capped at 5 MiB/s each. Windows thread CPU counters and
symbolized thread entry points locate work by thread, not by sampled instruction
or call stack. Linux and Windows CPU scopes must not be added together.

### CPU

Four alternating dedicated/mux/candidate triplets used 20-second measurements
and identical reported window geometry, 1536 by 912. All phases passed load,
window, and cleanup validation.

| Median Windows CPU (cores) | Dedicated | Mux before | Mux after |
| --- | ---: | ---: | ---: |
| Whole process | 0.74954 | 0.81170 | 0.76800 |
| Main thread | 0.60104 | 0.61304 | 0.58683 |
| Transport workers | 0.05442 | 0.11263 | 0.07401 |

These rows cover `hollow-native.exe` only: "whole process" means that single
process, not its Windows helpers or the whole machine. See the process-group
audit below for the broader Windows comparison.

Transport-worker CPU fell in every pair, with group medians down 34.3%.
Whole-process changes were -9.30%, -3.40%, -5.10%, and +2.27%: median paired
change -4.25%. The ratio of whole-process group medians instead shows -5.38%;
these are different summaries. Main-thread and graphics-driver variation affect
process totals. Watchdog CPU fell below the counters' measured resolution, not
literally to zero work. Remaining transport cost is primarily in the reader.

### Latency and observer noise

Two alternating identical-binary A/A pairs and four alternating baseline versus
candidate A/B pairs used the same geometry and load, with 1,000 unique ACKs per
run. Executable hashes, geometry, producer rates, and cleanup were validated.
One A/A run averaged 4.985 MiB/s per producer, within the existing 0.05 MiB/s
tolerance; it was retained.

| Run-pair percentile difference | p50 | p95 | p99 |
| --- | ---: | ---: | ---: |
| Median A/B paired change (ms) | +0.0325 | +0.0771 | -0.0154 |
| A/A pair 1 (ms) | -0.300 | -0.335 | -1.152 |
| A/A pair 2 (ms) | -1.444 | -3.823 | -10.844 |

Two A/B pairs favored each executable. One candidate run had a +4.54 ms p99
shift, so tail variation must not be hidden by the near-zero median paired
change. These values measure GUI IPC/PowerShell ACK observation, not physical
keyboard-to-display latency. Thousands of ACKs are not thousands of independent
experimental runs. The controls expose substantial variation, but two A/A pairs
do not establish a reliable noise bound or prove latency equivalence.

The evidence supports retaining this narrowly scoped optimization, not claiming
full mux/dedicated parity or changing defaults. Earlier runs at a different
window geometry must not be pooled with this follow-up.

## Validation and artifacts

```sh
zig build --build-file build-agent.zig test-agent-pty test-agent-pane-bench \
  -Doptimize=Debug -j1 --prefix /tmp/opencode/hollow-watch-commit-tests --summary all
```

The client suite passed 36 tests, including watchdog frame classification and
bounded bootstrap, close, shared shutdown, and backpressure checks. Two Python
pane-benchmark smoke tests passed. ReleaseFast client tests and a Windows
ReleaseFast build with PDBs also passed during qualification.

Local investigation artifacts (not portable benchmark fixtures):

- `/tmp/opencode/hollow-win-watch-cpu-recheck-20261020/analysis.json`
- `/tmp/opencode/hollow-win-watch-aa-20261020/analysis.json`
- `/tmp/opencode/hollow-win-watch-ab-20261020/analysis.json`
- `/tmp/opencode/hollow-win-watch-noise-analysis.json`

Next work: distinguish reader copying, locking, and notification costs using
sampled call stacks or controlled diagnostic instrumentation before choosing
another scheduling change.

## Reader follow-up

A temporary diagnostic binary sampled every sixteenth output admission in two
30-second capped-load runs. Both passed load and cleanup validation. Connection
lifetime counters include setup and drain beyond the measurement checkpoints.
The diagnostic binary is not installed; its instrumentation was removed from
production source after compilation and saved in
`/tmp/opencode/hollow-reader-diagnostics.patch`.

| Sampled mean elapsed time per output frame | Run 1 | Run 2 |
| --- | ---: | ---: |
| Connection mutex acquisition | 0.187 us | 0.265 us |
| Session mutex acquisition | 0.045 us | 0.049 us |
| Output admission | 0.428 us | 0.447 us |
| Pane wake | 0.183 us | 0.173 us |
| Writer broadcast | 3.449 us | 2.829 us |
| Entire `accept()` | 4.613 us | 4.068 us |

These are instrumented elapsed-time samples, including preemption and clock
overhead, not CPU attribution. Transport reads and frame decoding are excluded.
Periodic sampling may also bias frame selection. No prefix compaction occurred;
only 22 and 18 append-buffer growth events occurred across roughly 354 MiB per
run. Mean output frames were 2555 and 2262 bytes. The writer had a registered
waiter on 97.4% and 95.9% of output notifications.

This motivates testing notification coalescing across complete frames already
buffered by the reader. Unlike the discarded credit-boundary experiment, it
must flush before a read that could block, on control frames, and at bounded
frame/byte limits; it must never wait for more data to form a batch. Uninstrumented
CPU and loaded echo measurements must qualify it separately against the committed
watchdog-only baseline before retaining another change.

Diagnostics:
`/tmp/opencode/hollow-win-reader-diagnostics-20261020/reader-analysis.json`.

### Already-buffered notification experiment: not retained

The follow-up candidate deferred writer notifications only when another complete
frame was already buffered. It flushed at control frames, before reads that
could block, or after 16 frames/64 KiB. Debug validation passed 37 client tests
and two pane-benchmark tests; the Windows ReleaseFast build passed.

Four alternating uninstrumented CPU pairs compared it to the committed
watchdog-only baseline at matched 10 MiB/s load and 1536-by-912 geometry. All
eight CPU phases passed validation. Whole-process changes were -1.41%, +11.97%,
+17.18%, and +2.61% (median paired change +7.29%). Transport-worker changes were
+4.52%, -12.96%, +11.21%, and -6.45%: two better, two worse. Group medians were
0.80930 -> 0.82430 process cores and 0.09531 -> 0.09122 transport-worker cores.
The latter small aggregate decrease does not establish a repeatable win, and
main-thread variation prevents attributing the process regressions specifically
to notification code.

The loaded echo comparison did not complete: its first baseline run finished,
but the candidate launcher constructed a nonexistent executable path and failed
before starting the candidate. This was a harness bug, not a candidate crash or
latency result. The temporary harness was corrected to accept explicit executable
paths and check their existence, but no rerun was justified by the inconclusive
CPU result. Do not infer a latency outcome from that incomplete pair.

The experiment was removed from source. Commit `24f83ae` remains the retained
watchdog optimization; no additional writer scheduling change is retained.
Temporary instrumentation, binaries and raw artifacts remain under
`/tmp/opencode/` for further investigation:

- `hollow-buffered-notify.patch`
- `hollow-buffered-notify-cpu-20261020/analysis.json`
- `hollow-buffered-notify-echo-20261020/` (incomplete)

Further optimization needs a more direct CPU attribution or measured reduction
in actual notification work, rather than assuming lower elapsed time or fewer
potential notifications guarantees lower process CPU.

## Windows helper CPU accounting

The saved sampler captured Windows descendants, including `wsl.exe`,
`conhost.exe`, and `wslhost.exe`, but the original summaries and quoted CPU
improvements used only `hollow-native.exe`. Describing those numbers as
"whole-app" CPU was too broad. A fairer bounded Windows comparison includes
the captured process group as well as showing GUI-only CPU separately.

Reanalysis of the four-triplet watchdog qualification produces:

| Median Windows CPU (cores) | Dedicated | Mux before watchdog change | Mux after watchdog change |
| --- | ---: | ---: | ---: |
| Hollow process only | 0.74954 | 0.81170 | 0.76800 |
| Hollow plus recorded Windows helpers | 0.84543 | 0.90706 | 0.86021 |

The fixed mux is 1.75% above dedicated by the ratio of group medians. This does
not establish parity: individual fixed-mux/dedicated paired changes range from
-2.57% to +12.52%. Against pre-fix mux, the watchdog optimization's median paired
process-group change is -3.11%, versus -4.25% for Hollow alone. Most helper CPU
in these runs is in `wsl.exe`; `conhost.exe` and `wslhost.exe` generally show
zero sampled deltas at the counters' resolution, not guaranteed zero work.

For the original earlier four-pair comparison at its original geometry, group
medians were 1.10261 cores dedicated and 1.23097 mux; pair changes were +15.37%,
+14.63%, +5.41%, and +5.79%. Thus adding captured helpers does not reverse that
older result. Do not pool the old and new geometry or infer a machine-wide CPU
total from either comparison.

### Attribution audit and limitations

The old discovery code followed parent PIDs without comparing parent/child
creation times. Windows retains historical parent IDs, which can match a new
unrelated process after PID recycling. Three AMD processes in one qualification
run predated its GUI and were therefore impossible descendants; they were
excluded and listed in the audit output. Their sampled CPU deltas were zero,
so their removal did not affect that run's CPU total.

Historical records lack parent creation times. PID/start identities and stable
snapshot membership are checked, but the old ancestry edges cannot all be
proven retrospectively. The temporary sampler now checks parent/child creation
order, verifies discovery/capture identity, and records parent birth times.
This hardening passed PowerShell parsing and a read-only live topology check;
it does not retroactively make old discovery exhaustive.

The group calculation sums per-process CPU deltas between common endpoint
sample indices, divided by the GUI's actual measured interval. Process reads
are sequential, not simultaneous; maximum snapshot skew in the four-triplet
audit was about 495 ms. Missing already-recorded processes, changing PID/start identities,
decreasing counters, and incomplete sampling are rejected rather than counted
as zero. Short-lived processes between samples may still be missed.

Shared services such as WSL service/VM processes are not necessarily GUI
descendants and remain outside this total. It is a recorded Windows process
group, not an exhaustive WSL or system-wide total. Linux guest CPU is still
reported separately, never added to Windows CPU as if scopes were disjoint.

Reproduce the saved-data audit (does not launch a GUI):

```sh
python3 scripts/test_windows_process_group.py -v
python3 scripts/summarize_windows_process_group.py \
  /tmp/opencode/hollow-win-watch-cpu-recheck-20261020
```

The analyzer also works on the original
`/tmp/opencode/hollow-gui-dedicated-mux-fixed-20261020-v2` artifacts. It writes
`capped-windows-process-group.json` alongside, without replacing the original
analysis. Its validation covers saved Windows counters; original workload,
window and cleanup qualification must be checked separately.

### Fresh parent-identity-checked comparison

Two new alternating 30-second pairs compared dedicated mode against the retained
watchdog-only mux binary. All four workload/window/cleanup phases and saved
process-group audits passed. Every recorded parent PID and creation-time chain
reached the benchmark GUI; no pre-GUI processes needed exclusion. Geometry
remained 1536 by 912. Maximum snapshot skew was about 397 ms.

| Median Windows CPU (cores) | Dedicated | Fixed mux |
| --- | ---: | ---: |
| Hollow alone | 0.78881 | 0.80829 |
| Captured `wsl.exe` helpers | 0.10373 | 0.10345 |
| Hollow plus captured Windows helpers | 0.89254 | 0.91174 |

Captured `conhost.exe` and `wslhost.exe` deltas were zero at the sampled
resolution. The ratio of group medians is +2.15%, but paired process-group
changes were +15.97% and -8.84%. These noisy, short comparisons do not establish
parity or a precise residual CPU penalty. Transport-worker medians remain higher
for mux (0.09133 versus 0.05417 cores), which is a stronger basis for targeted
profiling than the small difference of process-group medians.

Artifacts: `/tmp/opencode/hollow-win-group-audit-20261020/analysis.json` and
`capped-windows-process-group.json` in that directory. The analyzer's eleven
synthetic tests cover helper inclusion, old processes, PID reuse, missing
processes, counter failures, unknown helpers, and recorded parent identities.

## Reader CPU-cycle follow-up

Since elapsed timing includes preemption and waits, a second temporary Windows
binary used `QueryThreadCycleTime` on the reader's current-thread pseudo-handle.
It sampled every 64th output frame and calibrated 1,000 empty query pairs per
reader startup. Both 30-second runs passed workload/window/cleanup validation
and creation-time-aware Windows process-group audits. No cycle query failed.

| Mean raw cycles per sampled output admission | Run 1 | Run 2 |
| --- | ---: | ---: |
| Empty query pair (startup calibration) | 860 | 861 |
| Connection mutex acquisition | 2065 | 2078 |
| Session mutex acquisition | 1098 | 1122 |
| Output admission | 2555 | 2459 |
| Pane wake | 2204 | 2016 |
| Writer notification | 12118 | 10780 |
| Entire `accept()` | 25249 | 23807 |

The writer-notification cost is substantial CPU work, not only elapsed blocking
or preemption. However, probe overhead is included, small stages approach the
probe floor, and entire-function totals include internal probes. Do not interpret
these rows as exact CPU percentages, convert cycles to nanoseconds, or compare
instrumented process totals to the uninstrumented qualification. Microsoft
explicitly warns against converting this API's CPU-dependent cycles to elapsed
time. Transport reads and header decoding remain outside this profile.

Instrumentation was saved externally in
`/tmp/opencode/hollow-reader-cycles.patch` and removed from production source
after building. Results are in
`/tmp/opencode/hollow-win-reader-cycles-20261020/reader-cycle-analysis.json`.

The next uninstrumented pilot changes only notification/lock release order:
publish the frame state under the connection mutex, unlock, then notify the
writer. The worker retains the connection until joining the reader, so the
notification cannot outlive that connection. There is no batching, credit,
buffer, or protocol change. Existing Debug client validation passed 36 tests.
The pilot continuation gate is two lower transport-CPU pairs, at least 5%
median transport reduction, and at least one lower captured Windows-group CPU
pair. Only then run loaded echo qualification; otherwise withdraw the candidate.
This is an exploratory gate, not statistical confidence or default rollout.

The initial unlock-before-notify pilot passed that continuation gate. Relative
to the committed watchdog-only baseline, transport-worker CPU changed -5.16%
and -7.33%, and captured Windows-group CPU changed -0.56% and -10.94%. Group
medians were 0.91122 -> 0.85820 cores, but whole-process and driver variation
make the exact group reduction uncertain. All four CPU phases and both
parent-identity-aware group audits passed.

Two alternating loaded echo pairs also passed 1,000 unique ACKs per run,
matched flood rates, and cleanup. Candidate-minus-baseline shifts were:

| Echo observer percentile | Pair 1 | Pair 2 |
| --- | ---: | ---: |
| p50 (ms) | +0.3734 | +0.5010 |
| p95 (ms) | +0.4691 | -0.2709 |
| p99 (ms) | +1.6230 | -0.3804 |

The median observer shift is small, but both p50 shifts were positive. Neither
a proven regression nor latency equivalence follows from these two runs or the
earlier A/A controls. Independent confirmation completed as two more CPU pairs
and two more echo pairs, reported separately from the selected pilot. The
installed application is unchanged.

Artifacts are under `/tmp/opencode/hollow-unlock-notify-cpu-20261020/` and
`hollow-unlock-notify-echo-20261020/`; confirmation directories add `-confirm`
before `-cpu` or `-echo`.

### Unlock-before-notify confirmation: not retained

All confirmation phases, parent-identity-aware group audits, and echo validation
passed. One echo producer averaged 4.9855 MiB/s in the last candidate run, within
the existing 0.05 MiB/s tolerance; it was retained, not silently excluded.

Confirmation transport CPU changed **+7.05% and +5.71%**, reversing the pilot's
reductions. Captured Windows-group CPU changed -2.60% and +10.42%. Across pilot
and confirmation, median paired transport change is +0.28%, essentially no
repeatable improvement. Median paired group change is -1.58%, but the selected
pilot and large run variation do not establish a robust whole-group saving.

Confirmation echo shifts were p50 +0.3687/+0.3369 ms, p95 +0.4163/+3.1215 ms,
and p99 +1.1929/+9.2011 ms. Across all four pairs, median paired shifts were
p50 +0.3711 ms and p99 +1.4080 ms. All p50 shifts were positive; the final p99
outlier must not be hidden. These are still IPC observer timings, not physical
typing/display latency, and do not by themselves establish causation.

The lock-release-order experiment was removed from source because the independent
CPU benefit did not reproduce, not merely because a small latency difference was
observed. `24f83ae` remains the retained watchdog optimization. The two-line
experimental patch is saved at `/tmp/opencode/hollow-unlock-notify.patch`, and
the pilot/confirmation summary is `/tmp/opencode/hollow-unlock-notify-analysis.json`.
Further scheduling changes need stronger CPU attribution or reproducible
notification-count reduction; kernel sampled-stack profiling still requires
elevated Windows access unavailable to this session.

## Elevated Windows stack capture (October 21)

The user supplied an Administrator PowerShell window for a fixed WPR capture
script; the benchmark and analysis remained unelevated. A dedicated/mux pair
using the retained watchdog binary passed the existing workload, window,
cleanup, and parent-identity-aware process-group checks. WPR saved its ETL
successfully, and Microsoft's TraceEvent 3.2.8 parsed it with zero lost events.
The full capture had 117,477 Hollow samples, of which 113,943 had stacks; this
includes unrelated Hollow processes and startup and is not the analysis scope.

Filtering to the two benchmark GUI PIDs and their saved steady-load sample UTC
windows leaves 32,401 dedicated samples (32,353 stacked) and 36,117 mux samples
(36,068 stacked). Native symbols were resolved from matching local PDBs and
Microsoft's symbol server. Main-thread sample counts were similar (23,854 vs
24,086). The mux reader had 5,012 samples and the writer/worker 2,297; stacks
show pipe-read/alertable-wait paths and futex wake/wait paths, respectively.
Inclusive stack counts overlap and do not represent blocked wall time.

However, the built-in CPU profile also records context-switch/ready-thread
stacks. Its own `EtwpTraceStackWalk` appears in 1,939/5,012 reader samples and
1,289/2,297 writer samples. This is substantial observer overhead, not ordinary
Hollow work. Do not infer untraced CPU percentages or select an optimization
from these proportions. The next capture uses a WPR-validated custom profile
containing only ProcessThread, Loader, SampledProfile, and SampledProfile stacks,
with no context-switch or ready-thread stack collection.

Artifacts: `/tmp/opencode/hollow-win-wpr-pair-20261021/stack-summary.json`,
`symbol-resolution.log`, and `symbolized-stacks.jsonl`; ETL is local to Windows
under `%LOCALAPPDATA%\HollowProfiles\mux-cpu-20261021\dedicated-and-mux.etl`.
Trace contents remain local; only Microsoft symbols and NuGet packages were
downloaded. No application code or defaults changed for this diagnostic.

### Sampled-only capture: comparison rejected

The lighter capture saved successfully, but the original strict analysis rejected
the mux phase: its GUI was foreground in 20 of 38 snapshots. Window auditing
also found different actual rectangles: dedicated stayed at (-1920,0)-(0,976),
while mux stayed at (78,78)-(1534,1017). Launcher metadata records intended
placement, not proof of actual placement; the sampled window records take
precedence. No dedicated/mux CPU comparison is valid for this pair.

The automatic analysis initially stopped before ETL parsing because validation
was fail-fast. A separate diagnostic path now records `validation: FAIL`, retains
the strict failure, and permits stack extraction without manufacturing a passing
comparative result. Successful process exit and successful ETL save are not
equivalent to full experiment qualification. The earlier progress update that
both phases "passed" was premature for this second capture.

Diagnostic artifacts are under
`/tmp/opencode/hollow-win-wpr-sampled-pair-20261021/`; `window-audit.json`
records the discrepancy and `analysis.stdout` retains the strict failure.

Diagnostic extraction completed with zero lost events. Across the full trace,
93,727 Hollow samples included 93,513 with stacks. Within the mux benchmark's
saved steady-load window, its reader had 3,039 samples (3,030 stacked):
2,429 included `readVec`, 2,368 included `operate`, and 417 included
`futexWake`. There were no reader stacks containing `EtwpTraceStackWalk`.
These overlapping inclusive counts suggest the Windows transport-read/completion
path deserves investigation before another notification-only scheduling change;
they are not exclusive CPU costs or a valid comparative result.

The installed Zig 0.16.0 source explains the observed `NtReadFile` /
`NtDelayExecution` stacks: its nonblocking Windows streaming read submits
`NtReadFile` with an APC callback and enters alertable waits until completion.
The mux client calls that path via the 64 KiB buffered `readerStreaming` in
`src/pty/agent_mux.zig`. Seeing CPU samples in this path does not count the
entire blocked interval as CPU, prove busy polling, or justify bypassing
cancelation/lifetime requirements. A next diagnostic should measure read-call
counts, returned byte distributions, and completion/wakeup costs before choosing
an alternative implementation. No further application change was made.

## Repeatable Windows benchmark geometry

Ordinary startup size can be set through existing Lua configuration:

```lua
hollow.config.set({ window_width = 1280, window_height = 800 })
```

These startup dimensions alone are not a physical-pixel benchmark guarantee.
The old temporary launcher called `SetWindowPos` once, did not wait for a real
main HWND or check the call's result, and recorded requested monitor bounds
instead of measured window geometry. PowerShell DPI virtualization also made
monitor/size requests unreliable as physical-pixel evidence.

`scripts/windows_bench_window.ps1` provides a shared launch/sampling helper.
It enters per-monitor-v2 DPI awareness, waits for the selected process's main
window, fits an explicit physical client size on an explicitly named monitor,
checks positioning success, and requires one second of stable measured bounds.
It uses `SWP_NOACTIVATE | SWP_NOZORDER` and, if needed, attempts to restore the
previous foreground window; inability to establish background state fails the
launch. It does not install hooks, prevent user resizing, or repeatedly force
placement during a measurement. Sampling rejects foreground/minimized/maximized
state or any client/outer geometry, monitor, or DPI drift.

The temporary launcher/config/sampler now use this helper, fixed 1280x800
physical client dimensions, and explicit `\\.\DISPLAY1`. A short dedicated/mux
smoke run verified identical measured geometry in all 6/7 saved snapshots:
outer rectangle (-1600,170)-(-320,970), client 1280x800, DPI 120, and background
state. Both cleanups passed. These are geometry checks, not CPU qualification;
do not pool this new client geometry with earlier runs. Artifacts:
`/tmp/opencode/hollow-window-fixed-smoke-20261021/`.

Synthetic invariant checks (no live window modifications):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/test_windows_bench_window.ps1
```

## Read-call counter diagnostic

A temporary binary wraps only the mux reader's `Io.operate` streaming-read calls.
It forwards to the unchanged underlying I/O backend with the original userdata;
the 64 KiB reader buffer, protocol, credits, notifications, and APC completion
implementation are unchanged. Counters record requested first-buffer capacity,
returned byte-size buckets, bytes, read calls, decoded/output frames, EOF and
errors. Every 128th read samples reader-thread CPU cycles around the underlying
operation, with 1,000 empty query-pair startup calibrations. This is a read-operation
CPU-cost diagnostic, not a direct kernel syscall count, APC pending/completion
counter, latency test, or uninstrumented CPU qualification.

The diagnostic Windows ReleaseFast build and full 36-test Debug client graph
passed. The source instrumentation was saved as
`/tmp/opencode/hollow-read-calls.patch` and removed after building; production PTY
source was restored to the retained watchdog change before the next pilot. Two
fixed-geometry 30-second runs passed workload/window/cleanup and process-group
checks under `/tmp/opencode/hollow-win-read-calls-20261021/`.

| Connection-lifetime counters | Run 1 | Run 2 |
| --- | ---: | ---: |
| Successful streaming reads | 698789 | 720160 |
| Output frames | 349226 | 360009 |
| Mean bytes/read | 546.6 | 534.9 |
| Reads/MiB | 1918.4 | 1960.2 |
| First-buffer requests in 16–64 KiB bucket | 0 | 0 |

Both runs had no read errors, one final EOF, and no cycle-query failures. Roughly
half the reads requested at most 64 bytes, consistent with a separate nine-byte
frame-header read; there were approximately two reads per output frame despite
the configured 64 KiB read-ahead buffer. Raw sampled read costs were about
22–23k cycles for <=64-byte returns and 21k for 1–4 KiB returns, against
806–879-cycle empty query pairs. Periodic 1/128 sampling may alias frame
patterns, so these bucket means are descriptive, not an exact whole-reader CPU
breakdown. Counters cover setup/shutdown too, not only the 30-second phase.

Source explains the lost read-ahead: `readSliceAll()` asks the file reader for
its direct destination followed by spare internal-buffer space, whereas Zig's
Windows `fileReadStreamingWindows()` reads only the first nonempty slice.
Thus the nine-byte header and small payload reads bypass the intended buffer.

### Buffer-first parsing pilot

The uncommitted pilot reads frames through `takeArray(header_len)` and
`take(payload_len)`, forcing fills into the existing 64 KiB reader buffer. It
validates header kind/length before requesting payload, borrows payload only
until synchronous `accept()` copies retained data, and leaves protocol, credits,
writer/watchdog notifications, and Windows completion behavior unchanged.
There is no timer or wait to fill a batch: only enough data for the current
header/payload is required. Maximum control payload remains 64 KiB.

Four regression tests model a first-slice-only backend, verify two frames arrive
from one buffer fill, exercise bytewise/short reads and truncation, reject bad
kinds/oversized headers before another payload read, and handle a full control
payload across buffer rebase. The Debug and ReleaseFast client graphs passed
40 tests each, both Python pane-benchmark tests passed, and the Windows
ReleaseFast build passed. Two uninstrumented fixed-geometry CPU pairs are being
collected before deciding whether to continue with loaded echo qualification.

The first two uninstrumented fixed-geometry pairs passed full qualification:

| Candidate change versus watchdog-only mux | Pilot pair 1 | Pilot pair 2 |
| --- | ---: | ---: |
| Transport-worker CPU | -43.46% | -28.83% |
| Hollow process CPU | -6.99% | -4.93% |
| Captured Windows process-group CPU | -10.36% | -3.46% |

The main GUI thread changed +0.46%/-0.85%, and the reader reduction accounts for
most transport improvement; writer CPU did not show a comparable reduction.
These are promising pilot results, not a retained optimization or comparison
against dedicated PTYs. Independent confirmation is two further alternating
CPU pairs and four alternating loaded-echo pairs. Echo observation now records
and checks physical geometry periodically outside each timed send/ACK interval;
geometry checks themselves can change observer pacing, so compare only the new
matched observer runs to each other.

Pilot artifacts: `/tmp/opencode/hollow-buffer-first-cpu-20261021/`. The
candidate patch is saved at `/tmp/opencode/hollow-buffer-first.patch`.

The first confirmation batch was interrupted when the second pair's baseline
window changed minimized/maximized/foreground state during measurement. The
sampler failed closed and both runs of that pair are excluded, including the
candidate run that completed. All isolated-session cleanups verified process
exit. Original artifacts remain under
`/tmp/opencode/hollow-buffer-first-confirm-cpu-20261021/`, with an explicit
`qualification-audit.json`. The first complete pair is kept separately as
supplementary evidence under `hollow-buffer-first-confirm-supplemental-20261021`.
One fresh two-pair confirmation batch was attempted at
`hollow-buffer-first-confirm-cpu-v2-20261021`; there is no unbounded retry policy.
The interrupted batch did not reach echo qualification.

### Buffer-first confirmation and echo results

Both fresh confirmation pairs passed strict workload, physical-window,
process-group and cleanup qualification. Transport CPU changed -28.53% and
-40.81%; Hollow process CPU changed -5.62%/-6.21%; captured Windows-group CPU
changed -4.80%/-8.38%. Across the four primary pilot/confirmation pairs, median
paired changes are -34.82% transport, -5.91% Hollow, and -6.59% captured Windows
group. All four improved. The supplementary first valid confirmation pair also
improved (-33.72% transport, -5.58% Hollow), but is not silently added to the
primary four-pair summary. This remains a mux-versus-watchdog-only-mux comparison,
not proof of parity with dedicated PTYs or grounds for changing defaults.

Three loaded-echo pairs completed 1,000 unique ACKs per run, matched flood rates,
target switching, periodic physical-window checks, and verified cleanup. A fourth
pair failed the candidate's startup window-stability check before launch readiness
or echo measurement; it is excluded and preserved, with no further retry.

| Candidate minus baseline observer shift (ms) | Echo pair 1 | Echo pair 2 | Echo pair 3 | Median paired |
| --- | ---: | ---: | ---: | ---: |
| p50 | +0.8155 | +0.4227 | -0.7288 | +0.4227 |
| p95 | +1.3614 | +0.7824 | -1.1680 | +0.7824 |
| p99 | +1.4575 | +1.7448 | -2.7014 | +1.4575 |
| Maximum | +0.4994 | +1.4050 | -1.0956 | +0.4994 |

Two echo pairs favored baseline, one favored candidate. The CPU benefit
reproduced independently, but these limited, mixed IPC-observer measurements do
not establish latency equivalence, prove the small shifts are noise, or measure
physical keyboard-to-display latency. Raw ACKs are not independent experimental
runs. Report the positive paired p99 shift rather than replacing it with a more
favorable ratio/difference of group medians.

Artifacts: `hollow-buffer-first-confirm-cpu-v2-20261021`, original
`hollow-buffer-first-echo-20261021` including startup failure, and the audited
three-pair view `hollow-buffer-first-valid-echo-20261021`, all under
`/tmp/opencode/`. Combined primary pairs, supplementary evidence, explicit
exclusions and caveats are in `/tmp/opencode/hollow-buffer-first-results.json`.

### Buffer-first read-count verification and retained candidate

A separate counter-only diagnostic build passed the same fixed-window,
workload, and cleanup checks. Over its connection lifetime it made 248,296
streaming-read operations for 382,740,220 bytes and 345,158 decoded frames:
680.25 calls/MiB and 1,541.5 bytes/call. Of its first-buffer requests, 248,294
were in the 16–64 KiB bucket, two were in 4–16 KiB, and none were <=4 KiB.
Against the two baseline diagnostic runs' median 1,939.29 calls/MiB, this is
64.92% fewer read operations per MiB. Calls include the final EOF attempt;
counts are over connection lifetime, not an exact 30-second syscall trace.
Different diagnostic binaries/runs establish the read-count mechanism, not
another instrumented-versus-uninstrumented CPU comparison.

Artifacts: `/tmp/opencode/hollow-buffer-first-counts-20261021/read-count-verification.json`
and captured GUI log. The diagnostic patch and binary hashes are recorded in
`/tmp/opencode/hollow-buffer-first-provenance.json`; all counter instrumentation
was removed from source, and its remaining diff exactly matches the
uninstrumented `hollow-buffer-first.patch` used for CPU/echo qualification.

Retain the buffer-first parser for review: the CPU
reduction reproduced in both independent confirmation pairs and the actual
read-count reduction matches the identified first-slice issue. Do not claim
latency equivalence, dedicated-mode parity, broad platform qualification, or
long-term stability from this experiment. Installed application and dedicated
default remain unchanged. The parser and supporting benchmark tools are committed
at the user's request; no push or merge was performed. Previously reported test
results are reused for that commit; no tests or benchmarks were rerun.
