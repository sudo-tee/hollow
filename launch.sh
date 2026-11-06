#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BIN_DIR="$SCRIPT_DIR/zig-out/bin"
TARGET="x86_64-windows-gnu"
BUILD=1
RUN=1
INSTALL=0
OPTIMIZE="ReleaseFast"
DEV=0
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
  --dev) DEV=1 ;;
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
    echo "Usage: $0 [--no-build] [--build-only] [--install] [--debug] [--dev] [--pdb] [--target=TARGET] [--safe-render] [--no-swapchain-glyphs] [--no-multi-pane-cache] [--list-fonts] [--match-font QUERY] [--json] [--app-arg=ARG]"
    echo "Lua dev loop: after one build, Lua files under src/lua/ are loaded from disk when present, so you can use --no-build for Lua-only changes."
    echo "ReleaseFast omits debug information by default. Use --pdb to retain symbols for profiling or crash reports."
    echo "--dev builds app code in Debug with ReleaseFast C dependencies, and only the app executables (no CLI/agent bundles) unless --install is set."
    echo "Windows targets run from zig-out/bin by default. --install copies them to C:\\Applications\\Hollow and runs from there unless --build-only is set."
    echo "--install first closes a running installed Hollow and reopens it afterwards; persistent sessions are restored."
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
  GUI_NAME="hollow-native.exe"
  GUI_PDB_NAME="hollow-native.pdb"
else
  EXE_NAME="hollow"
  PDB_NAME=""
  GUI_NAME=""
  GUI_PDB_NAME=""
fi
EXE_PATH="$BIN_DIR/$EXE_NAME"

if [[ $BUILD -eq 1 ]]; then
  "$SCRIPT_DIR/scripts/check-zig-version.sh"
  echo "[launch] building $TARGET target"
  BUILD_ARGS=()
  if [[ $DEV -eq 1 ]]; then
    echo "[launch] optimize mode: dev (Debug app, ReleaseFast dependencies)"
    # Installation needs the full CLI/agent bundles; plain dev launches do not.
    if [[ $INSTALL -eq 0 ]]; then
      BUILD_ARGS+=("gui")
    fi
    BUILD_ARGS+=("-Dtarget=$TARGET" "-Ddev")
  else
    echo "[launch] optimize mode: $OPTIMIZE"
    BUILD_ARGS+=("-Dtarget=$TARGET" "-Doptimize=$OPTIMIZE")
  fi
  if [[ $PDB -eq 1 ]]; then
    BUILD_ARGS+=("-Dpdb")
  fi
  zig build "${BUILD_ARGS[@]}"
  mkdir -p "$SCRIPT_DIR/zig-out"
  # The binary embeds this module list; dev.sh rebuilds when it changes.
  find "$SCRIPT_DIR/src/lua/hollow" -type f -name '*.lua' -printf '%P\n' | LC_ALL=C sort >"$SCRIPT_DIR/zig-out/.lua-modules"
  if [[ $DEV -eq 1 ]]; then
    printf '%s dev\n' "$TARGET" > "$SCRIPT_DIR/zig-out/.launch-build-mode"
  else
    printf '%s %s pdb=%s\n' "$TARGET" "$OPTIMIZE" "$PDB" > "$SCRIPT_DIR/zig-out/.launch-build-mode"
  fi
fi

copy_if_exists() {
  local src="$1"
  local dst="$2"
  [[ -f "$src" && "$src" != "$dst" ]] || return 0
  if [[ -f "$dst" ]]; then rm -f "$dst" 2>/dev/null || true; fi
  cp "$src" "$dst"
}

# Encode the helper and its arguments together to avoid WSL/PowerShell quoting.
windows_app() {
  local action="$1"
  shift
  local encoded
  encoded="$(printf '%s' "& { $(cat "$SCRIPT_DIR/scripts/restart-hollow.ps1") } -Action '$action' -AppArgs $(ps_list "$@")" |
    iconv -f UTF-8 -t UTF-16LE | base64 -w0)"
  powershell.exe -NoProfile -NonInteractive -EncodedCommand "$encoded" </dev/null
}

ps_list() {
  local arg list=""
  for arg in "$@"; do
    list+="${list:+,}'${arg//\'/\'\'}'"
  done
  printf '@(%s)' "$list"
}

RUN_ARGS=()
if [[ $RUN -eq 1 ]]; then
  if [[ $SAFE_RENDER -eq 1 ]]; then
    echo "[launch] renderer safe mode enabled"
    RUN_ARGS+=("--renderer-safe-mode")
    DISABLE_SWAPCHAIN_GLYPHS=1
  fi
  if [[ $DISABLE_SWAPCHAIN_GLYPHS -eq 1 ]]; then
    echo "[launch] swapchain glyph draw disabled"
    RUN_ARGS+=("--renderer-disable-swapchain-glyphs")
  fi
  if [[ $DISABLE_MULTI_PANE_CACHE -eq 1 ]]; then
    echo "[launch] multi-pane cache disabled"
    RUN_ARGS+=("--renderer-disable-multi-pane-cache")
  fi
  RUN_ARGS+=("${FORWARD_ARGS[@]}")
  if [[ $LIST_FONTS -eq 1 ]]; then
    RUN_ARGS+=("--list-fonts")
  fi
  if [[ -n "$MATCH_FONT" ]]; then
    RUN_ARGS+=("--match-font" "$MATCH_FONT")
  fi
  if [[ $LIST_FONTS_JSON -eq 1 ]]; then
    RUN_ARGS+=("--json")
  fi
fi

if [[ $INSTALL -eq 1 ]]; then
  WINDOWS_APP_DIR="$(wslpath -u 'C:\Applications\Hollow')"
  for name in "$EXE_NAME" "$GUI_NAME" hollow-cli.exe; do
    if [[ ! -f "$BIN_DIR/$name" ]]; then
      echo "[launch] missing $BIN_DIR/$name; build before installing" >&2
      exit 1
    fi
  done
  for name in SHA256SUMS linux-x86_64/hollow-cli linux-aarch64/hollow-cli; do
    if [[ ! -f "$SCRIPT_DIR/zig-out/cli/$name" ]]; then
      echo "[launch] missing CLI bundle file $name; run zig build cli-all before installing" >&2
      exit 1
    fi
  done
  for name in SHA256SUMS linux-x86_64/hollow-agent linux-aarch64/hollow-agent; do
    if [[ ! -f "$SCRIPT_DIR/zig-out/agents/$name" ]]; then
      echo "[launch] missing agent bundle file $name; run zig build agent-all before installing" >&2
      exit 1
    fi
  done
  # Closing Hollow can hang up the terminal running this script (a
  # non-persistent pane). Keep going so the app is always reopened, and keep
  # a copy of the output in case the terminal is gone.
  INSTALL_LOG="$SCRIPT_DIR/zig-out/install.log"
  trap '' HUP
  exec > >(tee -p "$INSTALL_LOG") 2>&1
  echo "[launch] closing installed Hollow (up to 3s after PowerShell starts)"
  PHASE_START=$SECONDS
  CLOSE_STATUS=0
  windows_app Close || CLOSE_STATUS=$?
  case "$CLOSE_STATUS" in
    0|3) ;; # Closed, or no installed copy was running.
    *) echo "[launch] could not close Hollow; installation cancelled" >&2; exit 1 ;;
  esac
  echo "[launch] close check finished in $((SECONDS - PHASE_START))s"
  PHASE_START=$SECONDS
  mkdir -p "$WINDOWS_APP_DIR"
  echo "[launch] copying Windows artifacts to $WINDOWS_APP_DIR (log: $INSTALL_LOG)"
  for name in "$EXE_NAME" "$GUI_NAME" hollow-cli.exe hollow-cli.py; do
    copy_if_exists "$BIN_DIR/$name" "$WINDOWS_APP_DIR/$name"
  done
  if [[ $PDB -eq 1 ]]; then
    for name in "$PDB_NAME" "$GUI_PDB_NAME"; do
      copy_if_exists "$BIN_DIR/$name" "$WINDOWS_APP_DIR/$name"
    done
  fi
  mkdir -p "$WINDOWS_APP_DIR/cli/linux-x86_64" "$WINDOWS_APP_DIR/cli/linux-aarch64"
  for name in linux-x86_64/hollow-cli linux-aarch64/hollow-cli SHA256SUMS; do
    copy_if_exists "$SCRIPT_DIR/zig-out/cli/$name" "$WINDOWS_APP_DIR/cli/$name"
  done
  mkdir -p "$WINDOWS_APP_DIR/agents/linux-x86_64" "$WINDOWS_APP_DIR/agents/linux-aarch64"
  for name in linux-x86_64/hollow-agent linux-aarch64/hollow-agent SHA256SUMS; do
    copy_if_exists "$SCRIPT_DIR/zig-out/agents/$name" "$WINDOWS_APP_DIR/agents/$name"
  done
  # Keep on-disk Lua/config overrides available beside the relocated executable.
  mkdir -p "$WINDOWS_APP_DIR/src"
  cp -Ru --preserve=timestamps "$SCRIPT_DIR/src/lua" "$WINDOWS_APP_DIR/src/"
  cp -Ru --preserve=timestamps "$SCRIPT_DIR/conf" "$WINDOWS_APP_DIR/"
  echo "[launch] copying finished in $((SECONDS - PHASE_START))s"
  EXE_PATH="$WINDOWS_APP_DIR/$EXE_NAME"
  # Persistent sessions survive the restart.
  if [[ $CLOSE_STATUS -eq 0 ]]; then
    PHASE_START=$SECONDS
    windows_app Start "${RUN_ARGS[@]}"
    echo "[launch] restarted Hollow (launch request took $((SECONDS - PHASE_START))s)"
    exit 0
  fi
fi

if [[ $RUN -eq 1 ]]; then
  echo "[launch] running $EXE_PATH with args: ${RUN_ARGS[*]}"

  exec "$EXE_PATH" "${RUN_ARGS[@]}"
fi
