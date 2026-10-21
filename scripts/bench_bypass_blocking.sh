#!/usr/bin/env bash
# Verify the pane relay keeps draining output while its input side is blocked.
#
# Creates a second pane running `bench.sh blocking-child`, floods it with input,
# and fails if the child stops reporting progress.
#
# Usage: bench.sh bypass-blocking [CHUNKS] [TIMEOUT_S]
set -euo pipefail

chunks="${1:-1024}"
timeout_s="${2:-15}"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
bench_sh="$script_dir/../bench.sh"

if command -v hollow-cli >/dev/null 2>&1; then
  cli="$(command -v hollow-cli)"
else
  cli="$script_dir/hollow-cli"
fi
if [[ ! -x "$cli" ]]; then
  echo "[bench] hollow-cli is required for bypass-blocking" >&2
  exit 1
fi

tag="bypass-blocking-$$-$(date +%s)"
result_path="/tmp/$tag.result"
ready_path="/tmp/$tag.ready"
rm -f "$result_path" "$result_path.progress" "$ready_path"
printf -v target_cmd '%q --quiet pane set-tag %q && exec %q blocking-child %q %q %q' \
  "$cli" "$tag" "$bench_sh" "$result_path" "$ready_path" "$chunks"

echo "[bench] creating blocked-input target pane tag=$tag"
"$cli" --quiet pane split vertical --ratio 0.5 --cmd "$target_cmd"
deadline=$((SECONDS + 5))
while [[ ! -f "$ready_path" && $SECONDS -lt $deadline ]]; do sleep 0.05; done
if [[ ! -f "$ready_path" ]]; then
  echo "[bench] target pane did not become ready" >&2
  "$cli" --quiet pane close --tag "$tag" 2>/dev/null || true
  exit 1
fi

printf -v payload '%*s' 32768 ''
payload="${payload// /x}"
(
  for _ in $(seq 1 128); do
    "$cli" --quiet pane send-text "$payload" --tag "$tag" 2>/dev/null || break
  done
) &
sender_pid=$!

echo "[bench] injecting 4MiB while target writes $((chunks * 16384 / 1024 / 1024))MiB"
deadline=$((SECONDS + timeout_s))
while [[ ! -f "$result_path" && $SECONDS -lt $deadline ]]; do sleep 0.05; done

passed=1
if [[ -f "$result_path" ]]; then
  cat "$result_path"
  echo "[bench] PASS: relay continued draining output under input backpressure"
  passed=0
else
  echo "[bench] TIMEOUT after ${timeout_s}s"
  if [[ -f "$result_path.progress" ]]; then cat "$result_path.progress"; fi
  echo "[bench] FAIL: relay stopped making output progress under input backpressure"
fi

kill "$sender_pid" 2>/dev/null || true
wait "$sender_pid" 2>/dev/null || true
"$cli" --quiet pane close --tag "$tag" 2>/dev/null || true
rm -f "$result_path" "$result_path.progress" "$ready_path"
exit "$passed"
