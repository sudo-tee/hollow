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
FORWARD_ARGS=()

for arg in "$@"; do
  case "$arg" in
  --force-build) FORCE_BUILD=1 ;;
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

print_help() {
  echo "Usage: $0 [--force-build] [launch args]"
  echo ""
  echo "Auto-skips rebuilds for Lua/config-only edits and rebuilds when tracked Zig/C build inputs are newer than the built artifact."
  echo "Pass --force-build to bypass the heuristic."
  echo ""
  "$LAUNCH_SCRIPT" --help
}

artifact_path() {
  if [[ "$TARGET" == *"windows"* ]]; then
    printf '%s\n' "$SCRIPT_DIR/zig-out/bin/hollow-native.exe"
  else
    printf '%s\n' "$SCRIPT_DIR/zig-out/bin/hollow-native"
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
