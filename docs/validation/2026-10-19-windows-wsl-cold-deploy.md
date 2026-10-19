# Windows WSL cold deployment and repair — isolated HOME fixture

Base: `5733770`. Windows x86_64 executable, Windows `10.0.26100.9445`, existing
Ubuntu-26.04/default user. Headless Lua 5.1.5 C API; production host bindings,
bootstrap, discovery, WSL adapter and Linux agent. No production code changes.

## Fixture boundary

`src/host_wsl_home_fixture.zig` is a **test-only Windows launcher**, not shipped or
selected by production defaults. `HOLLOW_TEST_WSL_FIXTURE` opts test into using it
as public `hollow.host.wsl`'s configurable executable. It forwards connector argv
to actual System32 `wsl.exe`, inserting `/usr/bin/env HOME=<owned directory>`
after `--exec`. Stdio is inherited unchanged; wrapper does not parse RPC, emulate
WSL commands or replace upload/checksum/rename logic.

Each case creates a fresh `mktemp -d /tmp/hollow-wsl-home-XXXXXXXXXXXX`. Both test
and launcher validate exact prefix plus 12 alphanumeric suffix characters.
Three invalid-invocation checks reject outside/traversal HOME values and missing
`--exec`. Fixture does not authenticate arbitrary caller-selected directories;
runner establishes ownership/freshness. No distro creation, user/default change,
prior cache corruption or recursive deletion. Owned directories remain for evidence.

## Results

Four cold layouts pass: **UNC flat**, **UNC prefix/bin**, **C: Unicode flat** and
**C: Unicode prefix/bin**. Runner verifies no `.cache` before launch. Public Lua
automatically discovers bundled artifacts without agent/artifact overrides.
Cases exercise cold copy/checksum/atomic install, info/read/list/exec, cancellation,
reconnect/cache reuse and explicit preinstalled mode. Then test corrupts **only
the installed target inside validated fixture HOME** via replacement, reconnects
through normal deployment and verifies repair. Wrong-checksum install rejects.

Final inspection of each HOME finds exactly one regular file: expected
content-addressed agent, SHA-256
`82ca8fde34ce8703ba735703c036c2e71fa85902928edafdc63f2c736380c09c`, mode **0700**.
No `.upload-*`, `.bad` or wrong-checksum target remains. Empty cache directories
are allowed. Installed bytes match packaged ReleaseSafe artifact.

Each process: **12 passed, one expected Linux-case skip**. One additional direct
System32 WSL run without fixture passes same counts: **five final Windows
processes, 60 passing executions including imports, five skips**. Direct run
still reuses default user's cache; it is not direct-launcher cold-install proof.
Both Linux Lua release-layout regressions pass **12 + one Windows-case skip**.
No hosted CI execution is claimed.

## Preserved post-run cleanup failure

First isolated run's Zig assertions passed, but immediate runtime teardown after
checksum rejection interrupted best-effort asynchronous upload cleanup. Post-run
inspection found an owned `.upload-*` file, mode 0600, containing agent bytes in
the all-zero digest directory. This remains a **failed post-run cleanup validation**,
not a retroactive pass. Initial raw log, binary hash, HOME and residue listing are
archived. Existing user caches were not touched.

Final harness keeps runtime alive and waits boundedly for that cleanup: remote
shell observes absence of upload files for up to 100 sleeps of 50 ms, with an
8-second operation timeout. It does not remove residue itself. Production cleanup
still remains best effort; immediate application teardown is not now guaranteed
to clean uploads. No runtime deadline or cleanup semantics were changed.

## Reproduce

Use previous [Lua dependency/build instructions](2026-10-19-windows-lua-bootstrap.md),
Zig 0.16.0 and same packaged bundle. Compile final test source to flat or prefix
release layout as before. Build launcher separately:

```sh
zig build-exe src/host_wsl_home_fixture.zig -target x86_64-windows-gnu -lc \
  -OReleaseSafe -femit-bin=/tmp/opencode/host-wsl-home-fixture.exe

home=$(mktemp -d /tmp/hollow-wsl-home-XXXXXXXXXXXX)
test ! -e "$home/.cache"
HOLLOW_TEST_WSL_DISTRO=Ubuntu-26.04 \
HOLLOW_TEST_WSL_HOME="$home" \
HOLLOW_TEST_WSL_FIXTURE="$(wslpath -w /tmp/opencode/host-wsl-home-fixture.exe)" \
WSLENV="${WSLENV:+$WSLENV:}HOLLOW_TEST_WSL_DISTRO:HOLLOW_TEST_WSL_HOME:HOLLOW_TEST_WSL_FIXTURE" \
  /tmp/opencode/windows-lua/host-lua.exe

# Independently inspect owned HOME afterward; never inspect/delete default cache.
find "$home" -type f -print
```

Run from repository root for Lua module loading. Do not set
`HOLLOW_TEST_EXPECT_NO_BUNDLE` for cold cases. Verify installed checksum/mode and
absence of stray files in addition to process success. Fresh HOME per layout is
essential; rerunning same HOME does not establish cold-install behavior.

## Evidence and exclusions

Adjacent `.json.gz` retains raw final/preliminary output, post-run file identities,
source/dependency/binary hashes, build commands and Linux regression output.
`.patch.gz` reconstructs **179 repository source identities** on `5733770`.
Final test/fixture source hashes recorded before/after matrix; other sources
verified against base afterward, not another complete fs/exec release-gate run.
Uncompressed archive SHA-256:
`9e12440d4d97550ec1a3b08054587467f4deaf386f2b0bba8d9b3c23b12cb725`.
Uncompressed source patch SHA-256:
`c08dfbfa2cd387b21c92e22eac0af957c65b3b2ba523fd55a40f716574bd4039`.

Qualification applies to **public Windows bootstrap cold deployment/repair under
explicit HOME-isolating test launcher**, not unmodified direct-launcher cold
deployment, production LuaJIT/GUI, teardown cleanup, bootstrap cancellation,
wrapper/process/job-tree faults or broad resource/fault/platform support.
Windows SSH/Podman/Docker, real Docker daemon and ARM64 execution remain open.
PTY defaults and performance qualification unchanged.
