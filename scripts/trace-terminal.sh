#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
REPO_DIR="$(readlink -f "$SCRIPT_DIR/..")"
LOG_PATH="$REPO_DIR/hollow.log"

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
