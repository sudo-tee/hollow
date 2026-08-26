#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
REPO_DIR="$(readlink -f "$SCRIPT_DIR/..")"
if [[ -n "${APPDATA:-}" ]]; then
  LOG_PATH="$APPDATA/hollow/hollow.log"
elif [[ -n "${USERPROFILE:-}" ]]; then
  LOG_PATH="$USERPROFILE/AppData/Roaming/hollow/hollow.log"
else
  LOG_PATH="$REPO_DIR/zig-out/bin/hollow.log"
fi

rm -f "$LOG_PATH"

cat <<'EOF'
[trace-terminal] Enable in config:
  hollow.config.set({ debug_terminal_trace = true })

[trace-terminal] Starting app. Reproduce:
  1. Neovim cursor shape change
  2. Prompt paste with Shift-Insert
  3. Claude Code missing cursor

[trace-terminal] Then inspect:
  hollow.log
EOF

exec "$REPO_DIR/launch.sh" "$@"
