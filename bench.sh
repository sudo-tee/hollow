#!/usr/bin/env bash
# Router for Hollow's terminal benchmarks; workload modes are implemented in scripts/.
# With no arguments (or --help) it lists the modes. Invoke as `bench.sh`
# (or `make bench`).
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
prog="${HOLLOW_BENCH_PROG:-$(basename -- "${BASH_SOURCE[0]}")}"

usage() {
  local prefix="$prog " suffix=""
  if [[ "$prog" == "make bench" ]]; then
    prefix='make bench ARGS="'
    suffix='"'
  fi
  cat <<EOF
$prog: router for Hollow's terminal benchmarks. Workload modes live in scripts/.

Workload modes only emit terminal traffic on stdout; run them inside the
terminal under test (e.g. a Hollow pane).

  ${prefix}WORKLOAD [COUNT] [RATE_HZ] [UPDATES_PER_BATCH] [CHUNK_BYTES] [WRITE_DELAY_MS]${suffix}

  scroll        flat colored line scrolling
  repaint       full-viewport repaint, measured end-to-end via DSR drain
  keypress      j/k style scroll of a single new line per keypress
  split-scroll  static left pane, right pane rewritten each keypress
  sync-output   viewport rewrites wrapped in CSI ?2026h/l
  chunked       chunked writes with synchronized output
  chunked-raw   chunked writes without synchronized output
  codex-flash   sparse timer-driven status-row updates
  image         visible Kitty image placement and composition workload
  image-animation visible Kitty animated-image workload
  ${prefix}image [COUNT] [RATE_HZ] [IMAGES] [PIXELS] [CHUNK_BYTES]${suffix}
  ${prefix}image-animation [TICKS] [RATE_HZ] [IMAGES] [ANIMATION_FRAMES] [FRAME_DELAY_MS]${suffix}

Headless renderer modes:

  ${prefix}renderer-image [renderer-bench ARGS...]${suffix}
  ${prefix}renderer-image-animation [renderer-bench ARGS...]${suffix}

Workflow modes:

  ${prefix}cpu COMMAND [ARGS...]${suffix}
  ${prefix}bypass-blocking [CHUNKS] [TIMEOUT_S]${suffix}
  ${prefix}nvim-restart [OUT_PATH] [DELAY_FRAMES]${suffix}
  ${prefix}minimize-restore [OUT_PATH] [PRE_MS] [MINIMIZED_MS] [POST_MS]${suffix}
  ${prefix}blocking-child RESULT_PATH READY_PATH [CHUNKS]${suffix}   (internal)
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

run_renderer_bench() {
  local scenario="$1"
  shift
  if [[ -x "$script_dir/zig-out/bin/hollow-renderer-bench" ]]; then
    exec "$script_dir/zig-out/bin/hollow-renderer-bench" --scenario "$scenario" "$@"
  fi
  if ! command -v zig >/dev/null 2>&1; then
    echo "$prog requires zig or zig-out/bin/hollow-renderer-bench" >&2
    exit 1
  fi
  cd -- "$script_dir"
  exec zig build run-renderer-bench -Doptimize=ReleaseFast -- --scenario "$scenario" "$@"
}

case "$mode" in
  scroll|repaint|keypress|split-scroll|sync-output|chunked|chunked-raw|codex-flash)
    need_python
    HOLLOW_BENCH_PROG="$prog" exec python3 "$script_dir/scripts/bench_workloads.py" "$mode" "$@"
    ;;
  image|image-animation)
    need_python
    exec python3 "$script_dir/scripts/bench_images.py" "$mode" "$@"
    ;;
  renderer-image|renderer-image-animation)
    run_renderer_bench "${mode#renderer-}" "$@"
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
    if [[ "$prog" == "make bench" ]]; then
      echo 'See make bench ARGS=--help for usage.' >&2
    else
      echo "See $prog --help for usage." >&2
    fi
    exit 2
    ;;
esac
