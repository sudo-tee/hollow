# Renderer Benchmark History

Use `scripts/renderer-bench.py` to preserve benchmark results from `zig build run-renderer-bench`.

Default history lives in ignored `.bench-history/renderer-bench.jsonl`.
Each line contains benchmark JSON plus commit, dirty-state, toolchain, host, and command metadata.

Record a snapshot:

```sh
python3 scripts/renderer-bench.py record \
  --scenario repaint \
  --mode pipeline \
  --frames 1000 \
  --iterations 10
```

Save a versioned baseline explicitly:

```sh
python3 scripts/renderer-bench.py record \
  --scenario repaint \
  --mode pipeline \
  --frames 1000 \
  --save-baseline bench-history/baselines/repaint-pipeline.json \
  --history bench-history/renderer-bench.jsonl
```

Compare latest snapshot against previous matching snapshot:

```sh
python3 scripts/renderer-bench.py compare \
  --history bench-history/renderer-bench.jsonl
```

Compare against explicit baseline and fail when median or p95 regresses by more than 5 percent:

```sh
python3 scripts/renderer-bench.py compare \
  --history bench-history/renderer-bench.jsonl \
  --baseline bench-history/baselines/repaint-pipeline.json \
  --max-regression 0.05
```

Keep long-term CI history in a dedicated benchmark branch or repository.
Pass its checked-out JSONL path with `--history` and upload or commit only that history.
Do not use GUI `bench.sh` rates as strict CI gates; compositor and host scheduling add substantial noise.
