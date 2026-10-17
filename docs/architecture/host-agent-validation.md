# Agent foundation validation — 2026-10-17

This records local execution, not hosted CI results or completion of the v4
plan. Environment: x86_64 Linux under WSL2, Zig 0.16.0, rootless Podman 5.7.0,
`docker.io/library/alpine:3.21`. No Windows GUI qualification ran. SSH validation
uses an owned non-root Alpine/OpenSSH fixture, not a production server.

| Check | Result |
|---|---|
| Static Linux musl x86_64 and aarch64 builds | Pass; `file` confirms static ELF |
| Protocol / filesystem native tests | 5 / 3 pass |
| Python harness / deployment / fault-safety / manifest / WSL / SSH unit tests | 32 pass |
| Persistent native transport integration / imported protocol tests | 5 / 5 pass |
| Windows x86_64 GNU transport cross-compile | Pass; compile only, no Windows execution |
| Local SIGKILL / EOF descendant containment | 6 pass |
| Rootless Podman SIGKILL / EOF descendant containment | 6 pass |
| Typed request/result tests | Pass; byte encoding, owned results, invalid metadata and allocation failure |
| HostManager tests | 4 real-agent integration + 1 handle validation pass (10 with imported protocol tests) |
| Native Lua host promises through local / rootless Podman | Pass, same headless integration test; local Lua 5.1 API |
| Complete Lua suite | 403 pass under Lua 5.1; SSH bootstrap adds 19 cases to previous 384 |
| Native-local operations | 6 pass; byte paths/argv/env, pagination, symlink stat/read, direct-child cancellation/deadlines and combined output cap |
| Native-local manager | 3 integration tests pass (10 including imports); shared dispatch, reconnect isolation and retained-request bounds |
| Production Lua Podman bootstrap | Pass through native bindings: deployment, reuse, corrupt-cache repair, preinstalled path and checksum rejection |
| Production bootstrap configured UID/GID 1000:1000 | Pass; `id -u` confirms 1000, no connector root override |
| Executable-relative agent bundle discovery | Pass through native Lua from installed prefix/bin and flat-release test layouts |
| Production Podman bootstrap with automatic discovery | Pass; prefix/bin UID 1000 and flat-release default-user fixture, no explicit artifact map |
| HostManager and native Lua adapter Windows compile checks | Pass; no runtime execution |
| Full Windows GUI cross-build | Blocked by two generated FreeType binding unused-constant errors; not a passing app build |
| Local-subprocess conformance | 16 pass |
| Rootless Podman conformance | 19 pass |
| Podman configured UID/GID 1000, fs/exec subset | 2 pass; no root override |
| SHA256SUMS verification for both artifacts | Pass |
| Isolated build without GUI sources, submodules or vendor tree | Pass |
| ARM64 execution | Not verified; cross-build only |
| WSL launcher conformance through Windows interop from Linux | 16 pass against existing Ubuntu-26.04, preinstalled agent |
| Production Lua WSL bootstrap through Windows interop from Linux | Pass; Windows UNC artifact, default/explicit user, binary RPCs, cancellation, reuse and preinstalled path |
| Production Lua SSH bootstrap | Pass; strict verified non-root deployment, reuse, preinstalled path, checksum rejection and authentication/host-key failures |
| SSH common fs/exec conformance | 16 pass against owned Alpine/OpenSSH fixture |
| Native Windows WSL/SSH client / GUI latency, Docker | Not verified |

Reproduction:

```sh
zig build --build-file build-agent.zig -Doptimize=ReleaseSafe agent agent-all test-agent test-agent-fs
zig build --build-file build-agent.zig -Doptimize=ReleaseSafe test-host-transport test-host-local
zig test src/host_transport.zig -target x86_64-windows-gnu -lc -fno-emit-bin
python3 -m unittest discover -s scripts/tests -v
python3 scripts/agent_conformance.py --connector local-subprocess --agent zig-out/bin/hollow-agent
python3 scripts/agent_conformance.py --connector podman --agent zig-out/bin/hollow-agent --image docker.io/library/alpine:3.21
python3 scripts/agent_fault_probe.py --agent zig-out/bin/hollow-agent --output agent-faults-local.json
python3 scripts/agent_fault_probe.py --connector podman --agent zig-out/bin/hollow-agent --output agent-faults-podman.json
(cd zig-out/agents && sha256sum -c SHA256SUMS)
```

The Podman suite additionally corrupts a cached pathname while the original
agent is live, verifies reinstall, restarts the container and recreates it.
Those destructive fixtures run **only** on containers created by this harness,
never with `--container` pointing to a user's existing container.

## Legacy benchmark harness checks

Local Linux legacy-helper runs exercised five independent processes with 5,000
echo samples each, and five 10 MiB output-only runs with verified byte counts
and SHA-256. Raw JSONL from this session:

* `/tmp/opencode/hollow-local-prompt-full.jsonl`
* `/tmp/opencode/hollow-local-output-10mib.jsonl`

These temporary artifacts are harness sanity checks, **not qualified WSL
baselines**. They used a Linux client, and some other validation ran concurrently.
Do not use these values to pass PTY rollout gates. The harness's readiness
measurement includes shell/echo-program startup; it is not yet a real-shell
warm first-prompt benchmark. Re-run matched Windows/WSL workloads, record build
flags and machine/load metadata, and preserve datasets before PTY changes.

## Crash-containment regression and current gate

A local SIGKILL probe verified that a direct `sleep` child dies when the agent
is killed, and its in-flight request fails. A shell's background `sleep`
grandchild **survived** agent SIGKILL until explicit test cleanup. Raw probe
result: `/tmp/opencode/hollow-agent-crash-probe.json`.

The direct-child-only implementation was replaced with an unprivileged per-EXEC
guardian. It survives RPC-agent death, subreaps adopted descendants, terminates
the workload group and adopted children, and waits for `ECHILD` before exit.
Guardians close inherited RPC/other-job descriptors. `HOST_INFO` now includes
`agent_pid` and `exec_supervised` for diagnostics and owned fault injection.

The repeatable gate now passes all six scenarios locally and through rootless
Podman: direct child, TERM-resistant grandchildren, and detached double-fork
descendants, each after agent SIGKILL and transport EOF. Workloads must disappear
from `/proc`; zombies are not a passing workload result. Guardian reaping by the
environment's parent/init is reported separately. Both tested environments
reaped guardians too. Current raw local result:

```sh
python3 scripts/agent_fault_probe.py --agent zig-out/bin/hollow-agent --workdir /tmp/opencode --output /tmp/opencode/hollow-agent-crash-probe-v2.json
python3 scripts/agent_fault_probe.py --connector podman --agent zig-out/bin/hollow-agent --output /tmp/opencode/hollow-agent-podman-faults.json
```

These gates cover ordinary descendants, not malicious workloads that kill their
guardian, simultaneous OOM-kill of guardian and agent, UID privilege changes,
fork bombs, or uninterruptible kernel waits. Guardians are lifecycle helpers, not
a security sandbox or cgroup resource controller. Hang/OOM and immediate-spawn
race stress remain unqualified. A Podman conformance run hit a 120-second tool
deadline; a rerun with a 300-second allowance passed 19/19 in 123 seconds.

## Persistent native transport slice

`src/host/transport.zig` launches one subprocess asynchronously and keeps binary
pipes open. Reader, writer and watchdog tasks run away from the owner thread.
It negotiates HELLO, correlates requests and even streams, bounds slots/queues
and captures, and uses tombstones for timed-out requests until their terminal
reply or disconnect. Each owner completion carries a fresh generation; ambiguous
EXECs are never replayed. Tests execute concurrent HOST_INFO/EXEC, filesystem
read/error, cancellation, deadline, 1 MiB binary output, slot exhaustion,
shutdown, reconnect nonce/generation and agent SIGKILL. Cross-compilation checks
the same implementation for Windows; it does not prove runtime pipe behavior.

## HostManager and Lua slice

`src/host/manager.zig` owns at most eight registered native-local/agent hosts and 64 retained
requests. Stable caller-provided host IDs are separate from fresh connection
generations. Old-generation terminal results remain consumable after explicit
reconnect, while stale handles/tickets cannot submit or cancel new work. No EXEC
is replayed. Typed adapters preserve raw byte paths/argv/environment and copy
decoded result bytes into an owned arena. Lua callbacks receive no borrowed
transport memory. The manager is lazy and owned by `Runtime`; shutdown/reload
destroys it before closing Lua. Current Lua API is explicitly experimental; it
does not silently route existing local or workspace operations remotely.

Headless end-to-end tests run Lua promises through the actual native bindings,
HostManager, persistent pipes and agent, both locally and with the same launch
argv contract through rootless Podman. These use installed plain Lua 5.1 locally,
not a claim of LuaJIT/Windows runtime qualification. CI is configured to use
LuaJIT. Optional include/library overrides for local reproduction:

```sh
zig build --build-file build-agent.zig test-host-lua \
  -Dhost-lua-include=/path/to/lua51/include \
  -Dhost-lua-object=/path/to/liblua.a
python3 scripts/agent_host_tests.py --connector podman --agent zig-out/bin/hollow-agent -- \
  zig build --build-file build-agent.zig test-host-lua \
  -Dhost-lua-include=/path/to/lua51/include -Dhost-lua-object=/path/to/liblua.a
LUA=lua bash scripts/test-lua.sh
```

Full Windows GUI cross-build reached 74/77 steps but failed on generated
`ft_bindings.zig` unused `extern_local_wcscat_s` and `extern_local_wcscpy_s`
constants. No vendor or pre-existing submodule changes were overwritten to work
around this. GUI-free HostManager and native Lua adapter cross-compiles pass.

## Native-local and host workspace continuation

`hollow.host.local_host()` uses native OS fs/process operations, never a Linux
agent. Requests own copied inputs and arena-backed results; each local host has
16 retained slots. Cancellation is an owner-thread atomic flag; worker-side
watchdogs cancel and join work before publishing results. Tests cover direct
children, not arbitrary descendants. Shutdown may join workers; no claim covers
uninterruptible filesystem/kernel waits. Reads check file kind before opening
and again on the opened handle. A concurrent pathname swap can still reach a
FIFO/device during portable native open; this is not a sandbox or a proven
nonblocking-open guarantee. Windows runtime behavior remains unqualified.

The same headless Lua test now also exercises native-local info/stat/exec,
cancellation, cached connections and generation changes. Native-local job,
manager and Lua adapter tests cross-compile for Windows, without execution.

Workspace sources may opt into a ready `source.host`. Discovery uses bounded,
asynchronous list/stat requests, byte-preserving identities, TTL caches,
cancellation on reconfigure and generation changes, and live picker revision
updates. Fifteen tests exercise pagination, concurrent stat bounds, per-source
and cross-host isolation, stale callbacks, malformed promises, errors, refresh,
and byte names. Legacy resolver discovery and workspace opening stay unchanged;
host-backed discovery alone does not select a remote PTY/session domain.

The full v4 matrix (including allocation-failure fuzzing, read-only/noexec
deployments and all portability runners) is still incomplete. Native Windows WSL
qualification, SSH network-fault coverage,
broader read-only query migration and native
Windows qualification remain incomplete; all PTY extraction/multiplexing
milestones remain unimplemented.

## Production Podman bootstrap continuation

`hollow.host.podman(opts)` confines Podman-specific discovery/deployment to Lua.
It takes a selected existing container and trusted architecture-keyed artifacts
with expected SHA-256 values, or an absolute preinstalled agent path. Bootstrap
uses asynchronous native-local exec; subsequent fs/exec requests use the existing
persistent `podman exec -i` transport. Names are resolved to immutable container
IDs before remote commands, never followed across replacement. There is no
container creation/removal, user override, dependency installation or PTY change
in production connector code.

Twenty Lua tests cover validation, options ownership, aliases, pinned IDs,
cache/deployment/error paths, positional shell data, byte-preserving HOME,
deadline/cancellation, upload cleanup after draining, and late-host closure. The
shared host suite also tests connection cancellation and bootstrap admission caps.
Cleanup is bounded best effort; CLI cancellation is not a transaction rollback,
and cannot guarantee removing a temporary name whose creation result was lost.

Real rootless Alpine tests execute the production connector itself (Python only
owns the disposable fixture), including repair of an already-running agent's
replaced pathname and rejection of a wrong expected digest. Both the image's
default user and configured UID/GID 1000:1000 pass; `id -u` verifies effective UID.
These do not qualify native Windows Podman/WSL/SSH runtime behavior or other distributions.

```sh
python3 scripts/agent_host_tests.py --connector podman-bootstrap --agent zig-out/bin/hollow-agent -- \
  zig build --build-file build-agent.zig test-host-lua \
  -Dhost-lua-include=/path/to/lua51/include -Dhost-lua-object=/path/to/liblua.a
python3 scripts/agent_host_tests.py --connector podman-bootstrap --container-user 1000:1000 \
  --agent zig-out/bin/hollow-agent -- zig build --build-file build-agent.zig test-host-lua \
  -Dhost-lua-include=/path/to/lua51/include -Dhost-lua-object=/path/to/liblua.a
```

## Experimental WSL fs/exec connector continuation

`hollow.host.wsl({id, distro, user?})` uses the same host API, agent and shared
bootstrap engine as Podman. The adapter selects an explicit existing distro and
optional user, converts Windows artifact paths using `wslpath -a -u`, copies with
`cp --`, and opens one `wsl.exe --distribution ... --cd / --exec <agent> stdio`
transport. Missing user preserves the distro's default; no implied root or
distribution import/install/termination is added. Deployment's SHA verification,
atomic rename, deadlines, cancellation and best-effort owned-temp cleanup remain
common policy. Podman's configured-UID integration still passes after extraction.

Fourteen Lua cases cover exact argument boundaries, user defaults/overrides,
configuration ownership, architecture aliases, preinstalled/reused artifacts,
path conversion and malformed output, copy/checksum failures, cleanup ordering,
native errors, cancellation/deadlines, late host closure, and bundle discovery.
Five Python tests cover a preinstalled-only WSL conformance connector; Python
does not implement a second deployment path. Lua mocks do not qualify native
Windows argument encoding or path conversion behavior.

Actual `wsl.exe` was available through Windows interop. The same 16 fs/exec/wire
conformance tests pass against existing `Ubuntu-26.04`, using an already-built
agent and only harness-owned random temporary workload directories. This covers
byte paths, symlinks, pagination, binary output, concurrent RPCs, malformed
framing, cancellation, timeout/group cleanup, EOF/reconnect and fresh nonces.
No distro restart/registration replacement, agent SIGKILL fault probe, OOM or
native Windows GUI qualification was performed.

Production Lua bootstrap also passes through real `wsl.exe`, with both omitted
user and explicit `francis` selection verified by `id -un`. It deploys/verifies
the versioned agent, executes concurrent info/read/list/exec, preserves non-UTF-8
argv/results through the binary protocol, cancels exec, reconnects with a fresh
generation, and connects to a preinstalled path. These runs use a **Linux native
client → Windows interop → WSL** topology, not a Windows-native client. The
interop fixture supplies an explicit Windows UNC artifact path. An initial run
using the Linux bundle pathname failed at `wslpath -u`; it is not a Windows path,
and that failed run is not counted as passing discovery/installation evidence.
Automatic discovery from a native Windows installation remains unqualified.

Tests may populate the selected user's checksum-keyed agent cache; they never
remove/replace distributions or fault-corrupt an existing distro's agent cache.
WSL's CLI selects registration names, not Podman-style immutable container IDs;
replacement during bootstrap is explicitly not pinned/qualified. All existing
PTY code, including WSL bypass, remains unchanged. The agent still has no PTY
operation implementation.

```sh
python3 scripts/agent_conformance.py --connector wsl --distro Ubuntu-26.04 \
  --agent-path /absolute/linux/path/to/hollow-agent
python3 scripts/agent_host_tests.py --connector wsl-bootstrap --distro Ubuntu-26.04 \
  --wsl-artifact '\\wsl.localhost\Ubuntu-26.04\absolute\linux\path\to\hollow-agent' \
  --agent zig-out/bin/hollow-agent -- zig build --build-file build-agent.zig test-host-lua \
  -Dhost-lua-include=/path/to/lua51/include -Dhost-lua-object=/path/to/liblua.a
# Repeat with --wsl-user <existing-user> to qualify explicit selection.
```

CI runs WSL connector mocks/validation tests and Windows cross-compilation, not
the real WSL launcher. WSL performance and the full portability/failure matrix
remain separate release gates; these fs/exec results do not authorize PTY rollout.

## Experimental SSH fs/exec connector continuation

`hollow.host.ssh` shares the Linux agent and bootstrap lifecycle with Podman/WSL.
Remote commands use explicit POSIX quoting for SSH's shell boundary; upload uses
forced SFTP (`scp -s -B`) with matching identity, configuration, port and host-key
policy. The extra local tool uses the same native execution slot, bootstrap
deadline, cancellation and owned-temp cleanup ordering. ControlMaster is disabled;
one persistent non-TTY SSH process carries connected RPCs. Forwarding, remote/local
command overrides and escape handling are disabled for connector-owned processes.

Executed evidence:

* 19 Lua SSH cases pass, including quoting, policy, validation, architecture,
  bundle selection, retained configuration, checksum/copy errors, deadline,
  cancellation ordering and late-host cleanup. Complete Lua suite: 403 pass.
* 32 Python unit tests pass, including four preinstalled SSH connector cases and
  three owned SSH fixture tests. Python does not duplicate production deployment.
* Native Lua integration passes with default executable-relative bundle discovery
  against a uniquely owned rootless Podman Alpine/OpenSSH fixture, non-root user
  `agent`. Both client key/config paths and remote HOME include spaces/quotes.
  Deployment, reuse, preinstalled agent, binary argv/results, concurrent reads,
  cancellation, reconnect generation and checksum rejection pass.
* Host-key mismatch, unknown host (empty user database), and unauthorized private
  key reject without prompts. The fixture verifies the empty database remains
  unchanged. Trusted host keys come directly from its owned container, not TOFU or
  a network key scan. Client keys/config are temporary; cleanup removes only the
  fixture's owned container and files.
* All 16 shared wire/fs/exec conformance tests pass through SSH to the deployed
  agent. Native host transport/operations/manager/local tests, prefix/bin and flat
  headless integrations, configured-UID Podman regression, and Windows adapter
  cross-compilation also pass after this change.

Reproduction (fixture installs OpenSSH packages in its disposable container, so
package repository access is required; production bootstrap installs no packages):

```sh
python3 scripts/agent_ssh_tests.py --conformance --agent zig-out/bin/hollow-agent -- \
  zig build --build-file build-agent.zig test-host-lua \
  -Dhost-lua-include=/path/to/lua51/include -Dhost-lua-object=/path/to/liblua.a
```

Native Windows OpenSSH execution, ProxyJump routes, network loss during upload,
agent SIGKILL through SSH, OOM and full hostile-cache/failure matrices remain
unqualified. No session/PTY implementation changed; WSL PTYs still use bypass.

## Packaged artifact discovery continuation

When no explicit `artifacts`/`agent_path` is supplied, production Podman bootstrap
now reads the release bundle using native-local info/read/stat promises. Native
`info().executable_dir` is produced on a worker; remote agents do not supply it.
The default root is `<executable-dir>/agents`. Only a `bin` executable directory
permits the conventional `../agents` fallback, and only when the first manifest
is missing. Flat releases do not search outside their directory. Explicit
`agent_dir` limits discovery to one caller-selected absolute directory. Invalid
manifests fail closed before any Podman command runs.

Seventeen artifact tests and five additional Podman tests cover bounded manifest
reads, strict path allowlisting, duplicate/traversal/missing entries, file kinds,
byte paths, CRLF, fallback/trust boundaries, cancellation, configuration ownership
and precedence. Full Lua results above use plain Lua 5.1; LuaJIT is CI-configured,
not locally executed.

`test-host-lua` executes an installed headless runner from `prefix/bin` with
`prefix/agents`; `test-host-lua-flat` stages a flat runner plus adjacent `agents/`.
Both pass native-local discovery. Production Podman tests now omit explicit
artifacts, resolve the built bundle, and pass deployment/reuse/repair/preinstalled
and wrong-digest checks in both layouts. The prefix layout also passes as UID/GID
1000:1000. Native Lua adapter cross-compilation for Windows passes; Windows
runtime and complete GUI release archive builds remain unverified.

Release workflow jobs now build and stage both static Linux architectures and
`SHA256SUMS` into Windows/Linux archives. Manifest generation streams hashing,
validates ELF headers/architecture order, and atomically replaces output only
after both inputs validate. Four Python tests cover generation and failure
preservation. Local `agent-all`, `file`, and `sha256sum -c SHA256SUMS` confirm
static x86_64/aarch64 artifacts and both checksums. No hosted release job or
ARM64 execution is claimed; manifest header validation alone is not a complete
ELF/static-link verifier.

```sh
zig build --build-file build-agent.zig test-host-lua test-host-lua-flat \
  -Dhost-lua-include=/path/to/lua51/include -Dhost-lua-object=/path/to/liblua.a
python3 scripts/agent_host_tests.py --connector podman-bootstrap --agent zig-out/bin/hollow-agent -- \
  zig build --build-file build-agent.zig test-host-lua-flat \
  -Dhost-lua-include=/path/to/lua51/include -Dhost-lua-object=/path/to/liblua.a
```
