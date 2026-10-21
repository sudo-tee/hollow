#!/usr/bin/env bash
# Launch Hollow with an nvim :restart and dump a snapshot after a frame delay.
#
# Usage: bench.sh nvim-restart [OUT_PATH] [DELAY_FRAMES]
set -euo pipefail

OUT_PATH="${1:-bench_nvim_restart_snapshot.txt}"
DELAY_FRAMES="${2:-45}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

echo "[bench] nvim-restart snapshot dump -> $OUT_PATH"
echo "[bench] close the app when the capture is done"
rm -f "$OUT_PATH"
exec "$SCRIPT_DIR/../launch.sh" \
  --app-arg="--startup-command" --app-arg=":restart" \
  --app-arg="--startup-command-delay-frames" --app-arg="$DELAY_FRAMES" \
  --app-arg="--snapshot-dump" --app-arg="$OUT_PATH"
