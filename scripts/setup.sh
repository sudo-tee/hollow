#!/usr/bin/env bash
# setup.sh — one-shot project setup
#   1. init/update git submodules
#   2. apply local patches to submodules
#   3. fetch missing Windows DLLs (Windows / WSL only)
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$SCRIPT_DIR/.."
PATCHES_DIR="$ROOT/patches"

# ── 1. Submodules ────────────────────────────────────────────────────────────
echo "[setup] initialising submodules..."
git -C "$ROOT" submodule update --init --recursive

# ── 2. Patches ───────────────────────────────────────────────────────────────
apply_patch() {
    local submodule_path="$1"   # relative to project root, e.g. third_party/sokol
    local patch_file="$2"       # absolute path to .patch file
    local abs_path="$ROOT/$submodule_path"

    if [[ ! -f "$patch_file" ]]; then
        echo "[setup] patch not found: $patch_file" >&2
        return 1
    fi

    # Check if the patch is already applied (git apply --check exits 0 if it can
    # still be applied cleanly; non-zero means it's already in or conflicts).
    if git -C "$abs_path" apply --check "$patch_file" 2>/dev/null; then
        echo "[setup] applying patch: $(basename "$patch_file") → $submodule_path"
        git -C "$abs_path" apply "$patch_file"
    else
        # Verify it's actually already applied, not a conflict
        if git -C "$abs_path" apply --reverse --check "$patch_file" 2>/dev/null; then
            echo "[setup] patch already applied: $(basename "$patch_file")"
        else
            echo "[setup] WARNING: patch $(basename "$patch_file") does not apply cleanly to $submodule_path" >&2
            echo "[setup]   patch file:  $patch_file" >&2
            echo "[setup]   submodule may have drifted — check manually" >&2
        fi
    fi
}

apply_patch "third_party/sokol" "$PATCHES_DIR/sokol-no-vsync.patch"

# ── 3. Windows DLLs ──────────────────────────────────────────────────────────
is_windows_or_wsl() {
    case "$(uname -s)" in
        MINGW*|CYGWIN*|MSYS*) return 0 ;;
        Linux)
            # WSL exposes /proc/version with "Microsoft" or "WSL"
            grep -qi "microsoft\|wsl" /proc/version 2>/dev/null && return 0 ;;
    esac
    return 1
}

if is_windows_or_wsl; then
    echo "[setup] fetching Windows DLLs..."
    bash "$SCRIPT_DIR/fetch-windows-dlls.sh"
else
    echo "[setup] skipping DLL fetch (not Windows/WSL)"
fi

echo "[setup] done."
