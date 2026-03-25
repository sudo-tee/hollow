#!/usr/bin/env bash
# launch.sh – run ghostty-love from WSL using the Windows Love2D binary
#
# Usage:
#   ./launch.sh            # normal launch
#   ./launch.sh --log      # write stderr to /tmp/ghostty-love.log
#   ./launch.sh --console  # open a Windows console window (shows Lua errors)
#
# Requirements:
#   - Love2D for Windows installed at C:\Program Files\LOVE\love.exe
#     (override with LOVE_EXE env var)
#   - ghostty-vt.dll in the project directory (already there)

set -euo pipefail

LOVE_EXE="${LOVE_EXE:-/mnt/c/Program Files/LOVE/love.exe}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Convert the WSL path of the project to a Windows path that love.exe understands
WIN_PATH="$(wslpath -w "$SCRIPT_DIR")"

LOG=0
CONSOLE=0

for arg in "$@"; do
	case "$arg" in
	--log) LOG=1 ;;
	--console) CONSOLE=1 ;;
	--help | -h)
		echo "Usage: $0 [--log] [--console]"
		echo "  --log      Write stderr output to /tmp/ghostty-love.log"
		echo "  --console  Open a Windows console window (shows Lua errors live)"
		exit 0
		;;
	esac
done

# Copy the DLL next to love.exe if it isn't there already.
# This is the most reliable way for the Windows binary to find it.
LOVE_DIR="$(dirname "$LOVE_EXE")"
DLL_SRC="$SCRIPT_DIR/ghostty-vt.dll"
DLL_DST="$LOVE_DIR/ghostty-vt.dll"

if [[ -f "$DLL_SRC" ]]; then
	if [[ ! -f "$DLL_DST" ]] || ! cmp -s "$DLL_SRC" "$DLL_DST"; then
		echo "[launch] Copying ghostty-vt.dll → $LOVE_DIR"
		cp "$DLL_SRC" "$DLL_DST"
	fi
fi

# Build the argument list
LOVE_ARGS=("$WIN_PATH")

# --console opens a Windows cmd window so you can see print() and errors.
# Omit it for a clean launch once everything is working.
if [[ $CONSOLE -eq 1 ]]; then
	LOVE_ARGS+=("--console")
	export GHOSTTY_LOVE_DEBUG=1
fi

echo "[launch] Running: \"$LOVE_EXE\" ${LOVE_ARGS[*]}"

if [[ $LOG -eq 1 ]]; then
	LOG_FILE="/tmp/ghostty-love.log"
	echo "[launch] Logging stderr → $LOG_FILE"
	# Run detached so the terminal isn't blocked; stderr goes to the log.
	"$LOVE_EXE" "${LOVE_ARGS[@]}" 2>"$LOG_FILE" &
	LOVE_PID=$!
	echo "[launch] PID $LOVE_PID  –  tail -f $LOG_FILE"
	# Show the log in this terminal while the app runs
	tail -f "$LOG_FILE" &
	TAIL_PID=$!
	wait $LOVE_PID
	kill $TAIL_PID 2>/dev/null || true
	echo "[launch] love.exe exited."
else
	# Foreground – stderr goes straight to the WSL terminal
	exec "$LOVE_EXE" "${LOVE_ARGS[@]}"
fi
