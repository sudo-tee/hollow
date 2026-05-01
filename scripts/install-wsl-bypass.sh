#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
SRC="$ROOT_DIR/zig-out/bin/hollow-wsl-bypass"
DEST='/usr/local/bin/hollow-wsl-bypass'

if [[ ! -f "$SRC" ]]; then
  echo "[install-wsl-bypass] missing $SRC; build with 'zig build wsl-bypass' first" >&2
  exit 1
fi

if [[ -n "${WSL_DISTRO_NAME:-}" ]] || [[ "$(uname -s)" == "Linux" ]]; then
  if [[ ! -w /usr/local/bin ]]; then
    echo "[install-wsl-bypass] /usr/local/bin requires elevated permissions; run with sudo" >&2
    exit 1
  fi
  install -d -m 755 /usr/local/bin
  install -m 755 "$SRC" "$DEST"
  echo "[install-wsl-bypass] installed locally: $DEST"
  exit 0
fi

if command -v wsl.exe >/dev/null 2>&1; then
  if ! command -v cygpath >/dev/null 2>&1; then
    echo "[install-wsl-bypass] cygpath is required when running from Windows bash" >&2
    exit 1
  fi
  SRC_WSL="$(wsl.exe wslpath -a "$(cygpath -u "$SRC")" | tr -d '\r')"
  wsl.exe sh -lc "if [ ! -w /usr/local/bin ]; then echo '[install-wsl-bypass] /usr/local/bin requires elevated permissions; rerun with sudo inside WSL' >&2; exit 1; fi; install -d -m 755 /usr/local/bin && install -m 755 \"$SRC_WSL\" \"$DEST\""
  echo "[install-wsl-bypass] installed to WSL default distro: $DEST"
  exit 0
fi

echo "[install-wsl-bypass] unsupported host: run this from Windows with WSL installed, or from inside WSL" >&2
exit 1
