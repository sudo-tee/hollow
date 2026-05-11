#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$SCRIPT_DIR/.."
TOOL_VERSIONS="$ROOT/.tool-versions"

if [[ ! -f "$TOOL_VERSIONS" ]]; then
  echo "[zig-check] missing $TOOL_VERSIONS" >&2
  exit 1
fi

REQUIRED_ZIG="$(grep -E '^zig ' "$TOOL_VERSIONS" | head -n 1 | awk '{print $2}')"

if [[ -z "$REQUIRED_ZIG" ]]; then
  echo "[zig-check] could not determine required Zig version from $TOOL_VERSIONS" >&2
  exit 1
fi

if ! command -v zig >/dev/null 2>&1; then
  echo "[zig-check] zig is not installed or not on PATH" >&2
  echo "[zig-check] required version: $REQUIRED_ZIG" >&2
  exit 1
fi

CURRENT_ZIG="$(zig version)"

if [[ "$CURRENT_ZIG" != "$REQUIRED_ZIG" ]]; then
  echo "[zig-check] wrong Zig version: found $CURRENT_ZIG, expected $REQUIRED_ZIG" >&2
  echo "[zig-check] install the pinned toolchain with 'asdf install' or 'mise install', or install Zig $REQUIRED_ZIG manually" >&2
  exit 1
fi
