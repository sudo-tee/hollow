#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT
REPO="$TEST_DIR/repo"
export INSTALL_DEST="$TEST_DIR/Applications/Hollow"
export TEST_LOG="$TEST_DIR/calls"
mkdir -p "$REPO/scripts" "$REPO/zig-out/bin" "$REPO/src/lua/hollow/ui" "$REPO/conf" "$TEST_DIR/bin"
cp "$ROOT/launch.sh" "$REPO/launch.sh"
cp "$ROOT/scripts/check-zig-version.sh" "$ROOT/scripts/restart-hollow.ps1" "$REPO/scripts/"
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
printf '%s' "$4" | base64 -d | iconv -f UTF-16LE -t UTF-8 > "$TEST_LOG.ps"
grep -Fq "\$ProgressPreference = 'SilentlyContinue'" "$TEST_LOG.ps" || exit 1
if grep -Fq -- "-Action 'Close'" "$TEST_LOG.ps"; then
  echo close >> "$TEST_LOG"
  if [[ "${TEST_HUP:-0}" == 1 ]]; then kill -HUP "$PPID"; fi
  exit "${PS_STATUS:-3}"
fi
echo start >> "$TEST_LOG"
exit 0
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
printf 'native symbols\n' > "$REPO/zig-out/bin/hollow-native.pdb"
printf 'lua\n' > "$REPO/src/lua/init.lua"
printf 'return {}\n' > "$REPO/src/lua/hollow/app.lua"
printf 'return {}\n' > "$REPO/src/lua/hollow/ui/pane.lua"
printf 'config\n' > "$REPO/conf/init.lua"
mkdir -p "$REPO/zig-out/agents/linux-x86_64" "$REPO/zig-out/agents/linux-aarch64" "$REPO/zig-out/agents/windows-x86_64"
printf 'x86_64 agent\n' > "$REPO/zig-out/agents/linux-x86_64/hollow-agent"
printf 'aarch64 agent\n' > "$REPO/zig-out/agents/linux-aarch64/hollow-agent"
printf 'windows session owner\n' > "$REPO/zig-out/agents/windows-x86_64/hollow-agent.exe"
printf 'manifest\n' > "$REPO/zig-out/agents/SHA256SUMS"
mkdir -p "$REPO/zig-out/cli/linux-x86_64" "$REPO/zig-out/cli/linux-aarch64"
printf 'x86_64 cli\n' > "$REPO/zig-out/cli/linux-x86_64/hollow-cli"
printf 'aarch64 cli\n' > "$REPO/zig-out/cli/linux-aarch64/hollow-cli"
printf 'cli manifest\n' > "$REPO/zig-out/cli/SHA256SUMS"

# CI must build without running or invoking Windows tools.
bash "$REPO/launch.sh" --build-only
grep -q '^build build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast$' "$TEST_LOG"
printf 'app.lua\nui/pane.lua\n' > "$TEST_DIR/expected-lua-modules"
cmp "$TEST_DIR/expected-lua-modules" "$REPO/zig-out/.lua-modules"
! grep -Eq 'wslpath|^close$|^start$|^run ' "$TEST_LOG"
[[ ! -e "$INSTALL_DEST" ]]

# Debug and profiling builds retain their explicit build flags.
: > "$TEST_LOG"
bash "$REPO/launch.sh" --build-only --debug
grep -Fxq 'build build -Dtarget=x86_64-windows-gnu -Doptimize=Debug' "$TEST_LOG"
: > "$TEST_LOG"
bash "$REPO/launch.sh" --build-only --pdb
grep -Fxq 'build build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast -Dpdb' "$TEST_LOG"

# Dev builds apps plus their native helper, except when installing full bundles.
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
! grep -Eq 'wslpath|^close$|^start$|^build ' "$TEST_LOG"

# Installation remains possible without building or running.
: > "$TEST_LOG"
bash "$REPO/launch.sh" --install --no-build --build-only
for name in hollow.exe hollow-native.exe hollow-cli.exe; do
  cmp "$REPO/zig-out/bin/$name" "$INSTALL_DEST/$name"
done
[[ ! -e "$INSTALL_DEST/hollow-gui.exe" ]]
[[ ! -e "$INSTALL_DEST/hollow.pdb" && ! -e "$INSTALL_DEST/hollow-native.pdb" ]]
for name in SHA256SUMS linux-x86_64/hollow-cli linux-aarch64/hollow-cli; do
  cmp "$REPO/zig-out/cli/$name" "$INSTALL_DEST/cli/$name"
done
cmp "$REPO/src/lua/init.lua" "$INSTALL_DEST/src/lua/init.lua"
for name in app.lua ui/pane.lua; do
  cmp "$REPO/src/lua/hollow/$name" "$INSTALL_DEST/src/lua/hollow/$name"
done
cmp "$REPO/conf/init.lua" "$INSTALL_DEST/conf/init.lua"
for name in SHA256SUMS linux-x86_64/hollow-agent linux-aarch64/hollow-agent windows-x86_64/hollow-agent.exe; do
  cmp "$REPO/zig-out/agents/$name" "$INSTALL_DEST/agents/$name"
done
grep -Fxq close "$TEST_LOG"
! grep -Eq '^start$|^run |^build ' "$TEST_LOG"

# Symbols are copied only with --pdb, even when installing an existing build.
bash "$REPO/launch.sh" --install --no-build --build-only --pdb
for name in hollow.pdb hollow-native.pdb; do
  cmp "$REPO/zig-out/bin/$name" "$INSTALL_DEST/$name"
done
printf 'changed symbols\n' > "$REPO/zig-out/bin/hollow.pdb"
bash "$REPO/launch.sh" --install --no-build --build-only
grep -Fxq symbols "$INSTALL_DEST/hollow.pdb"

# Install-and-run uses the installed launcher; optional symbols may be absent.
rm "$REPO/zig-out/bin/hollow.pdb"
: > "$TEST_LOG"
bash "$REPO/launch.sh" --install --no-build --list-fonts --pdb
grep -Fxq "run $INSTALL_DEST/hollow.exe --list-fonts" "$TEST_LOG"

# A running installation is restarted by PowerShell, not launched again by Bash.
: > "$TEST_LOG"
PS_STATUS=0 bash "$REPO/launch.sh" --install --no-build --app-arg="it's here"
grep -Fq -- "-Action 'Start' -AppArgs @('it''s here')" "$TEST_LOG.ps"
grep -Fq "FilePath = \$dir + 'hollow-native.exe'" "$TEST_LOG.ps"
printf 'close\nstart\n' > "$TEST_DIR/expected-restart"
grep -E '^(close|start)$' "$TEST_LOG" > "$TEST_DIR/actual-restart"
cmp "$TEST_DIR/expected-restart" "$TEST_DIR/actual-restart"
! grep -q '^run ' "$TEST_LOG"

# Reinstall does not rewrite unchanged Lua/config files; edited files still copy.
touch -d '2020-01-01' "$REPO/src/lua/init.lua" "$INSTALL_DEST/src/lua/init.lua"
bash "$REPO/launch.sh" --install --no-build --build-only
[[ "$(stat -c %Y "$INSTALL_DEST/src/lua/init.lua")" == "$(stat -c %Y "$REPO/src/lua/init.lua")" ]]
printf 'edited lua\n' > "$REPO/src/lua/init.lua"
bash "$REPO/launch.sh" --install --no-build --build-only
cmp "$REPO/src/lua/init.lua" "$INSTALL_DEST/src/lua/init.lua"

# Restart still happens with --build-only and when closing hangs up the caller.
: > "$TEST_LOG"
PS_STATUS=0 TEST_HUP=1 bash "$REPO/launch.sh" --install --no-build --build-only
grep -Fxq start "$TEST_LOG"
! grep -q '^run ' "$TEST_LOG"

# Failure to close must leave all installed files untouched, without reopening.
printf 'updated native\n' > "$REPO/zig-out/bin/hollow-native.exe"
printf 'updated config\n' > "$REPO/conf/init.lua"
: > "$TEST_LOG"
if PS_STATUS=1 bash "$REPO/launch.sh" --install --no-build --build-only; then
  echo 'Expected restart timeout to fail' >&2
  exit 1
fi
[[ ! -e "$INSTALL_DEST/hollow-native.exe.new" ]]
grep -Fxq native "$INSTALL_DEST/hollow-native.exe"
grep -Fxq config "$INSTALL_DEST/conf/init.lua"
! grep -Eq '^start$|^run ' "$TEST_LOG"

# Reject incomplete bundles and unsupported targets.
mv "$REPO/zig-out/agents/windows-x86_64/hollow-agent.exe" "$TEST_DIR/saved-owner.exe"
: > "$TEST_LOG"
if bash "$REPO/launch.sh" --install --no-build --build-only; then
  echo 'Expected missing native session owner to fail before closing Hollow' >&2
  exit 1
fi
! grep -Eq '^close$|^start$|^run ' "$TEST_LOG"
mv "$TEST_DIR/saved-owner.exe" "$REPO/zig-out/agents/windows-x86_64/hollow-agent.exe"
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
