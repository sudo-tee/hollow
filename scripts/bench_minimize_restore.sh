#!/usr/bin/env bash
# Print the manual minimize-restore snapshot workflow and its driver command.
#
# Usage: bench.sh minimize-restore [OUT_PATH] [PRE_MS] [MINIMIZED_MS] [POST_MS]
set -euo pipefail

out_path="${1:-bench_minimize_restore_snapshot.txt}"
pre_minimize_delay_ms="${2:-2000}"
minimized_delay_ms="${3:-1000}"
post_restore_delay_ms="${4:-1200}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ps_script="$(wslpath -w "$script_dir/minimize-restore.ps1")"

echo "[bench] manual minimize-restore workflow"
echo "[bench] 1) launch hollow with: launch.sh --app-arg=\"--snapshot-dump\" --app-arg=\"$out_path\""
echo "[bench] 2) create visible shell output in the window"
echo "[bench] 3) run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"$ps_script\" -ProcessName \"hollow-native\" -PreMinimizeDelayMs $pre_minimize_delay_ms -MinimizedDelayMs $minimized_delay_ms -PostRestoreDelayMs $post_restore_delay_ms"
echo "[bench] 4) inspect $out_path for lost shell content after restore"
