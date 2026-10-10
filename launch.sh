#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BIN_DIR="$SCRIPT_DIR/zig-out/bin"
TARGET="x86_64-windows-gnu"
BUILD=1
RUN=1
INSTALL=0
OPTIMIZE="ReleaseFast"
PDB=0
SAFE_RENDER=0
DISABLE_SWAPCHAIN_GLYPHS=0
DISABLE_MULTI_PANE_CACHE=0
LIST_FONTS=0
LIST_FONTS_JSON=0
MATCH_FONT=""
FORWARD_ARGS=()

EXPECT_MATCH_FONT=0
for arg in "$@"; do
  if [[ $EXPECT_MATCH_FONT -eq 1 ]]; then
    MATCH_FONT="$arg"
    EXPECT_MATCH_FONT=0
    continue
  fi
  case "$arg" in
  --no-build) BUILD=0 ;;
  --build-only) RUN=0 ;;
  --install) INSTALL=1 ;;
  --debug) OPTIMIZE="Debug" ;;
  --pdb) PDB=1 ;;
  --safe-render) SAFE_RENDER=1 ;;
  --no-swapchain-glyphs) DISABLE_SWAPCHAIN_GLYPHS=1 ;;
  --no-multi-pane-cache) DISABLE_MULTI_PANE_CACHE=1 ;;
  --list-fonts) LIST_FONTS=1 ;;
  --json) LIST_FONTS_JSON=1 ;;
  --match-font) EXPECT_MATCH_FONT=1 ;;
  --target=*) TARGET="${arg#--target=}" ;;
  --app-arg=*) FORWARD_ARGS+=("${arg#--app-arg=}") ;;
  --help | -h)
    echo "Usage: $0 [--no-build] [--build-only] [--install] [--debug] [--pdb] [--target=TARGET] [--safe-render] [--no-swapchain-glyphs] [--no-multi-pane-cache] [--list-fonts] [--match-font QUERY] [--json] [--app-arg=ARG]"
    echo "Lua dev loop: after one build, Lua files under src/lua/ are loaded from disk when present, so you can use --no-build for Lua-only changes."
    echo "Windows targets run from zig-out/bin by default. --install copies them to C:\\Applications\\Hollow and runs from there unless --build-only is set."
    exit 0
    ;;
  esac
done

if [[ $EXPECT_MATCH_FONT -eq 1 ]]; then
  echo "[launch] --match-font requires a query" >&2
  exit 1
fi

if [[ $INSTALL -eq 1 ]]; then
  if [[ "$TARGET" != *"windows"* ]]; then
    echo "[launch] --install is only supported for Windows targets" >&2
    exit 1
  fi
  if ! command -v wslpath >/dev/null 2>&1; then
    echo "[launch] --install requires WSL (wslpath not found)" >&2
    exit 1
  fi
fi

if [[ "$TARGET" == *"windows"* ]]; then
  EXE_NAME="hollow.exe"
  PDB_NAME="hollow.pdb"
  LAUNCHER_NAME="hollow.exe"
  LAUNCHER_PDB_NAME="hollow.pdb"
  GUI_NAME="hollow-native.exe"
  GUI_PDB_NAME="hollow-native.pdb"
  GUI_LAUNCHER_NAME="hollow-gui.exe"
  GUI_LAUNCHER_PDB_NAME="hollow-gui.pdb"
else
  EXE_NAME="hollow"
  PDB_NAME=""
  LAUNCHER_NAME=""
  LAUNCHER_PDB_NAME=""
  GUI_NAME=""
  GUI_PDB_NAME=""
  GUI_LAUNCHER_NAME=""
  GUI_LAUNCHER_PDB_NAME=""
fi
EXE_PATH="$BIN_DIR/$EXE_NAME"

if [[ $BUILD -eq 1 ]]; then
  "$SCRIPT_DIR/scripts/check-zig-version.sh"
  echo "[launch] building $TARGET target"
  if [[ -n "$OPTIMIZE" ]]; then
    echo "[launch] optimize mode: $OPTIMIZE"
  fi
  BUILD_ARGS=("-Dtarget=$TARGET")
  if [[ -n "$OPTIMIZE" ]]; then
    BUILD_ARGS+=("-Doptimize=$OPTIMIZE")
  fi
  if [[ $PDB -eq 1 ]]; then
    BUILD_ARGS+=("-Dpdb")
  fi
  zig build "${BUILD_ARGS[@]}"
fi

mkdir -p "$SCRIPT_DIR"

copy_if_exists() {
  local src="$1"
  local dst="$2"
  if [[ -f "$src" ]]; then
    if [[ "$src" == "$dst" ]]; then
      return
    fi
    if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
      return
    fi
    if [[ -f "$dst" ]]; then
      rm -f "$dst" 2>/dev/null || true
    fi
    cp "$src" "$dst"
  fi
}

if [[ $INSTALL -eq 1 ]]; then
  WINDOWS_APP_DIR="$(wslpath -u 'C:\Applications\Hollow')"
  for name in "$LAUNCHER_NAME" "$GUI_NAME" "$GUI_LAUNCHER_NAME"; do
    if [[ ! -f "$BIN_DIR/$name" ]]; then
      echo "[launch] missing $BIN_DIR/$name; build before installing" >&2
      exit 1
    fi
  done
  mkdir -p "$WINDOWS_APP_DIR"
  echo "[launch] copying Windows artifacts to $WINDOWS_APP_DIR"
  for name in "$LAUNCHER_NAME" "$GUI_NAME" "$GUI_LAUNCHER_NAME" \
    "$LAUNCHER_PDB_NAME" "$GUI_PDB_NAME" "$GUI_LAUNCHER_PDB_NAME" \
    hollow-wsl-bypass hollow-cli; do
    copy_if_exists "$BIN_DIR/$name" "$WINDOWS_APP_DIR/$name"
  done
  # Keep on-disk Lua/config overrides available beside the relocated executable.
  mkdir -p "$WINDOWS_APP_DIR/src"
  cp -R "$SCRIPT_DIR/src/lua" "$WINDOWS_APP_DIR/src/"
  cp -R "$SCRIPT_DIR/conf" "$WINDOWS_APP_DIR/"
  EXE_PATH="$WINDOWS_APP_DIR/$EXE_NAME"
fi

if [[ $RUN -eq 1 ]]; then
  RUN_ARGS=()
  if [[ $SAFE_RENDER -eq 1 ]]; then
    echo "[launch] renderer safe mode enabled"
    RUN_ARGS+=("--renderer-safe-mode")
    if [[ $DISABLE_SWAPCHAIN_GLYPHS -eq 0 ]]; then
      DISABLE_SWAPCHAIN_GLYPHS=1
    fi
  fi
  if [[ $DISABLE_SWAPCHAIN_GLYPHS -eq 1 ]]; then
    echo "[launch] swapchain glyph draw disabled"
    RUN_ARGS+=("--renderer-disable-swapchain-glyphs")
  fi
  if [[ $DISABLE_MULTI_PANE_CACHE -eq 1 ]]; then
    echo "[launch] multi-pane cache disabled"
    RUN_ARGS+=("--renderer-disable-multi-pane-cache")
  fi
  if [[ ${#FORWARD_ARGS[@]} -gt 0 ]]; then
    RUN_ARGS+=("${FORWARD_ARGS[@]}")
  fi
  if [[ $LIST_FONTS -eq 1 ]]; then
    RUN_ARGS+=("--list-fonts")
  fi
  if [[ -n "$MATCH_FONT" ]]; then
    RUN_ARGS+=("--match-font" "$MATCH_FONT")
  fi
  if [[ $LIST_FONTS_JSON -eq 1 ]]; then
    RUN_ARGS+=("--json")
  fi
  echo "[launch] running $EXE_PATH with args: ${RUN_ARGS[*]}"

  exec "$EXE_PATH" "${RUN_ARGS[@]}"
fi
