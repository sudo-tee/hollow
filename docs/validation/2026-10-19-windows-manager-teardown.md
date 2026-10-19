# Windows manager teardown with live WSL EXEC

Base: `6c170e5`. Headless Windows x86_64 test with vendored LuaJIT/JIT enabled,
owned HOME-isolating launcher, production manager and ReleaseSafe Linux agent.
No production implementation or PTY-default changes.

## Results

Six final Windows processes pass: three UNC flat repetitions, UNC prefix/bin,
Unicode C: flat and Unicode C: prefix/bin. **72 passing executions including
imports, six expected Linux-case skips**. Existing cold/deployment/fs/exec checks
still execute before live-work teardown.

Test starts shell that writes PID inside owned HOME, then execs `sleep 120`.
Concurrent EXEC witnesses workload, guardian and agent `/proc` identities before
manager destruction. Workload promise must remain pending. Manager `deinit()`
returns in **2.47–4.39 ms** in these finite samples (ceiling eight seconds).
Old promise rejects `session_gone`; fresh native-local manager serves HOST_INFO
while old promise remains rejected.

External Linux runner validates ancestry and PID/starttime identities, then
requires **all 18 identities disappear**. Same-identity zombies fail; reused PIDs
are not survivors. One shared **five-second deadline starts immediately after
Windows executable exits**, not at deinit entry. All identities absent at first
final observation; exact cleanup latency not established. Runner requires its
WSL distro match selected target, avoiding unrelated `/proc` namespaces.

Full Python suite passes **84** tests, including four new identity/parser cases:
spaces/parentheses in names, zombies, PID reuse and ancestry/duplicate rejection.
Both Linux Lua layouts pass 12 tests plus one Windows-only skip each. Raw output,
timeouts/failures and binary identities retained; output directories never reused.
Preliminary workload-only pass retained; final ancestry-aware matrix authoritative.

## Reproduce

Build/stage updated test and vendored LuaJIT as in
[engine checks](2026-10-19-windows-luajit-bootstrap.md), plus unchanged HOME
launcher from [cold-deploy checks](2026-10-19-windows-wsl-cold-deploy.md).
Run from Hollow root inside explicitly selected distro:

```sh
python3 scripts/agent_windows_teardown_tests.py \
  --exe /tmp/opencode/windows-lua-flat/host-luajit-teardown-final.exe \
  --fixture /tmp/opencode/host-wsl-home-fixture.exe \
  --distro Ubuntu-26.04 --runs 3 \
  --output /tmp/opencode/windows-teardown-new-report
```

Runner sets required-JIT/fixture/teardown selectors, clears inherited HOLLOW_TEST
selectors and creates fresh owned HOME per process. WSLENV names have no path
conversion. Observer never kills processes to manufacture success. Owned HOMEs
and pid files remain as evidence.

## Evidence and limits

Adjacent `.json.gz` retains six raw runs, live witnesses, post-run observations,
timings, dependency identities, preliminary output and full regression logs.
`.patch.gz` reconstructs **181 repository source identities** on `6c170e5`.
Sources verified afterward; executable/fixture hashes checked before/after each
batch. Not another complete frozen-source fs/exec release run.
Uncompressed archive SHA-256:
`3658e752f11ea05be05bfab11d57b9a338f0d1817c22f66391dfa97100abb897`.
Uncompressed patch SHA-256:
`bc8bab27bd65215acd883d4d185c927d2a8798386b2b872ccd704f1e5a7defe6`.

Qualifies finite **explicit manager deinit with running EXEC** under fixture,
not full application reload/GUI teardown or abrupt Windows crash. Lua state stays
alive deliberately for stale-callback checks; actual Runtime closes Lua and is
not exercised. Bootstrap-stage cancellation, upload cleanup at immediate teardown,
kernel-handle growth, arbitrary process trees, other Windows connectors, Docker
daemon, ARM64 and PTY performance/defaults remain outside this result.
