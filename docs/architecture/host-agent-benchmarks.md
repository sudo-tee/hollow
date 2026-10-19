# Host/agent benchmark baseline

Status: functional harness for the existing `hollow-wsl-bypass` framed helper.
No measured WSL result is checked in. A Linux run exercises the local helper
path only and is not WSL-qualified. This benchmark does not migrate PTY
ownership or implement an agent.

## Build and run

Build the Linux helper with project Zig 0.16.0 (or use an existing compatible
`zig-out/bin/hollow-wsl-bypass`):

```sh
zig build -Dtarget=x86_64-linux-gnu wsl-bypass -Doptimize=ReleaseFast
python3 scripts/agent_bench.py prompt --launcher-json '["zig-out/bin/hollow-wsl-bypass"]' --output results/local-prompt.jsonl
```

Launcher arguments are a JSON argv array, allowing launcher flags without shell
parsing problems. Example WSL invocation:

```sh
python3 scripts/agent_bench.py prompt --launcher-json '["wsl.exe","-d","Ubuntu","--","/tmp/hollow-wsl-bypass"]' --output results/wsl2-prompt.jsonl
```

The default prompt experiment has five independent helper processes, each
performing 5,000 echo samples (`--runs 5 --samples 5000`). Each helper stays
alive for its run. Smoke runs may use `--runs 1 --samples 10`; those are recorded
with `qualification: false`. Full qualification requires at least five runs and
5,000 samples per run. Each sample uses unique token; helper child is started
with `stty raw -echo`, and sentinel triggers clean child exit with status zero.
Linux pipe reads use `select` against deadlines; framing and individual output
are bounded. Dimensions remain fixed at 120x40.

Throughput defaults to a deterministic raw output producer (a `cat`-like
one-direction workload). `--direction echo` selects a separate duplex echo
experiment; do not compare duplex measurements with output-only baselines:

```sh
python3 scripts/agent_bench.py throughput --launcher-json '["zig-out/bin/hollow-wsl-bypass"]' --size-mib 10 --runs 5 --output results/local-10mib.jsonl
python3 scripts/agent_bench.py throughput --launcher-json '["wsl.exe","-d","Ubuntu","--","/tmp/hollow-wsl-bypass"]' --size-mib 100 --runs 5 --output results/wsl2-100mib.jsonl
```

Payload bytes are deterministic and binary; observed bytes and SHA-256 are
verified with bounded client buffers. Each throughput run gets its own helper
and exits naturally (or receives a graceful sentinel in echo mode).
`--timeout` sets protocol deadlines (default 15s); use
a larger value for slower environments or 100 MiB.

## Artifacts and interpretation

JSONL records metadata, exact launcher argv, source SHA-256, locally available
helper executable SHA-256, environment subset, all prompt samples, and per-run
p50/p95/p99 latency summaries. Throughput rows retain byte counts, checksum,
elapsed time, and MiB/s. Preserve raw JSONL. Record Windows build identity, WSL
distro/kernel, CPU/power mode, and other relevant environment details alongside
published measurements; local environment metadata cannot establish WSL
qualification. Never pool WSL1 and WSL2 results.

| ID | Host / path | Workload | Repeat | Purpose |
|---|---|---|---:|---|
| A | Windows → WSL2, legacy bypass | prompt echo, 5,000 samples/run | >=5 | latency baseline |
| B | Windows → WSL2, legacy bypass | 10 MiB raw echo | >=5 | throughput baseline |
| C | Windows → WSL2, legacy bypass | 100 MiB raw echo | >=5 | sustained throughput/backpressure |
| D | Linux local helper subprocess | prompt / raw echo | >=5 | harness sanity only |
| E | Windows → WSL1 if supported | same A–C | >=5 | separate environment |

No synthetic or Linux-local result substitutes for Windows/WSL measurements.
Keep the v4 gates unchanged: idle input-to-echo p99 delta <=2 ms; loaded p99
delta <=5 ms at matched load; warm time-to-first-prompt p95 <=max(1.10 times
legacy p95, legacy p95 +50 ms); 10/100 MiB output throughput >=95% of legacy.
Require bounded memory, zero background starvation, correct DATA-before-EXIT
ordering, GUI frame-time qualification and explicit fault-isolation outcomes.
The 10/25/50-session matrix means 40/100/200 PTYs for the four-pane profile.
The current harness measures only the legacy echo/throughput reference, not
that entire experiment matrix or GUI rendering. No backend switch is justified
by these harness tests alone.

## Dedicated native/agent adapter comparison (E1)

`scripts/agent_pty_bench.py` drives one native Zig client binary against either
the existing Linux native PTY backend or the experimental dedicated agent adapter.
Both execute the same `/bin/sh` workload at 120×40. This is **not** a comparison
against WSL bypass and does not replace the E0/Windows or multiplexing gates above.

```sh
zig build --build-file build-agent.zig agent agent-pty-bench -Doptimize=ReleaseFast
python3 scripts/agent_pty_bench.py --runs 5 --samples 5000 --size-mib 10 100 --output results/agent-pty-local.jsonl
```

Create the destination directory first; output files must not already exist.
Default runs alternate backend order, use a new connection/PTY per independent
run/workload/size, and preserve every raw sample. Startup time runs from spawn
through the checked ready marker, including connector startup for agent cases.
Prompt measurements exclude 32 verified warmup exchanges and measure client
dispatch through receipt of the exact unique line token on one monotonic clock.
The same client loop waits on the backend wake callback, not a periodic read
sleep; a 10 ms heartbeat bounds native exit reaping after the reader's last wake.

Output mode waits for readiness and a `GO` input before producing deterministic
raw zero bytes. Timing includes dispatch through consumption of all requested
bytes, but excludes the subsequent clean-exit wait. The client checks each byte,
records SHA-256 and rejects extra output or a nonzero/missing exit status. This
is output-only throughput, not duplex echo. The harness records no GPU/frame
times, loaded-neighbor fairness, CPU/RSS counters or multiplexing measurements.

JSONL includes source and executable SHA-256, git revision/dirty paths, exact
connector argv, runner command, host metadata, raw latency samples, nearest-rank
p50/p95/p99/max and per-run throughput. It always records `qualification: false`;
repeat counts alone cannot establish WSL/GUI parity. Preserve the original file,
including failure rows, and compare per-run distributions rather than pooling
samples or cherry-picking the fastest run.

The client allocator is explicit: `--allocator debug` (the current default)
matches the GUI's thread-safe DebugAllocator; `--allocator page` reproduces the
original allocator choice and `--allocator smp` permits a separate experiment.
Never compare allocator changes without labeling them. `--telemetry` enables
bounded host counters; `HOLLOW_AGENT_PROFILE=1` separately enables agent stderr
diagnostics, forwarded only with client telemetry enabled. Use
`-Dagent-profile=true` to keep symbols/frame pointers for `perf`, not to enable
runtime instrumentation. Compare diagnostics on/off independently.

For prepared remote agents, pass `--connector-argv '<JSON argv>'` or
`HOLLOW_TEST_CONNECTOR_ARGV`; no discovery, authentication or deployment occurs.
`--backend agent` measures only that path. A paired local-native/remote-agent run
has **different execution paths** and must not be described as same-host backend
parity; remote agent build identity is not attested by the local binary hash.
The native benchmark currently requires Linux. Native Windows GUI, real WSL bypass,
and the 40/100/200-PTY matrix remain separate unexecuted gates.

Executed local five-run datasets and the rejected read-ahead experiment are
preserved in [the dedicated adapter measurement report](../benchmarks/agent-pty/README.md).
The subsequent [throughput investigation](../benchmarks/agent-pty/2026-10-18-throughput-fix.md)
identifies/removes avoidable ready-output poll sleeps and transient DATA/credit
allocations; four additional five-run datasets preserve the controlled evidence.

### Initial shared-connection matrix

The same client/runner additionally supports `--backend all` (native POSIX,
dedicated agent, shared agent), `--sessions 1 4 8 16` and
`--load idle noisy stalled`. Each total includes one checked foreground and
the remaining backgrounds. Results include per-background byte totals and maximum
delivery gaps; background payloads have distinct byte values to detect bad
demultiplexing. The stalled case deliberately never consumes one background.

See the [initial shared PTY report](../benchmarks/agent-pty/2026-10-18-shared-pty.md)
for workload limits, owner scheduling, buffer differences and remaining gates.
Those initial measurements do not implement GUI focus hints, filesystem bulk, 40/100/200-PTY
scaling or native Windows/WSL bypass comparison. Aggregate throughput must be
interpreted separately from the foreground's throughput; raw background counts
and elapsed duration are retained for that purpose. CI runs correctness smokes,
not machine-independent latency thresholds.

### Mixed filesystem/exec interference

The runner additionally accepts `--bulk off fs exec mixed`,
`--bulk-exec-bytes` (default 524,288; maximum 1,048,576) and
`--resize-every N` (default 0, disabled). For example:

```sh
python3 scripts/agent_pty_bench.py --backend all --sessions 8 \
  --load noisy stalled --bulk off mixed --resize-every 16 \
  --runs 3 --samples 1000 --size-mib 10 --output mixed.jsonl
```

Bulk uses existing typed operations and protocol handlers. At most one 16 KiB
`FS_READ` and one non-PTY `EXEC` are pending; each completion is checked for exact
length and all-zero contents before another request of that kind is submitted.
The exec command reads `/dev/zero`. Shared PTYs use their existing connection;
native and dedicated PTYs use one additional agent connection, explicitly labeled
`separate_agent`. This is a connection-placement experiment, not native filesystem
versus agent filesystem performance. Requested PTYs plus enabled bulk workers
must fit the unchanged 16-job shared limit; invalid matrices fail before launch.

Local fs runs create and remove a unique 16 KiB zero fixture. Prepared remote
connectors require an explicit `--bulk-path` to an equivalent target-side fixture;
the runner does not deploy or delete remote files. Each enabled operation completes
one checked warmup before load starts, then counters reset. Counters include
foreground prompt warmups. They retain completion counts, exact byte totals,
total/max owner-observed RPC latency and a fixed 64-bucket log2-nanosecond histogram.
These timings include owner-loop scheduling and result decoding/verification;
they are **not** internal dispatch/control-queue timings or exact percentiles.
Pending bulk work is abandoned at teardown, not counted as completed throughput.

During receive, foreground reads precede bulk completion/submission and then the
existing bounded background service. Bulk processing can therefore delay the
owner loop even on separate connections. `--resize-every` alternates foreground
widths before selected prompt writes, including warmups; `resizes_issued` records
issuance only, not acknowledgement or applied-size latency. The lifecycle suite
separately checks terminal resize semantics. Output workloads do not issue resizes.
CLI defaults remain bulk off and resize disabled. CI exercises correctness, not
latency acceptance. This adds no GUI focus policy or rollout qualification.
The [eight-PTY repeated comparison](../benchmarks/agent-pty/2026-10-18-mixed-8.md)
preserves 72 off/mixed measurements, source patches and per-run summaries.

### Opt-in agent dispatch/output-queue diagnostics

`HOLLOW_AGENT_QUEUE_PROFILE=1` enables independently gated, fixed-size diagnostics
inside the Linux agent. The runner requires `--telemetry` with this environment
flag so the subprocess transport inherits agent stderr. The existing
`HOLLOW_AGENT_PROFILE` flag remains separate. For example:

```sh
HOLLOW_AGENT_QUEUE_PROFILE=1 python3 scripts/agent_pty_bench.py --telemetry \
  --backend shared --sessions 8 --load stalled --bulk off mixed \
  --resize-every 16 --runs 3 --samples 1000 --size-mib 10 --output queue-on.jsonl
```

Run a matching `--telemetry` comparison with the queue flag absent to measure its
overhead; compare neither directly with diagnostics-off historical numbers.
The flag must be explicitly supplied in the target environment for prepared
remote connectors; a client environment variable does not attest remote settings.
Stderr must be continuously drained. Snapshot serialization/emission occurs at
PTY completion and can add teardown latency; no logging occurs on protocol stdout.

The agent allocates one fixed-size profiler only when enabled. No timing samples
allocate memory. It tracks at most 1,024 pending spans, dropping **timings**, not
wire bytes, on overflow; `untracked`, `discarded` and `pending` explicitly report
coverage/censoring. Every successfully appended frame advances monotonic wire
positions; successful partial stdout writes advance completion positions, unaffected
by output-buffer compaction. With the legacy scheduler, filesystem workers append
opaque already-framed responses, so their entire reply is tracked as one span,
not falsely as one DATA frame. The bounded-bulk experiment below instead tracks
each issued worker frame separately. Disconnect discards unresolved spans rather
than recording false completions.

`AGENT_QUEUE_PROFILE` stderr records contain schema/version and explicit class
orders. Each class has enqueue counts, bytes already queued ahead, and enqueue-to-
first/complete-successful-write durations. Classes distinguish PTY DATA, exec DATA,
filesystem reply spans, successful PTY input/resize/close ACKs, and other frames.
These aggregate all streams on that connection, **not just foreground**. Input
ACK still means queued, not consumed by the child. Queue timings end when bytes
are accepted by the agent's stdout write, not when the client/VT/GUI consumes them.
They exclude delay before frame enqueue, including buffered PTY output and any
earlier credit or scheduling wait.

Dispatch duration covers one handler invocation, not arrival-to-dispatch latency.
Per-request durations include JSON parse/handler work; filesystem/exec values
measure dispatch/spawn, not asynchronous job completion. Poll timings separately
count calls made while a complete command is already buffered in agent memory.
They do not measure commands still waiting in the kernel pipe or incomplete frames.
Histograms have 64 fixed log2 buckets; bucket 0 includes 0/1, and bucket i>0 covers
`[2^i, 2^(i+1))`. Timing units are ns, queued-ahead units bytes. Sums saturate at
u64 maximum. Do not report histogram boundaries as exact percentiles.

Snapshots are cumulative over connection startup, priming and prompt warmups,
emitted when an open connection finalizes a PTY, before its terminal response/error. Pending/dropped spans remain
censored; a connection lost or closed before any PTY completion may emit no record.
Repeated snapshots are not independent samples. The runner preserves raw stderr
and parsed `agent_queue_profiles`, checking histogram/accounting and fixed bounds;
requested local agent/shared diagnostics fail if no snapshot arrives. No protocol
schema, scheduling policy, queue/admission limits or backend defaults change.
The [first diagnostic report](../benchmarks/agent-pty/2026-10-18-queue-profile.md)
preserves the on/off comparison, internal observations and dedicated E1 recheck.

### Opt-in bounded bulk scheduling

`HOLLOW_AGENT_BOUNDED_BULK=1` selects a research scheduler **only on connections
whose HELLO explicitly enables experimental PTYs**. The flag is ignored for
ordinary fs/exec connections. It does not select pane backends, infer GUI focus,
change protocol capabilities or raise the 16-job/32-request limits. An example:

```sh
HOLLOW_AGENT_BOUNDED_BULK=1 python3 scripts/agent_pty_bench.py --backend all \
  --sessions 8 --load noisy stalled --bulk off mixed --resize-every 16 \
  --runs 3 --samples 1000 --size-mib 10 --output bounded.jsonl
```

Completed exec/filesystem captures remain in their existing bounded job slots
until their terminal frame is queued. A rotating cursor shares output issuance
among credited PTYs and completed bulk jobs: one whole bulk frame or 16 KiB PTY
quantum per visited job, retaining the old 64 KiB PTY quantum when only one output
source is ready. Successful execs retain stdout-then-stderr DATA ordering and
terminal byte totals. Worker replies are validated and issued at whole-frame
boundaries, never spliced or re-encoded. Already queued/partially written frames
remain in their original byte order under the existing single stdout writer.

The shared batch budget is 65,536 payload bytes plus four 22-byte headers
(65,624 bytes), applied to bulk as well as PTY issuance. Control/error responses
can still exceed this soft budget; the existing 4 MiB safety cap remains. An
indivisible filesystem metadata frame larger than the batch budget may queue
**alone into an empty buffer**, within negotiated payload/global limits. This is
an explicit atomic-frame exception, not a claim that all metadata is at most
16 KiB. A blocked bulk frame retains the scheduling cursor so continuously ready
PTYs cannot keep stealing the space it needs after output drains.

Retained completed jobs own captured bytes, not a live child/process-group
identity. They skip process cleanup ticks; delivery deadlines/cancellation can
still discard unissued capture and emit one truncated error after any already
queued DATA. Reap matching ignores previously reaped jobs, preventing a reused
PID from overwriting an older completion. Connection teardown releases completed
captures directly. The already-reaped PID guard also protects the legacy path;
default scheduling remains unchanged. Retention can delay job admission and memory release; CPU/RSS,
many-job resource pressure and hostile control-flood fairness remain unqualified.

With queue diagnostics also enabled, `bounded_bulk` reports the negotiated
scheduler selection; `bulk_frames`, `bulk_deferred`, `bulk_oversized_frames` and
`bulk_max_queued_bytes` expose issuance, budget deferrals and atomic exceptions.
Historical snapshots without these optional fields remain readable. The runner
checks local snapshot selection against the requested environment flag. Remote
connectors must explicitly set target environment/argv; client flags alone do not
attest remote selection or build identity. Compare diagnostic-on/off separately.

### Explicit hierarchical focus baseline

`--focus-scheduler` is valid only with `--backend shared`; it requires both
target-side scheduler flags plus HELLO's `experimental_focus` and the matching
capability. Missing capability fails rather than silently timing flat RR.
See [wire/native API contract](agent-pty-experiment.md#explicit-focussession-scheduler-research-only).
Neither flag changes existing pane selection or ordinary host API routing.

The benchmark assigns explicit logical groups of four panes and selects the
measured foreground pane in group one before load starts. `sessions` retains its
historical meaning of **PTY/pane count**: eight here means two logical sessions,
not the plan's 10/25/50 logical sessions. Focus remains static during timing.
Its initial `focus_ack_ns` measures request-to-ACK wall time before load, not
focus-to-output causality, loaded change latency or a per-update p99. No GUI
renderer/parser work or warm shared-connection reuse is added.

Compare native, legacy flat PTY scheduling, bounded flat bulk scheduling and the
focus baseline separately. Hierarchical weighting changes how a logical session
shares visits irrespective of its pane count; it is **not byte-fair DRR**. It may
improve foreground shares by reducing siblings, other sessions or bulk rates.
Keep per-stream counters, aggregate PTY throughput, completed fs/exec throughput,
stopped-buffer size and background progress gaps alongside prompt p99. Equal
frame-visit weights do not imply equal bytes/second or starvation-free wall time.

Keep runs long enough to observe checked bulk completions. In an initial 1 MiB
focus smoke, the output workload ended with no completed mixed bulk progress and
the harness correctly failed `BulkStarved`. Do not weaken that validator, report
the partial dataset as passing, or treat a longer repeat as disproving starvation.
The CI focus correctness workload uses 10 MiB output, 200 prompts and 64 KiB EXEC
captures; performance comparisons retain 512 KiB captures. Resource/QoS bounds
and dynamic-focus timing still need independently sustained workloads.

### Static foreground-isolation comparison

`--separate-foreground --backend shared --sessions 8` pins foreground to another
prepared instance of the same agent, keeping background PTYs and bulk on the
original connection. It requires 2+ PTYs and rejects simultaneous separate bulk.
Existing conservative admission stays unchanged. Focused runs select foreground
stream on its connection and selected session/stream-zero on background; record
both pre-load ACKs independently. This is not live migration, cross-connection
global fairness, same-agent lanes or GUI routing.

Host `telemetry` and `background_telemetry` are separate connection snapshots;
`bulk_telemetry` may duplicate background connection and must not be summed again.
Queue-profile snapshots lack connection identity: this topology rejects local
queue flag and any received queue/focus traces rather than merging equal sequence
numbers. Remote queue profiling must remain off too.

The [isolation report](../benchmarks/agent-pty/2026-10-19-isolated-foreground.md)
preserves 124 ReleaseFast measurements plus four separate ReleaseSafe checks.
Local foreground gains are substantial, but prompt background/bulk rates fall,
and output aggregate gains conceal slower non-selected-session panes. Same offered
load is not equal achieved output/resources. Extra process/thread/transport costs,
genuine focus transitions and independent fault/recovery remain open; keep defaults.

### Hierarchical wire-byte scheduling comparison

`--focus-scheduler --deficit-scheduler` explicitly selects byte-deficit research,
requiring all three target scheduler flags and ACK `experimental.deficit`.
Otherwise weighted-focus, bounded-flat and default paths remain independently
selectable. Foreground grouping/focus metadata and consumption loop stay the same.
Use identical binaries/workloads with deficit off/on plus frozen prior/native
controls; do not equate weighted visit counts with weighted byte proportions.

The [DRR report](../benchmarks/agent-pty/2026-10-19-deficit-scheduler.md) specifies
wire-byte quanta, actual enqueue charging, conservative terminal reservations,
idle deficit resets, bounded metadata accumulation/retry and focus churn behavior.
All immediate control frames remain outside byte budgets, and large indivisible
metadata can still block stdout after enqueue. Static finite tests, fixed storage
and bounded virtual rounds do not qualify wall-time QoS, flood resistance or
sustained resources/scale. Preserve default E1 and per-stream/bulk tradeoffs.

### Explicit bulk placement comparison

`--separate-bulk --backend shared --bulk mixed` explicitly moves only fs/exec
interference onto another connection/process using the same prepared connector
and agent binary. PTYs retain their shared connection and optional static focus.
Omit the option for the co-located control. Native/dedicated placement is unchanged.
Inactive bulk and non-shared backends reject the option. Result `separate_bulk`
and `bulk_lane` must agree with requested topology; the runner never falls back.

Both placements prime one checked operation per kind before load. At equal PTY
count, compare foreground echo/output, each background's delivered bytes/gaps and
bulk completion throughput. Full 16-PTY plus separate-bulk smoke validates separate
admission, not equal resources or higher per-connection capacity. The owner loop
still services foreground first and bounded background/bulk work. Extra process,
transport, worker-loop isolation and OS scheduling all change, so this probe
cannot attribute differences solely to stdout head-of-line blocking or qualify
same-agent lanes. See [experiment](../benchmarks/agent-pty/2026-10-19-split-bulk.md).

### Per-sequence focus observability

With focus negotiated, existing target-side queue profiling also emits separate
`AGENT_FOCUS_PROFILE` snapshots. They retain the first 64 accepted sequences with
dispatch, first observed captured/credited readiness, next matching DATA enqueue,
absolute payload interval and successful stdout first/final payload writes.
Already queued DATA and header-only writes cannot satisfy correlation. Fixed
overflow drops timings only; superseded/no-stream/released/discarded records and
nullable pending timestamps stay explicit. Snapshots repeat per connection: select
latest observations by sequence within each run, never sum terminal duplicates.

`--focus-every N` explicitly refreshes the same foreground target before every
Nth prompt, including warmups, waiting for its ACK while servicing backgrounds and
bulk. ACK waits are outside the echo timer; preserve `focus_refreshes` sequence,
prompt index and RTT separately. Output cases still use only initial focus. This
is not a target-switch benchmark; quota truncation makes refresh a real workload
change, so compare identical refresh settings on/off. Never subtract client and
agent clock epochs or equate stdout writes with visible echo.

The [diagnostics report](../benchmarks/agent-pty/2026-10-19-focus-profile.md)
preserves 107 measurements and 15 reconstructed source hashes. Loaded samples
give per-sequence ready/enqueue/write boundaries, not kernel-readiness, prompt
identity, sustained QoS or GUI/application timing. At 32 loaded refreshes per run,
nearest-rank p99 equals max; missing/dropped records are not completed or imputed.
Default E1 remains inconclusive with failed individual prior/current native pairs.
