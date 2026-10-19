# Native Windows fs/exec dispatcher smoke

Base: `43063da`. Native **x86_64 Windows executable**, launched through WSL
interop, ran on Windows `10.0.26100.9445`. This is actual Windows process/API
execution, not a cross-compile or Linux client launching `wsl.exe`. No GUI, Lua,
PTY backend, production transport or operation changes.

`src/host_windows_test.zig` uses production HostManager, native-local workers,
typed operations and persistent subprocess transport. Three fresh process runs
pass **13/13** each: **39 executions including imports**, including **six**
Windows-specific integration executions (two cases per run).

## Coverage

* Native-local reports `os:windows`; reads SystemRoot directory, `cmd.exe` stat
  and `MZ` file bytes using native Windows filesystem APIs.
* Native `cmd.exe` produces exact separate CRLF stdout/stderr and exit 7, with
  explicit SystemRoot cwd to avoid UNC default-directory shell warnings.
* Native cancellation targets one directly owned `ping.exe` loopback process,
  not a shell plus an uncontained sleeping descendant. Reconnect changes native
  host generation and stale handles reject.
* Windows transport launches explicitly selected existing Ubuntu-26.04 and
  preinstalled Linux agent: info/list/stat/read, binary argv/env/stdout/stderr,
  NUL output and invalid UTF-8 bytes inside RPC work.
* Exact Linux non-UTF-8 path and binary content survive Windows dispatch. An
  owned mktemp file supplies an ASCII base; second file appends raw `0xff`.
  Read/stat validate six bytes `NUL 0xff DATA`. Cleanup removes only those two
  exact paths, never recursively removes user directories.
* In-flight EXEC cancellation, asynchronous close, failed pending ticket,
  explicit reconnect/new generation and subsequent HOST_INFO work. No request
  rebinding. This is not a side-effect replay or loaded fault-injection test.
* Imported protocol/admission/storage tests pass. Linux execution explicitly
  skips the two Windows cases and is not Windows qualification.

## Reproduce

Zig **0.16.0**, ReleaseSafe, no GUI/vendor/Lua dependencies:

```sh
zig test src/host_windows_test.zig -target x86_64-windows-gnu -lc \
  -OReleaseSafe --test-no-exec -femit-bin=/tmp/opencode/host-windows-test.exe

# From WSL: append to existing WSLENV, without /p path conversion.
HOLLOW_TEST_WSL_DISTRO=Ubuntu-26.04 \
HOLLOW_TEST_WSL_AGENT=/absolute/linux/path/hollow-agent \
WSLENV="${WSLENV:+$WSLENV:}HOLLOW_TEST_WSL_DISTRO:HOLLOW_TEST_WSL_AGENT" \
  /tmp/opencode/host-windows-test.exe
```

On native Windows, `zig test src/host_windows_test.zig -lc -OReleaseSafe` runs
native-local coverage. WSL case skips without explicit `HOLLOW_TEST_WSL_DISTRO`;
selected WSL requires `HOLLOW_TEST_WSL_AGENT`. Missing/unavailable selected target
fails, never falls back. Test neither creates distributions nor deploys agents.
Verify preinstalled target bytes first; arbitrary caller paths are not attested.
Measured target matches prior fs/exec ReleaseSafe artifact SHA. CI adds a native
Windows job; it does not configure a WSL target. Hosted execution is not claimed.

## Evidence and remaining scope

Adjacent `.json.gz` retains raw stdout/stderr/results, OS version, compiler command,
environment overrides, executable SHA, full test source and **177** unchanged base
source hashes. Adding archived test source to `43063da` reconstructs all **178**
identified sources. `.summary.json` retains counts/scope/exclusions.
Uncompressed archive SHA-256:
`8a5fa3dc0ce28cbce19fce0469c7c6d1f38d5f4157a372d6a304173156a97ceb`.
Frozen test executable SHA-256:
`d194b88e8097206c891a250c31d4167c95fc14f467efc9fe9d20f1d7ceadaa67`.

This closes **basic native Windows dispatcher/native-local/preinstalled-WSL smoke
execution**, not complete Windows support. Public Lua bootstrap, automatic bundle
discovery/deployment, Unicode native paths, runtime/GUI teardown, kernel-handle
growth, network faults, sustained loads, native Windows Podman/SSH/Docker clients,
ARM64 execution and PTY gates remain separate. Next Windows fs/exec work should
exercise public Lua bootstrap and release bundle on that native client, not PTY
benchmarks. No default backend, frame latency or resource-parity claim changes.
