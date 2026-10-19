# Windows fs/exec bootstrap with vendored LuaJIT

Base: `74fc1c3`. Actual Windows x86_64 processes on `10.0.26100.9445` use
Hollow's **current vendored LuaJIT sources and production library build settings**,
not standalone Lua 5.1. No production implementation/dependency edits.

## Results

Set `HOLLOW_TEST_REQUIRE_LUAJIT=1`. Test requires `jit.status()`, computes a known
sum with hotloop threshold 1, asserts `jit.util.traceinfo(1)` exists and prints
engine/OS/architecture. Threshold restored to 56 before host tests. Every final
process reports `LuaJIT 2.1.ROLLING x64 Windows compiled-trace`. Merely linking a
Lua-compatible interpreter cannot satisfy this gate: stock Lua 5.1 negative
control fails with `LuaJIT with enabled JIT required`, as expected.

**Six final Windows processes pass**, each **12 passed, one Linux-case skip**:
**72 passing executions including imports**, six expected skips.

* One direct System32 WSL public-bootstrap/cache-reuse regression.
* Four [isolated cold-install/repair](2026-10-19-windows-wsl-cold-deploy.md) layouts:
  UNC flat/prefix and Unicode C: flat/prefix. Fresh owned HOME lacks cache before
  each run. Final independent inspection finds only checksum-verified 0700 agent,
  no upload residue. Same HOME-isolating fixture and bounded async-cleanup drain;
  production WSL adapter/discovery/upload/checksum/rename logic unchanged.
* One missing-bundle rejection case, with no WSL connection.

Host cases cover typed info/read/list/exec, byte argv/NUL output, stderr/exit,
cancellation, reconnect, preinstalled mode, owned cache corruption/repair and
checksum rejection. Both Linux Lua release-layout regressions also pass, each
12 passed/one Windows-case skip. Historical failures remain in earlier archives;
the stock-Lua required-JIT failure here is an intentional negative control.

## Dependency/build identity

Snapshot copies of `third_party/lua-zluajit` and `third_party/luajit-upstream`
include their **pre-existing local modifications**. Original dirty submodules
remain untouched/uncommitted. Archive records dependency heads, binary git diffs
and **256** file hashes, rather than silently testing clean upstream revisions.
Reconstruction requires those recorded dependency heads plus patches, not merely
the superproject's gitlink revisions.

Build matches `build.zig` settings: `system=false`, `shared=false`,
`lua52-compat=false`, `llvm=true`, x86_64 Windows GNU, ReleaseSafe. Existing
dependency builder sets C sanitization off; this is not the earlier standalone
Lua library's narrow float-cast instrumentation adjustment. Zig remains ReleaseSafe.

Snapshot's `.relver` already contains `ROLLING`. Initial successful build warned
that git release metadata was unavailable; therefore banner is `2.1.ROLLING`,
not a dated release. Exact source/library hashes identify measured engine. No
upstream version/date or published release identity is inferred from banner.

```sh
# Use isolated copies beside each other; preserve dirty patches and hash inputs.
zig build --build-file /tmp/opencode/windows-luajit-production/lua-zluajit/build.zig \
  -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe \
  -Dsystem=false -Dshared=false -Dlua52-compat=false -Dllvm=true

# From Hollow root; stage packaged agents beside executable as in prior checks.
zig test src/host_lua_test.zig -target x86_64-windows-gnu -lc -OReleaseSafe \
  -I/tmp/opencode/windows-luajit-production/luajit-upstream/src \
  /tmp/opencode/windows-luajit-production/lua-zluajit/zig-out/lib/lua.lib \
  --test-no-exec -femit-bin=/tmp/opencode/windows-lua-flat/host-luajit.exe
HOLLOW_TEST_WSL_DISTRO=Ubuntu-26.04 HOLLOW_TEST_REQUIRE_LUAJIT=1 \
WSLENV="${WSLENV:+$WSLENV:}HOLLOW_TEST_WSL_DISTRO:HOLLOW_TEST_REQUIRE_LUAJIT" \
  /tmp/opencode/windows-lua-flat/host-luajit.exe
```

Cold cases additionally set fixture/HOME variables from prior instructions.
Missing case sets `HOLLOW_TEST_EXPECT_NO_BUNDLE=1` and has no adjacent bundle.

## Evidence and limits

Adjacent `.json.gz` retains raw output, dependency snapshots/patches, cached build
repeat, build commands, source/binary hashes, cold postchecks and negative control.
`.patch.gz` reconstructs **179 repository source identities** on `74fc1c3`.
Test source hash recorded before/after matrix; other repository/dependency sources
verified afterward. This is not another complete frozen-source fs/exec release run.
Uncompressed archive SHA-256:
`6e245a1a1ea33b17d3bd2573d5d51954a626938c1cbbf6ecda256e9d2a851588`.
Uncompressed source patch SHA-256:
`060d3ab4428eed115dfd9ffa08e01c87f6c26ff883475d2f06d9dc5fcd93a064`.

Closed gap: **headless production-vendored Windows LuaJIT engine** executes host
binding/bootstrap cases with JIT enabled. Harness still supplies a small C API
adapter and deferred callback pump; full application's zluajit wrapper/runtime,
launcher/GUI lifecycle and teardown are not exercised. Direct-launcher cold
deployment without fixture, bootstrap cancellation/process-tree faults, teardown
upload cleanup, other Windows connectors, Docker daemon and ARM64 remain open.
No hosted CI or PTY-default/performance claims follow.
