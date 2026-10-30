#!/usr/bin/env bash
set -euo pipefail

shopt -s globstar nullglob

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
LAUNCH_SCRIPT="$SCRIPT_DIR/launch.sh"
TARGET="x86_64-windows-gnu"
FORCE_BUILD=0
USER_SET_NO_BUILD=0
BUILD_ONLY=0
SHOW_HELP=0
DEV=1
OPTIMIZE="ReleaseFast"
PDB=0
FORWARD_ARGS=()

for arg in "$@"; do
  case "$arg" in
  --force-build) FORCE_BUILD=1 ;;
  --release) DEV=0 ;;
  --dev) DEV=1 ;;
  --debug)
    DEV=0
    OPTIMIZE="Debug"
    FORWARD_ARGS+=("$arg")
    ;;
  --pdb)
    DEV=0
    PDB=1
    FORWARD_ARGS+=("$arg")
    ;;
  --install)
    DEV=0
    FORWARD_ARGS+=("$arg")
    ;;
  --no-build)
    USER_SET_NO_BUILD=1
    FORWARD_ARGS+=("$arg")
    ;;
  --build-only)
    BUILD_ONLY=1
    FORWARD_ARGS+=("$arg")
    ;;
  --target=*)
    TARGET="${arg#--target=}"
    FORWARD_ARGS+=("$arg")
    ;;
  --help | -h) SHOW_HELP=1 ;;
  *) FORWARD_ARGS+=("$arg") ;;
  esac
done

if [[ $DEV -eq 1 ]]; then
  FORWARD_ARGS=(--dev "${FORWARD_ARGS[@]}")
  BUILD_MODE="$TARGET dev"
else
  BUILD_MODE="$TARGET $OPTIMIZE pdb=$PDB"
fi

print_help() {
  echo "Usage: $0 [--force-build] [--release] [launch args]"
  echo ""
  echo "Auto-skips rebuilds for Lua/config-only edits and rebuilds when tracked Zig/C build inputs are newer than the built artifact."
  echo "Pass --force-build to bypass the heuristic."
  echo "Builds in dev mode (launch.sh --dev) by default. --release builds ReleaseFast; --debug, --pdb, and --install also leave dev mode."
  echo ""
  "$LAUNCH_SCRIPT" --help
}

artifact_path() {
  if [[ "$TARGET" == *"windows"* ]]; then
    printf '%s\n' "$SCRIPT_DIR/zig-out/bin/hollow-native.exe"
  else
    printf '%s\n' "$SCRIPT_DIR/zig-out/bin/hollow"
  fi
}

build_inputs() {
  printf '%s\n' \
    "$SCRIPT_DIR/build.zig" \
    "$SCRIPT_DIR/build.zig.zon" \
    "$SCRIPT_DIR"/assets/**/*.zig \
    "$SCRIPT_DIR"/src/**/*.zig \
    "$SCRIPT_DIR"/src/**/*.c \
    "$SCRIPT_DIR"/src/**/*.h \
    "$SCRIPT_DIR"/third_party/**/*.zig \
    "$SCRIPT_DIR"/third_party/**/*.c \
    "$SCRIPT_DIR"/third_party/**/*.h
}

needs_build() {
  local artifact
  artifact="$(artifact_path)"

  if [[ $FORCE_BUILD -eq 1 ]]; then
    return 0
  fi

  if [[ ! -f "$artifact" ]]; then
    return 0
  fi

  # Rebuild when switching between dev and release modes.
  if [[ "$(cat "$SCRIPT_DIR/zig-out/.launch-build-mode" 2>/dev/null)" != "$BUILD_MODE" ]]; then
    return 0
  fi

  while IFS= read -r path; do
    [[ -e "$path" ]] || continue
    if [[ "$path" -nt "$artifact" ]]; then
      return 0
    fi
  done < <(build_inputs)

  return 1
}

if [[ $SHOW_HELP -eq 1 ]]; then
  print_help
  exit 0
fi

if [[ $USER_SET_NO_BUILD -eq 1 ]]; then
  echo "[dev] user requested --no-build"
  exec "$LAUNCH_SCRIPT" "${FORWARD_ARGS[@]}"
fi

if needs_build; then
  echo "[dev] build required"
  exec "$LAUNCH_SCRIPT" "${FORWARD_ARGS[@]}"
fi

if [[ $BUILD_ONLY -eq 1 ]]; then
  echo "[dev] build artifacts already up to date"
  exit 0
fi

echo "[dev] skipping build; using on-disk Lua/config overrides"
exec "$LAUNCH_SCRIPT" --no-build "${FORWARD_ARGS[@]}"
