# Fs/exec release checklist

Fs/exec is a separate deliverable from agent PTYs. Do not require PTY throughput,
focus/DRR, GUI frame latency or 40/100/200-PTY research to ship host filesystem
and noninteractive command operations. Existing native/WSL pane backends remain
unchanged. This checklist covers the public `hollow.host` API, shared agent
handlers, Lua bootstrap policy and read-only workspace integration.

## Release surface

* Native-local host plus Linux agent `info`, read-only `fs.stat/list/read`, and
  noninteractive `exec`; exact argv/env/cwd and binary output, structured errors,
  cancellation/deadlines, bounded captures and explicit reconnect generations.
* Podman, Docker, WSL and SSH bootstrap use the same agent/operation protocol.
  Connector establishment/deployment stays in Lua. No per-operation remote CLI
  spawn, implicit command replay or silent backend fallback.
* Executable-relative x86_64/aarch64 static musl bundle and strict SHA manifest;
  explicit artifact/preinstalled overrides, checksum validation and atomic install.
* Workspace discovery uses explicit `source.host`; `workspace.load_host` reads
  and validates bounded host files asynchronously. Local resolver aliases and
  synchronous `workspace.load` remain compatible. Arbitrary read-only project
  queries use `host:exec({argv=...,cwd=...})`, not per-environment handlers.
* Workspace export/write and automatic remote pane/bootstrap routing are **not**
  part of read-only fs/exec. Loading a remote document never executes it or chooses
  a pane backend. Native-local exec retains documented direct-child semantics;
  Linux agent guardians are not a native-local process-tree sandbox.

## One reproducible check command

Requires Zig **0.16.0**, Python 3, Lua 5.1-compatible headers/library/interpreter,
Busted and `sha256sum`. Optional profiles require real tools/targets. Command
creates a new report directory, retains every check's stdout/stderr and exact
argv/return code, and records source/artifact hashes. Experimental agent/test
environment overrides are cleared for fs/exec checks.

```sh
python3 scripts/agent_fs_exec_release.py --profile local podman ssh socket \
  --output /tmp/opencode/fs-exec-release
# Real Docker runner; no Podman CLI substitution qualifies this profile:
python3 scripts/agent_fs_exec_release.py --profile local docker \
  --output /tmp/opencode/fs-exec-docker
# Existing WSL distribution with an explicitly prepared conformance agent:
python3 scripts/agent_fs_exec_release.py --profile local wsl \
  --distro Ubuntu-26.04 --wsl-agent-path /opt/hollow-agent \
  --output /tmp/opencode/fs-exec-wsl
```

`--zig /path/to/zig`, `--lua lua`, and repeatable
`--build-option=-Dhost-lua-include=/headers` /
`--build-option=-Dhost-lua-object=/path/liblua.a` support non-system dependencies.
Plain Lua 5.1 works; some static LuaJIT builds require additional unwinder linkage.
Use matching headers/library. Tests do not require GUI dependencies or submodules.

Local checks always run: static bundles, native host tests, both installed bundle
layouts, Python unit suite, full Lua suite, checksums, common wire conformance and
SIGKILL/EOF descendant containment. Selected profiles additionally execute real
production bootstrap/native Lua, conformance and applicable containment/link-loss
checks. Podman/SSH/Docker fixtures own their containers; never point destructive
lifecycle tests at user-owned containers. WSL tests require explicit existing
distribution and can install only into selected user's versioned agent cache.

Every requested check must pass. Missing tools, unavailable fixture/daemon and
nonzero exit statuses fail; omitted profiles are recorded as **unverified**, not
passed. `checks_passed:true` means selected checks passed, not universal platform
approval. Source hashes identify the checked working tree, including uncommitted
files; source changes detected before completion fail the report. Do not edit
source during a qualification run. Historical failed attempts
remain evidence rather than being overwritten by a new successful report.

## Security and lifecycle review

* Trust bundle, native connector executables/configuration and selected target.
  SHA validates transferred bytes, not publisher authenticity or hostile targets.
* SSH must enforce verified host keys/noninteractive authentication, disable TTY
  and unintended forwarding/local commands, and use controlled SFTP deployment.
* Container selection pins immutable ID, preserves configured user, and never
  starts/removes user containers during normal connector bootstrap.
* Binary framing/size limits, byte-safe paths/argv, request/job admission, pending
  completion storage, connect/request/cancel watchdogs and owner teardown remain
  bounded. Broken streams fail in-flight work. Reconnect never replays EXEC.
* Deployment uses positional arguments for untrusted path bytes, versioned
  same-directory atomic install and explicit preinstalled trust override. Same-UID
  hostile cache races are not sandboxed. No automatic download/install of tools.
* Windows native strings use native WTF-8 semantics; Linux operation payloads are
  opaque bytes. Native Windows execution must be qualified on that client, not
  inferred from a cross-compile or Linux→Windows→WSL interop.

## Connector/platform support evidence

Release evidence is scoped to actual execution, not to all platforms supported by
the wire format. Linux x86_64 local/Podman, owned SSH fixture, mock socket and WSL
interop have current integration evidence; see [validation](host-agent-validation.md).

| Configuration | Fs/exec evidence | Release boundary |
| --- | --- | --- |
| Linux x86_64 native-local and local agent | Native operation/manager tests, 16 wire cases, local containment, both bundle layouts | Native-local direct-child cleanup is not agent guardian containment |
| Rootless Podman 5.7 / Alpine 3.21 | 19 wire/deployment cases, containment, production Lua bootstrap under UID 1000 in both layouts | No Windows Podman runtime claim |
| Owned non-root Alpine/OpenSSH fixture | 16 common wire cases, production bootstrap, strict authentication/host-key failure cases, both layouts | Controlled local network, not arbitrary WAN faults |
| Mock socket, 257-byte relay fragments | 16 common wire cases, production Lua, explicit loss/reconnect and no EXEC replay | Design fixture, not production vsock/hvsock |
| Linux→Windows launcher→Ubuntu-26.04 | 16 common wire cases, public WSL bootstrap/default and explicit user, both layouts | Explicit Windows-accessible artifact; not native Windows automatic discovery/client execution |
| Real Docker | Dedicated CI gate configured | Not executed locally: no Docker CLI/daemon available; no Podman substitution accepted |
| Native Windows client | Transport/manager/local/Lua cross-compile checks pass | Runtime qualification still required for that client |
| ARM64 | Static Linux-musl bundle/checksum | Cross-build only; runtime qualification still required |

Workspace host loading has seven focused Lua tests plus real >16 KiB paged reads
and oversized-document rejection through native host bindings and native-local
workers. The headless native harness uses an exact-document JSON bridge stub;
it tests real file bytes/pagination, not a new JSON parser or GUI execution.
Full Lua suite passes **442** cases and Python suite **80** cases, including
two guardian-wait regressions.

Initial local/Podman/SSH/socket release run passes all 11 requested checks. The
next source-integrity run adds WSL but fails **one local containment check**:
recorded workload was reaped while guardian still sampled `R`. This failure is
retained, not replaced with a passing result. The probe returned as soon as
workloads vanished, then sampled guardian once, without waiting for its permitted
exit deadline. The fix waits for **both** workload absence and guardian exit/Z
within the **same original** deadline; a still-live guardian or workload zombie
still fails. Two deterministic regressions cover delayed exit and deadline
exhaustion. **32/32** direct SIGKILL repeats pass with the corrected observer.
That does not recover the original guardian's exact exit latency or retroactively
make the failed run pass. No production agent/guardian implementation changed.

Closing source-integrity run passes **13/13** selected checks: local, Podman,
SSH, socket and WSL interop. All **177** source hashes remain unchanged and match
the implementation committed as `f2cc4a5`; run baseline revision was `e410fb0`.
Standalone native checks total **107 executions including imports**; both static
musl artifacts and their manifest verify. A separate direct Podman-native host
probe passes both installed layouts, exercising the same >16 KiB workspace load
code against a real remote agent as well as native-local workers.

Evidence: [`2026-10-19-fs-exec-release.json.gz`](../validation/2026-10-19-fs-exec-release.json.gz)
retains all three run reports/logs, containment records, environment/tool versions,
32 direct SIGKILL repeats and direct Podman-host logs. Adjacent `.summary.json`
lists selected/unverified scope and the preserved failure. `.patch.gz` reconstructs
all **177** closing source hashes on `e410fb0`; failed-run hashes also reconstruct
by retaining that revision's original fault probe and its unit test. Initial
preliminary run is historical; closing source-verified run is authoritative.
Source patch includes earlier resource/fault helpers exercised by common Python
unit tests; docs/CI changes are not part of the measured source patch.

Uncompressed archive SHA-256:
`02066b8ca1b9b07e457379c99a939dbbc0fe549b6607fca2f0ac68dec7bdf070`.
Uncompressed source patch SHA-256:
`b0131c298023ea81743218770fe646c6118c691705860c5300731ec932e79800`.

**Release decision:** fs/exec implementation/checklist is complete for the verified
Linux/interop scope above, independently of PTY rollout. This is not universal
client/platform approval. Real Docker, native Windows client and ARM64 execution
remain explicitly unverified; no PTY performance result blocks the verified
fs/exec scope. Installed local agent remains ReleaseSafe; native/WSL pane defaults
unchanged. No push, tag, release publication or hosted CI success is claimed.
The initial run preceded final argument/driver-test refinements; only the final
run is authoritative for final source hashes. Missing system LuaJIT dependencies
and a static LuaJIT unwind-link failure were resolved by explicitly selecting
matching Nix Lua 5.1 headers/static library, not by removing native Lua checks.

Real Docker requires its CI/native daemon job; that job now runs this independent
fs/exec checklist and uploads report/logs. A configured job is not proof it passed.
Native Windows WSL/SSH/Podman clients and ARM64 execution require their own runner
or controlled manual record; Linux-musl cross-builds do not qualify execution.

### Controlled WSL/native Windows manual record

Record commit/source hashes, build mode, client OS, launcher/SSH versions,
distro/user/architecture and artifact checksums. Exercise public connector
bootstrap with an installed bundle, then preinstalled override; verify info,
byte-safe list/read and argv/stdout/stderr, nonzero exit, cancel/timeout, close and
explicit reconnect. Check damaged cache/manifest rejection and ensure an in-flight
side-effecting EXEC is not replayed after transport loss. Record native-client
thread/handle cleanup across repeated connect/close and runtime teardown. Use an
owned target for loss/cache fixtures. Existing PTY panes must retain their backend.
Attach exact logs and failures; mark only that client/connector configuration
qualified. Do not substitute PTY benchmarks or claim GUI recovery from headless
tests. Real network disruption and OOM/security boundaries must remain explicit.
