#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BIN_DIR="$SCRIPT_DIR/zig-out/bin"
EXE_NAME="hollow-native.exe"
EXE_PATH="$SCRIPT_DIR/$EXE_NAME"

TARGET="x86_64-windows-gnu"
BUILD=1
RUN=1

for arg in "$@"; do
	case "$arg" in
	--no-build) BUILD=0 ;;
	--build-only) RUN=0 ;;
	--help | -h)
		echo "Usage: $0 [--no-build] [--build-only]"
		exit 0
		;;
	esac
done

if [[ $BUILD -eq 1 ]]; then
	echo "[launch] building Windows target"
	# Default to temp caches to avoid WSL-on-/mnt/c rename failures.
	# Allow the user to override by setting ZIG_LOCAL_CACHE_DIR or ZIG_GLOBAL_CACHE_DIR.
	ZIG_LOCAL_CACHE_DIR=${ZIG_LOCAL_CACHE_DIR:-/tmp/hollow-zig-cache}
	ZIG_GLOBAL_CACHE_DIR=${ZIG_GLOBAL_CACHE_DIR:-/tmp/hollow-zig-global}
	echo "[launch] using ZIG_LOCAL_CACHE_DIR=$ZIG_LOCAL_CACHE_DIR ZIG_GLOBAL_CACHE_DIR=$ZIG_GLOBAL_CACHE_DIR"
	zig build -Dtarget="$TARGET" \
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
	echo "[launch] running $EXE_PATH"
	exec "$EXE_PATH"
fi
