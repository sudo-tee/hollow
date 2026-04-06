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
FORWARD_ARGS=()

for arg in "$@"; do
	case "$arg" in
	--no-build) BUILD=0 ;;
	--build-only) RUN=0 ;;
	--debug) OPTIMIZE="Debug" ;;
	--safe-render) SAFE_RENDER=1 ;;
	--no-swapchain-glyphs) DISABLE_SWAPCHAIN_GLYPHS=1 ;;
	--no-multi-pane-cache) DISABLE_MULTI_PANE_CACHE=1 ;;
	--app-arg=*) FORWARD_ARGS+=("${arg#--app-arg=}") ;;
	--help | -h)
		echo "Usage: $0 [--no-build] [--build-only] [--debug] [--safe-render] [--no-swapchain-glyphs] [--no-multi-pane-cache] [--app-arg=ARG]"
		exit 0
		;;
	esac
done

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

copy_if_exists "$BIN_DIR/$EXE_NAME" "$EXE_PATH"
copy_if_exists "$BIN_DIR/ghostty-vt.dll" "$SCRIPT_DIR/ghostty-vt.dll"
copy_if_exists "$BIN_DIR/lua51.dll" "$SCRIPT_DIR/lua51.dll"
copy_if_exists "$SCRIPT_DIR/lua51.dll" "$BIN_DIR/lua51.dll"

for _dll in libfreetype-6.dll libharfbuzz-0.dll libgcc_s_seh-1.dll libstdc++-6.dll \
	libwinpthread-1.dll \
	libglib-2.0-0.dll libbrotlidec.dll libbrotlicommon.dll \
	libbz2-1.dll libpng16-16.dll zlib1.dll libpcre2-8-0.dll \
	libiconv-2.dll libintl-8.dll; do
	copy_if_exists "$BIN_DIR/$_dll" "$SCRIPT_DIR/$_dll"
done

if [[ ! -f "$SCRIPT_DIR/lua51.dll" ]]; then
	echo "[launch] warning: lua51.dll missing from project root"
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
	echo "[launch] running $EXE_PATH"
	exec "$EXE_PATH" "${RUN_ARGS[@]}"
fi
