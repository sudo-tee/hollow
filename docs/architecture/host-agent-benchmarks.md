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
