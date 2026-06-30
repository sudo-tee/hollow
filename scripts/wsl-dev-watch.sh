#!/usr/bin/env bash
# Dev-only WSL file watcher.
#
# Watches a directory tree inside WSL for .lua changes and touches a file on
# the real Windows filesystem (/mnt/c/...) so the Windows-side hollow process
# reloads its config.
#
# Why: hollow uses ReadDirectoryChangesW to watch config dirs on Windows.
# RDCW does NOT fire on \\wsl$\ / \\wsl.localhost\ 9P-backed UNC paths, so
# editing files on the WSL ext4 filesystem never notifies the Windows hollow
# process. This script bridges the gap: inotify inside WSL detects the edit,
# then touches a file on /mnt/c/ (real NTFS) which hollow's RDCW watcher sees.
#
# Configure hollow to watch the directory containing the touch target:
#   watch_dirs = { "C:\\Users\\you\\AppData\\Roaming\\hollow" }
# or point base/override config at the touch target itself.
#
# Run from inside WSL:
#   scripts/wsl-watch-touch.sh /home/francis/Projects/_stuff/hollow /mnt/c/Users/francis/AppData/Roaming/hollow/.wsl-reload-trigger
#
# Requires inotify-tools: sudo apt install inotify-tools

set -euo pipefail

if ! command -v inotifywait >/dev/null 2>&1; then
  echo "error: inotifywait not found. Install with: sudo apt install inotify-tools" >&2
  exit 1
fi

if [ $# -lt 2 ]; then
  echo "usage: $0 <wsl_watch_dir> <windows_touch_target>" >&2
  echo "  wsl_watch_dir         WSL path to watch recursively for .lua changes" >&2
  echo "  windows_touch_target  /mnt/c/... path to touch on each change" >&2
  exit 2
fi

watch_dir=$1
touch_target=$2

if [ ! -d "$watch_dir" ]; then
  echo "error: watch dir does not exist: $watch_dir" >&2
  exit 1
fi

# Ensure touch target exists and its parent dir is real NTFS, not 9P.
touch_target_abs=$(readlink -f "$touch_target" 2>/dev/null || echo "$touch_target")
case "$touch_target_abs" in
  /mnt/*) ;;
  *)
    echo "error: touch target must be a /mnt/... (real Windows FS) path, got: $touch_target_abs" >&2
    echo "       9P-backed WSL paths (\\wsl$\) do not trigger RDCW on the Windows side." >&2
    exit 1
    ;;
esac

mkdir -p "$(dirname "$touch_target_abs")"
touch "$touch_target_abs"

# Skip inotify events on the touch target itself to avoid a self-trigger loop
# (only relevant when watch_dir contains the touch target, e.g. watching
# /mnt/c/foo and touching /mnt/c/foo/trigger.lua).
touch_target_in_watch=$(case "$touch_target_abs" in
  "$watch_dir"*) echo yes ;;
  *) echo no ;;
esac)

echo "wsl-watch-touch: watching $watch_dir (**/*.lua)"
echo "wsl-watch-touch: touching $touch_target_abs on change"
echo "wsl-watch-touch: self-trigger filter: $touch_target_in_watch"
echo "wsl-watch-touch: ready (pid $$)"

# Close-write + moved-to + create covers real edits and atomic saves.
# modify alone fires too often mid-write; close_write is the reliable signal.
inotifywait -r -q -m \
  -e close_write -e moved_to -e create \
  --include '\.lua$' \
  "$watch_dir" |
while read -r path _event file; do
  full="$path$file"
  if [ "$touch_target_in_watch" = "yes" ]; then
    abs=$(readlink -f "$full" 2>/dev/null || echo "$full")
    if [ "$abs" = "$touch_target_abs" ]; then
      echo "wsl-watch-touch: [skip] self-trigger $abs"
      continue
    fi
  fi
  touch "$touch_target_abs"
  echo "wsl-watch-touch: [touch] event=$_event file=$full -> $touch_target_abs"
done
