#!/usr/bin/env bash
# setup.sh — one-shot project setup
#   1. init/update git submodules
#   2. apply local patches to submodules
#   3. fetch missing Windows DLLs (Windows / WSL only)
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$SCRIPT_DIR/.."
PATCHES_DIR="$ROOT/patches"
BUSTED_VERSION="${BUSTED_VERSION:-2.3.0}"

"$SCRIPT_DIR/check-zig-version.sh"

# ── 0. Lua test tooling ───────────────────────────────────────────────────────
if command -v busted >/dev/null 2>&1; then
  echo "[setup] Busted is already installed: $(busted --version)"
else
  if ! command -v luarocks >/dev/null 2>&1; then
    echo "[setup] LuaRocks is required to install Busted $BUSTED_VERSION" >&2
    echo "[setup] install LuaRocks, then rerun setup.sh" >&2
    exit 1
  fi

  echo "[setup] installing Busted $BUSTED_VERSION..."
  luarocks --lua-version=5.1 install busted "$BUSTED_VERSION"
fi

# ── 1. Submodules ────────────────────────────────────────────────────────────
echo "[setup] initialising submodules..."
git -C "$ROOT" submodule update --init --recursive

# ── 2. Patches ───────────────────────────────────────────────────────────────
apply_patch() {
  local submodule_path="$1" # relative to project root, e.g. third_party/sokol
  local patch_file="$2"     # absolute path to .patch file
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
apply_patch "third_party/sokol" "$PATCHES_DIR/sokol-image-region.patch"

# `third_party/lua-zluajit` tracks upstream `negrel/zluajit` but Hollow uses a
# local path dependency for `../luajit-upstream`, Windows cross-build support,
# and Zig 0.16 build API updates. Keep these as repo-level patches so the
# submodule flow matches the existing `sokol` model.
apply_patch "third_party/lua-zluajit" "$PATCHES_DIR/lua-zluajit-local.patch"
apply_patch "third_party/luajit-upstream" "$PATCHES_DIR/luajit-relver.patch"

# `third_party/nightwatch` tracks upstream `neurocyte/nightwatch` master but
# std.os.linux.inotify_add_watch returns usize; the libc errno()
# check in the library misses the negative-return encoding, so the subsequent
# @intCast(wd) panics on a watch failure. Patched locally until upstream ships
# a fix.
apply_patch "third_party/nightwatch" "$PATCHES_DIR/nightwatch-inotify-fix.patch"
