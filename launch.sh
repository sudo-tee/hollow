#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BIN_DIR="$SCRIPT_DIR/zig-out/bin"
EXE_NAME="hollow-native.exe"
EXE_PATH="$SCRIPT_DIR/$EXE_NAME"

TARGET="x86_64-windows-gnu"
BUILD=1
RUN=1
OPTIMIZE=""
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
	--debug) OPTIMIZE="Debug" ;;
	--safe-render) SAFE_RENDER=1 ;;
	--no-swapchain-glyphs) DISABLE_SWAPCHAIN_GLYPHS=1 ;;
	--no-multi-pane-cache) DISABLE_MULTI_PANE_CACHE=1 ;;
	--list-fonts) LIST_FONTS=1 ;;
	--json) LIST_FONTS_JSON=1 ;;
	--match-font) EXPECT_MATCH_FONT=1 ;;
	--app-arg=*) FORWARD_ARGS+=("${arg#--app-arg=}") ;;
	--help | -h)
		echo "Usage: $0 [--no-build] [--build-only] [--debug] [--safe-render] [--no-swapchain-glyphs] [--no-multi-pane-cache] [--list-fonts] [--match-font QUERY] [--json] [--app-arg=ARG]"
		exit 0
		;;
	esac
done

if [[ $EXPECT_MATCH_FONT -eq 1 ]]; then
	echo "[launch] --match-font requires a query" >&2
	exit 1
fi

if [[ $BUILD -eq 1 ]]; then
	echo "[launch] building Windows target"
	if [[ -n "$OPTIMIZE" ]]; then
		echo "[launch] optimize mode: $OPTIMIZE"
	fi
	# Default to temp caches to avoid WSL-on-/mnt/c rename failures.
	# Allow the user to override by setting ZIG_LOCAL_CACHE_DIR or ZIG_GLOBAL_CACHE_DIR.
	ZIG_LOCAL_CACHE_DIR=${ZIG_LOCAL_CACHE_DIR:-/tmp/hollow-zig-cache}
	ZIG_GLOBAL_CACHE_DIR=${ZIG_GLOBAL_CACHE_DIR:-/tmp/hollow-zig-global}
	echo "[launch] using ZIG_LOCAL_CACHE_DIR=$ZIG_LOCAL_CACHE_DIR ZIG_GLOBAL_CACHE_DIR=$ZIG_GLOBAL_CACHE_DIR"
	BUILD_ARGS=("-Dtarget=$TARGET")
	if [[ -n "$OPTIMIZE" ]]; then
		BUILD_ARGS+=("-Doptimize=$OPTIMIZE")
	fi
	zig build "${BUILD_ARGS[@]}" \
		--cache-dir "$ZIG_LOCAL_CACHE_DIR" \
		--global-cache-dir "$ZIG_GLOBAL_CACHE_DIR"
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

if [[ $RUN -eq 1 ]]; then
	copy_if_exists "$BIN_DIR/$EXE_NAME" "$EXE_PATH"

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
	echo "[launch] running $EXE_PATH"
	exec "$EXE_PATH" "${RUN_ARGS[@]}"
fi
