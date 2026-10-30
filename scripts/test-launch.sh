#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT
REPO="$TEST_DIR/repo"
export INSTALL_DEST="$TEST_DIR/Applications/Hollow"
export TEST_LOG="$TEST_DIR/calls"
mkdir -p "$REPO/scripts" "$REPO/zig-out/bin" "$REPO/src/lua" "$REPO/conf" "$TEST_DIR/bin"
cp "$ROOT/launch.sh" "$REPO/launch.sh"
cp "$ROOT/scripts/check-zig-version.sh" "$REPO/scripts/"
cp "$ROOT/.tool-versions" "$REPO/"
export REQUIRED_ZIG="$(awk '$1 == "zig" { print $2 }' "$REPO/.tool-versions")"
cat > "$TEST_DIR/bin/zig" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == version ]]; then
  echo "$REQUIRED_ZIG"
else
  echo "build $*" >> "$TEST_LOG"
fi
EOF
cat > "$TEST_DIR/bin/wslpath" <<'EOF'
#!/usr/bin/env bash
echo wslpath >> "$TEST_LOG"
[[ "$1" == -u && "$2" == 'C:\Applications\Hollow' ]] || exit 1
echo "$INSTALL_DEST"
EOF
cat > "$TEST_DIR/bin/powershell.exe" <<'EOF'
#!/usr/bin/env bash
echo powershell >> "$TEST_LOG"
exit 1
EOF
cat > "$REPO/zig-out/bin/hollow.exe" <<'EOF'
#!/usr/bin/env bash
echo "run $0 $*" >> "$TEST_LOG"
EOF
chmod +x "$TEST_DIR/bin/"* "$REPO/zig-out/bin/hollow.exe"
export PATH="$TEST_DIR/bin:$PATH"
printf 'native\n' > "$REPO/zig-out/bin/hollow-native.exe"
printf 'cli\n' > "$REPO/zig-out/bin/hollow-cli.exe"
printf 'symbols\n' > "$REPO/zig-out/bin/hollow.pdb"
printf 'lua\n' > "$REPO/src/lua/init.lua"
printf 'config\n' > "$REPO/conf/init.lua"
mkdir -p "$REPO/zig-out/agents/linux-x86_64" "$REPO/zig-out/agents/linux-aarch64"
printf 'x86_64 agent\n' > "$REPO/zig-out/agents/linux-x86_64/hollow-agent"
printf 'aarch64 agent\n' > "$REPO/zig-out/agents/linux-aarch64/hollow-agent"
printf 'manifest\n' > "$REPO/zig-out/agents/SHA256SUMS"
mkdir -p "$REPO/zig-out/cli/linux-x86_64" "$REPO/zig-out/cli/linux-aarch64"
printf 'x86_64 cli\n' > "$REPO/zig-out/cli/linux-x86_64/hollow-cli"
printf 'aarch64 cli\n' > "$REPO/zig-out/cli/linux-aarch64/hollow-cli"
printf 'cli manifest\n' > "$REPO/zig-out/cli/SHA256SUMS"

# CI must build without running or invoking Windows tools.
bash "$REPO/launch.sh" --build-only
grep -q '^build build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast$' "$TEST_LOG"
! grep -Eq 'wslpath|powershell|^run ' "$TEST_LOG"
[[ ! -e "$INSTALL_DEST" ]]

# Debug and profiling builds retain their explicit build flags.
: > "$TEST_LOG"
bash "$REPO/launch.sh" --build-only --debug
grep -Fxq 'build build -Dtarget=x86_64-windows-gnu -Doptimize=Debug' "$TEST_LOG"
: > "$TEST_LOG"
bash "$REPO/launch.sh" --build-only --pdb
grep -Fxq 'build build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast -Dpdb' "$TEST_LOG"

# Dev builds only the app executables, except when installing full bundles.
: > "$TEST_LOG"
bash "$REPO/launch.sh" --build-only --dev
grep -Fxq 'build build gui -Dtarget=x86_64-windows-gnu -Ddev' "$TEST_LOG"
grep -Fxq 'x86_64-windows-gnu dev' "$REPO/zig-out/.launch-build-mode"
: > "$TEST_LOG"
bash "$REPO/launch.sh" --build-only --dev --install
grep -Fxq 'build build -Dtarget=x86_64-windows-gnu -Ddev' "$TEST_LOG"
rm -rf "$INSTALL_DEST"
: > "$TEST_LOG"
bash "$REPO/launch.sh" --build-only --dev --pdb
grep -Fxq 'build build gui -Dtarget=x86_64-windows-gnu -Ddev -Dpdb' "$TEST_LOG"

# Normal development launches directly from zig-out/bin and forwards arguments.
: > "$TEST_LOG"
bash "$REPO/launch.sh" --no-build --app-arg='hello world'
grep -Fxq "run $REPO/zig-out/bin/hollow.exe hello world" "$TEST_LOG"
! grep -Eq 'wslpath|powershell|^build ' "$TEST_LOG"

# Installation remains possible without building or running.
: > "$TEST_LOG"
bash "$REPO/launch.sh" --install --no-build --build-only
for name in hollow.exe hollow-native.exe hollow-cli.exe hollow.pdb; do
  cmp "$REPO/zig-out/bin/$name" "$INSTALL_DEST/$name"
done
[[ ! -e "$INSTALL_DEST/hollow-gui.exe" ]]
for name in SHA256SUMS linux-x86_64/hollow-cli linux-aarch64/hollow-cli; do
  cmp "$REPO/zig-out/cli/$name" "$INSTALL_DEST/cli/$name"
done
cmp "$REPO/src/lua/init.lua" "$INSTALL_DEST/src/lua/init.lua"
cmp "$REPO/conf/init.lua" "$INSTALL_DEST/conf/init.lua"
for name in SHA256SUMS linux-x86_64/hollow-agent linux-aarch64/hollow-agent; do
  cmp "$REPO/zig-out/agents/$name" "$INSTALL_DEST/agents/$name"
done
! grep -Eq 'powershell|^run |^build ' "$TEST_LOG"

# Install-and-run uses the installed launcher; optional symbols may be absent.
rm "$REPO/zig-out/bin/hollow.pdb"
: > "$TEST_LOG"
bash "$REPO/launch.sh" --install --no-build --list-fonts
grep -Fxq "run $INSTALL_DEST/hollow.exe --list-fonts" "$TEST_LOG"

# Reject incomplete bundles and unsupported targets.
rm "$REPO/zig-out/bin/hollow-native.exe"
if bash "$REPO/launch.sh" --install --no-build --build-only; then
  echo 'Expected incomplete installation to fail' >&2
  exit 1
fi
if bash "$REPO/launch.sh" --install --no-build --target=x86_64-linux-gnu; then
  echo 'Expected non-Windows installation to fail' >&2
  exit 1
fi
echo '[test-launch] all checks passed'
