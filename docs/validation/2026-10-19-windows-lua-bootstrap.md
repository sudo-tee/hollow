# Native Windows public Lua WSL bootstrap

Base: `b4c30eb`. Actual Windows x86_64 headless test process on
`10.0.26100.9445`, using Lua **5.1.5 C API** and production native HostManager,
bindings, promises and `hollow.host.wsl`. No production implementation changes;
this does not exercise the application's LuaJIT engine, GUI or PTY lifecycle.

## Results

**Seven final processes pass**, each **12 passed, one expected skip**:
**84 passing executions including imports**, seven skips of the Linux-only case.
Six Windows-specific positive cases and one Windows missing-bundle negative case:

| Executable/bundle location | Processes | Result |
| --- | ---: | --- |
| UNC flat, `exe/agents` | 2 | Public bootstrap/cache reuse pass |
| UNC prefix/bin, `exe/../agents` | 2 | Public bootstrap/cache reuse pass |
| Windows `C:` flat, Unicode snowman in parent directory | 1 | Public bootstrap/cache reuse pass |
| Windows `C:` prefix/bin, Unicode snowman in parent directory | 1 | Public bootstrap/cache reuse pass |
| UNC directory with no adjacent bundle | 1 | Explicit `agent_install_unavailable`; no CWD search/fallback |

Positive cases automatically discover both bundled Linux architectures using
native executable directory; no artifact, agent_dir or agent_path override on
initial connect. Existing explicitly selected Ubuntu-26.04 runs with its default
user; no distribution creation or user change. Cases check Linux info, bounded
read/list, binary/quoted argv and NUL stdout, separate stderr/exit status, promise
cancellation, reconnect generation, explicit preinstalled mode and wrong checksum
rejection. Wrong-checksum upload exercises native path mapping/copy and rejects;
it is **not proof of a successful cold installation**. Existing valid SHA cache
was reused. No existing cache entry was corrupted or deleted for this test.

Linux `test-host-lua` and `test-host-lua-flat` also pass: each **12 passed, one
Windows-only skip**. Added test skips on Linux or without explicit WSL distro;
an explicitly selected unavailable distro fails rather than selecting a default.
`HOLLOW_TEST_EXPECT_NO_BUNDLE=1` selects only the missing-discovery assertion and
does not open WSL. Unset it for positive bootstrap qualification.

## Reproduce

Use Zig **0.16.0**, packaged `zig-out/agents` including original SHA256SUMS, and
an explicitly chosen existing WSL distro. Fetch Lua 5.1.5 source from
`https://www.lua.org/ftp/lua-5.1.5.tar.gz`; verify archive SHA-256
`2640fc56a795f29d28ef15e13c34a47e223960b0240e8cb0a82d9b0738695333`.

```sh
# From extracted lua-5.1.5/src; exclude the two CLI mains and luac printer.
sources=()
for file in *.c; do
  case "$file" in lua.c|luac.c|print.c) ;; *) sources+=("$file");; esac
done
zig build-lib -target x86_64-windows-gnu -lc -OReleaseSafe -I. \
  -femit-bin=/tmp/opencode/lua51-windows.a \
  -cflags -fno-sanitize=float-cast-overflow -- "${sources[@]}"

# From repository root; create output directory first.
mkdir -p /tmp/opencode/windows-lua/agents
zig test src/host_lua_test.zig -target x86_64-windows-gnu -lc -OReleaseSafe \
  -I/tmp/opencode/lua-5.1.5/src /tmp/opencode/lua51-windows.a \
  --test-no-exec -femit-bin=/tmp/opencode/windows-lua/host-lua.exe
cp -R zig-out/agents/. /tmp/opencode/windows-lua/agents/
HOLLOW_TEST_WSL_DISTRO=Ubuntu-26.04 \
WSLENV="${WSLENV:+$WSLENV:}HOLLOW_TEST_WSL_DISTRO" \
  /tmp/opencode/windows-lua/host-lua.exe
```

For prefix layout, place identical executable under `prefix/bin` and bundle under
`prefix/agents`, with no `bin/agents`. Windows drive layouts use same bytes under
an owned Windows temporary directory. Relative Lua module loading requires
repository root as process CWD, but bundle discovery remains executable-relative.
No automatic download/deploy of Lua is added to CI; existing Windows CI smoke
still covers dependency-free native-local operations, not this WSL test.

## Preserved failure and evidence

First external Lua library build trapped at `lua_number2int` in `luaH_get` while
parsing a module, before connector execution. Legacy Lua 5.1 probes numeric table
keys by casting floating values to int; C float-cast-overflow instrumentation
trapped there. Rebuilt **external test C library only** with
`-fno-sanitize=float-cast-overflow`; Zig and other C checks remain ReleaseSafe.
No dependency source or production code was patched. Failed raw log, executable
and library hashes remain archived; later passes do not reclassify that failure.

Adjacent `.json.gz` contains raw results, external Lua dependency hashes/build
commands, prior failed log, preliminary pass, Linux regression command/result,
Windows version, final binary hash and **178** repository source hashes.
`.patch.gz` reconstructs repository sources on `b4c30eb`; final test-source hash
was recorded before/after final matrix, other source identities checked against
base afterward. This is not another complete frozen-source fs/exec release run.
Uncompressed archive SHA-256:
`c4e6c7560d2aabd095e8c1fccc4126534f45822aa8780822a17428850e2c886a`.
Uncompressed source patch SHA-256:
`ccdc031c27499071bd5198a0532a511b1bd248f84e98ebd1cb0aefa195aa3793`.

Closed gap: **public Lua WSL cache-reuse bootstrap and executable-relative bundle
discovery** in measured Windows layouts. Still open: successful cold install/repair
under isolated cache/user, production LuaJIT engine, GUI teardown, broad Unicode
filesystem semantics, native Windows SSH/Podman/Docker, fault/resource matrix,
Docker daemon and ARM64 execution. PTY defaults/performance remain unchanged.
