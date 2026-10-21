#!/usr/bin/env bash
# Router for Hollow's terminal benchmarks; each mode is implemented in scripts/.
# With no arguments (or --help) it lists the modes. Invoke as `bench.sh`
# (or `make bench`).
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
prog="$(basename -- "${BASH_SOURCE[0]}")"

usage() {
  cat <<EOF
$prog: router for Hollow's terminal benchmarks. Each mode lives in scripts/.

Workload modes only emit terminal traffic on stdout; run them inside the
terminal under test (e.g. a Hollow pane).

  $prog WORKLOAD [COUNT] [RATE_HZ] [UPDATES_PER_BATCH] [CHUNK_BYTES] [WRITE_DELAY_MS]

  scroll        flat colored line scrolling
  repaint       full-viewport repaint, measured end-to-end via DSR drain
  keypress      j/k style scroll of a single new line per keypress
  split-scroll  static left pane, right pane rewritten each keypress
  sync-output   viewport rewrites wrapped in CSI ?2026h/l
  chunked       chunked writes with synchronized output
  chunked-raw   chunked writes without synchronized output
  codex-flash   sparse timer-driven status-row updates

Workflow modes:

  $prog cpu COMMAND [ARGS...]
  $prog bypass-blocking [CHUNKS] [TIMEOUT_S]
  $prog nvim-restart [OUT_PATH] [DELAY_FRAMES]
  $prog minimize-restore [OUT_PATH] [PRE_MS] [MINIMIZED_MS] [POST_MS]
  $prog blocking-child RESULT_PATH READY_PATH [CHUNKS]   (internal)
EOF
}

mode="${1:-}"
if [[ -z "$mode" ]]; then
  usage
  exit 0
fi
shift || true

need_python() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "$prog requires python3" >&2
    exit 1
  fi
}

case "$mode" in
  scroll|repaint|keypress|split-scroll|sync-output|chunked|chunked-raw|codex-flash)
    need_python
    HOLLOW_BENCH_PROG="$prog" exec python3 "$script_dir/scripts/bench_workloads.py" "$mode" "$@"
    ;;
  cpu)
    need_python
    HOLLOW_BENCH_PROG="$prog" exec python3 "$script_dir/scripts/bench_cpu.py" -- "$@"
    ;;
  blocking-child)
    need_python
    exec python3 "$script_dir/scripts/bench_blocking_child.py" "$@"
    ;;
  bypass-blocking)
    HOLLOW_BENCH_PROG="$prog" exec "$script_dir/scripts/bench_bypass_blocking.sh" "$@"
    ;;
  nvim-restart)
    exec "$script_dir/scripts/bench_nvim_restart.sh" "$@"
    ;;
  minimize-restore)
    exec "$script_dir/scripts/bench_minimize_restore.sh" "$@"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "$prog: unknown mode '$mode'" >&2
    echo "usage: $prog [WORKLOAD|MODE] [ARGS...]  (see $prog --help)" >&2
    exit 2
    ;;
esac
