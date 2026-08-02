#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$SCRIPT_DIR/.."
BUSTED="${BUSTED:-busted}"
LUA="${LUA:-luajit}"

if ! command -v "$BUSTED" >/dev/null 2>&1; then
  echo "test-lua.sh: busted is required; install it with: luarocks --lua-version=5.1 install busted" >&2
  exit 127
fi

if ! command -v "$LUA" >/dev/null 2>&1; then
  echo "test-lua.sh: Lua interpreter not found: $LUA" >&2
  exit 127
fi

exec "$BUSTED" --directory="$ROOT" --config-file="$ROOT/.busted" --lua="$LUA" "$@"
