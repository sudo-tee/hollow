# Agent foundation validation — 2026-10-17

This records local execution, not hosted CI results or completion of the v4
plan. Environment: x86_64 Linux under WSL2, Zig 0.16.0, rootless Podman 5.7.0,
`docker.io/library/alpine:3.21`. No Windows GUI qualification ran. SSH validation
uses an owned non-root Alpine/OpenSSH fixture, not a production server.

| Check | Result |
|---|---|
| Static Linux musl x86_64 and aarch64 builds | Pass; `file` confirms static ELF |
| Protocol / filesystem native tests | 5 / 3 pass |
| Python harness / deployment / fault-safety / manifest / connector unit tests | 44 pass |
| Persistent native transport integration / imported protocol tests | 5 / 5 pass |
| Windows x86_64 GNU transport cross-compile | Pass; compile only, no Windows execution |
| Local SIGKILL / EOF descendant containment | 6 pass |
| Rootless Podman SIGKILL / EOF descendant containment | 6 pass |
| Typed request/result tests | Pass; byte encoding, owned results, invalid metadata and allocation failure |
| HostManager tests | 4 real-agent integration + 1 handle validation pass (10 with imported protocol tests) |
| Native Lua host promises through local / rootless Podman | Pass, same headless integration test; local Lua 5.1 API |
| Complete Lua suite | 435 pass under Lua 5.1; Docker adds 25 common container cases and 7 context/restaging cases to previous 403 |
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
| Docker-shaped Lua contract | 25 shared container cases + 7 context/restaging cases pass |
| Docker public API native integration through Podman-compatible CLI | Pass; configured UID/GID 1000, bootstrap/repair/reuse, prefix/bin and flat layout, 16 common conformance cases |
| Real Docker daemon / native Windows WSL/SSH client / GUI latency | Not verified |
| Mock socket stream conformance | 16 pass, 257-byte relay chunks, unchanged agent |
| Mock socket native Lua and forced link loss | Prefix/bin and flat headless contracts pass; in-flight EXEC fails, reconnect nonce changes, side effect not replayed |

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

## 2026-10-18 bounded-bulk candidate follow-up

The opt-in candidate is **not performance-qualified**. Its
[306-measurement report](../benchmarks/agent-pty/2026-10-18-bounded-bulk.md)
records lower mixed shared p99 at substantial bulk-throughput cost, remaining
bulk-free latency failures, and an unresolved possible default-path throughput
regression. Default scheduling and pane selection remain unchanged; neither
numeric parity nor regression absence follows from correctness results.

Current local correctness rerun, Zig 0.16.0 ReleaseSafe:

* 137 standalone native test executions pass, including imports: protocol 5,
  agent loop 24, filesystem 3, PTY adapter 30, host transport 15, typed operations
  17, manager 14, native-local 15 + 14.
* Both `HOLLOW_AGENT_BOUNDED_BULK` and queue profiling enabled: loop/PTY/transport
  rerun passes 69 executions (24 + 30 + 15).
* 58 Python harness unit tests pass. Bounded flag enabled: 11 PTY wire/lifecycle
  cases pass; 16 ordinary fs/exec conformance cases pass with the flag ignored
  because those connections do not negotiate experimental PTYs.
* New regressions cover 16-slot output rotation, ordered exact stdout/stderr,
  cancellation after partial DATA, oversized atomic filesystem metadata,
  retained-completion deadlines and reused-PID reap matching. Real-agent test
  checks all 256 long filesystem names without duplicates and exact large
  stdout/stderr captures and nonzero exit status.
* Static x86_64/aarch64 musl builds and both SHA256SUMS pass; ARM64 execution
  remains unverified. Installed local agent restored to ReleaseSafe.
* New four-measurement bounded/profiling CI command passes locally on ReleaseSafe
  with concurrent correctness work; correctness smoke only, not timing evidence.
  Measured ReleaseFast datasets above ran separately without concurrent builds/tests.
* All 306 completed measurements revalidated, all 13 measured workspace source
  hashes reconstructed, and current measured source hashes remain unchanged.
  Separate old-agent overrides retain independently verified binary identity.

No new native Windows, GUI/GPU, real Docker daemon, remote connector, fault/OOM,
soak or large-scale qualification is claimed by this follow-up.

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
Production PTY code, including WSL bypass, remains unchanged. At that stage the
agent had no PTY implementation; the later opt-in experiment is recorded below.

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

## Experimental Docker connector continuation

`hollow.host.docker` and `hollow.host.podman` now share container selection and
adapter policy in `hollow.host.container`. Both pin the inspect result's full ID,
preserve the configured container user, and use the same Linux binary, operation
handlers and persistent transport. Docker's optional explicit context prefixes
all commands, including cleanup; configuration is copied before async work.
No agent, protocol handler, workspace policy or PTY changes were needed.

Docker-specific restaging handles archive copy ownership: after `cp`, the configured
user opens the uploaded inode, removes only the reserved temp name, and recreates
it with noclobber and umask 077 before common SHA/chmod/atomic installation. No
privileged exec, chown, second named temporary or fallback to root is introduced.
Unreadable copied files fail closed; release artifacts are mode 0755. This step
addresses Docker's root-owned-copy behavior by design; actual Docker ownership
semantics still require real-daemon qualification, not compatible-CLI evidence.

Executed locally:

* All 25 existing container contract cases run for both Podman and Docker.
  Seven Docker context/restaging cases additionally verify exact argv prefixes,
  retained options, validation, copy/restaging failures and cancellation/drain
  before context-specific cleanup. The four connectors share bootstrap admission
  limits. Complete Lua suite: 435 tests.
* Six Docker connector/fixture Python unit tests pass (38 Python tests total),
  covering full-ID pinning, exact binary-clean argv, validation, failed inspect,
  missing tool and cleanup limited to a fixture-owned ID/ownership label.
* Production Docker API passes native prefix/bin and flat-layout integration
  using **`--docker podman`**, an explicit compatible-CLI override, in an owned
  container configured as UID/GID 1000:1000. Automatic discovery, deployment,
  restaging, reuse, corrupt-cache repair, preinstalled path, checksum rejection,
  exec cancellation and new generations pass. All 16 common wire/fs/exec
  conformance cases pass through the Docker harness with the same override.
* Production Podman UID/GID 1000 bootstrap regression, native transport/manager/
  operations/local tests and Windows adapter cross-compilation pass.

Neither `docker` nor `dockerd` was installed locally. These results are **not real
Docker qualification**. Docker copy ownership, remote contexts, Docker Desktop,
Windows clients, daemon/container failures, OOM, and the broader release matrix
remain unverified. CI now defines a real-Docker non-root bootstrap/conformance job;
its result has not been observed in this session.

Run on a Docker-capable machine (fixture creates/starts/removes only its owned
container; production Lua never performs those lifecycle actions):

```sh
python3 scripts/agent_docker_tests.py --conformance --agent zig-out/bin/hollow-agent -- \
  zig build --build-file build-agent.zig test-host-lua test-host-lua-flat \
  -Dhost-lua-include=/path/to/lua51/include -Dhost-lua-object=/path/to/liblua.a
# Optional --context <name>; --docker podman is compatibility evidence only.
```

The PR6 fs/exec release gate remains open: real Docker/native Windows qualification,
broader fault/security coverage and host-aware read-only project query gaps are
not completed by this slice. The mock socket proof is recorded below. PTY extraction
and multiplexing still require separate baselines/qualification; WSL bypass stays.

## Mock socket / future vsock-hvsock boundary proof

`scripts/agent_mock_socket.py` is a **test-only** AF_UNIX listener with two bounded
stdio/socket relays. It models a connector establishing a reliable ordered byte
stream, not actual AF_VSOCK or Hyper-V sockets. Every accepted link launches the
same preinstalled Linux agent in stdio mode. The native client still supplies
only subprocess connector argv; its relay process opens the private socket.
No RPC framing or operation interpretation happens in either relay. Production
direct-socket transports and their authentication/lifecycle remain future work.

The socket lives in a fixture-owned mode-0700 temporary directory; its pathname
is mode 0600. There is no TCP/public listener or privilege requirement. At most
eight links/workers are active. Each relay direction buffers at most 64 KiB,
with bounded read/write chunks and backpressure; EOF propagates only after that
direction's queue drains, without prematurely closing the response direction.
Fixture shutdown closes links, stops relays, waits for owned agent cleanup and
joins workers before removing only its own endpoint/directory. No daemon is left
running and no arbitrary PID scan or signal target is used. Same-user malicious
clients are not isolated by this test fixture; it is not an authentication design.

Executed evidence:

* All 16 existing fs/exec/wire conformance cases pass over the socket path with
  257-byte maximum relay reads/writes, including binary paths/output, concurrent
  RPCs, malformed frames, cancellation/deadline, EOF/reconnect and nonce changes.
* Unchanged native Lua host tests pass from prefix/bin and flat bundle layouts
  through the socket connector argv, including concurrent operations, cancel,
  stale generations and manager teardown. No production agent, Zig transport,
  operation handler or Lua host API changes were needed for this proof.
* A forced-link-loss probe starts an EXEC with a fixture-owned marker, waits for
  its side effect, shuts down socket links, and observes pending request failure.
  A fresh connection negotiates a distinct nonce and reads exactly one marker
  byte: the lost EXEC is not replayed. This socket-fault probe uses the Python
  client; native Lua tests exercise their existing close/reload lifecycle paths.
* Six Python socket tests pass: byte-transparent fragmentation/short writes,
  ordered bidirectional half-close, bounded backpressure/stop, private endpoint
  cleanup, input validation, clean protocol stdout on connection failure, and
  eight-link admission with worker joins. Total Python suite: 44 tests.

```sh
python3 scripts/agent_socket_tests.py --agent zig-out/bin/hollow-agent \
  --fragment 257 --conformance -- \
  zig build --build-file build-agent.zig test-host-lua test-host-lua-flat \
  -Dhost-lua-include=/path/to/lua51/include -Dhost-lua-object=/path/to/liblua.a
python3 scripts/agent_conformance.py --connector mock-socket \
  --agent zig-out/bin/hollow-agent --socket-fragment 257
```

CI is configured to run this Linux mock, not real vsock/hvsock. No Windows socket
family qualification, VM identity/authentication, vsock addressing, reconnect
policy, suspended-VM recovery, latency benchmark or PTY rollout is established.

## Opt-in agent PTY implementation

Actual agent PTY code now exists; this is no longer only a connector experiment.
See [experimental PTY contract](agent-pty-experiment.md) and its runnable client.
Eleven real tests pass on each of local Linux, rootless Podman and
Linux → Windows `wsl.exe` interop → Ubuntu-26.04. They exercise controlling TTY on
all stdio descriptors, prompt/output before exit, raw NUL/non-UTF-8/control input,
interactive-shell Ctrl-C, resize/SIGWINCH, credit exhaustion while HOST_INFO stays
responsive, final output before exit, bounded unread input, deadline, isolated
close, failed exec, opt-in rejection, EOF cleanup and agent-SIGKILL guardian cleanup.
Tests identify only workloads launched by the fixture and never signal reused PIDs.

Static x86_64/aarch64 builds and existing native agent/fs/host tests pass after
implementation; all 16 ordinary local fs/exec conformance cases still pass.
CI is configured for local and Podman PTY cases; no hosted result is claimed.

These are Linux PTY correctness tests, not Windows GUI execution or benchmark
qualification. Native streaming and experimental pane selection are now implemented
as described below; rendered GUI integration, full crash/descendant stress and
input-latency/throughput comparisons remain unfinished. Existing WSL bypass and all production defaults
remain active. The Python interactive client is an experiment, not a production
Lua/PTy API or a release gate waiver.

### Native streaming adapter and explicit pane selection

`test-agent-pty` passes 20 tests locally and with adapter sessions routed through
rootless Podman and real `wsl.exe` interop. This count includes imported native
PTY/protocol unit tests and local-only wake/entry-point fixtures, not 20 remote
agent cases. Coverage includes 2 MiB streamed raw output with a 64 KiB pending
bound, exit/drain ordering, resize/Ctrl-C, SHA-256 verification of ordered input
after genuine remote queue exhaustion, atomic local input admission, failed launch,
scheduled wakes, connection-loss pane isolation and explicit pane spawn selection.
The native host regression run passes 65 tests including this target.

Windows adapter compile checks pass with the headless build-options stub. GUI
rendering/execution is not tested; the stub does not qualify shell integration.
CI now includes native local/Podman runs and Windows adapter compilation, but no
hosted result is claimed. `HOLLOW_EXPERIMENTAL_AGENT_PTY` is a process-wide explicit
development override, not Lua workspace policy or a default backend change.

### Real pane/terminal integration continuation

The separate `zig build -Dagent-pane-only=true test-agent-pane` graph links the
actual terminal engine, bypassing font, GPU, Lua and window dependencies. Its two
tests pass locally, through rootless Podman, and through Linux → Windows
`wsl.exe` → WSL interop. They run actual `Pane.bootstrap`, layout resize and
`pollPty`, verify 128 KiB binary startup input by SHA-256, exercise terminal
query/reply through the pane callback, inspect primary/alternate terminal grids,
release render helpers for background parsing, and check final output/status.
Closing a pane during partial input delivery leaves a second pane usable.

These tests exposed and now cover two integration fixes: deadline-aware agent
input accepts a bounded prefix of oversized pane chunks, and pane startup-input
ownership retains the original allocation length across partial writes. Fully
draining, replacing or destroying a partial queue now frees the full allocation.
The standalone adapter's all-or-error `writeAll` behavior is unchanged.

`scripts/setup.sh --agent-pane` fetches/patches only the terminal dependency and
leaves submodules and Lua tooling untouched; the corresponding CI job is configured,
not observed. Test callbacks are lightweight fixtures, not the full application
callback bundle. No GPU rendering, native Windows GUI or baseline performance
qualification is claimed.

### Dedicated PTY adapter measurements (E1)

The native Zig benchmark runs identical ready/prompt/output workloads through the
native Linux PTY backend and experimental dedicated-agent adapter. Five
independent paired ReleaseFast runs, each with 5,000 recorded prompt exchanges and
10/100 MiB output, completed with exact byte checks, SHA-256 and clean exits.
Raw compressed JSONL, source/executable hashes, ranges and conclusions are
preserved in [the measurement report](../benchmarks/agent-pty/README.md).

On this Linux client inside WSL2, median per-run prompt p99 is 0.320 ms native
versus 0.643 ms agent. Median 10/100 MiB output throughput is 75.04/72.15 MiB/s
native versus 11.80/12.23 MiB/s agent. At that stage the measured throughput gap blocked any
default-switch argument. A second five-run experiment with 64 KiB host read-ahead
did not improve throughput; its runtime change was removed and experiment patch
preserved. The subsequent investigation below identifies the dominant scheduling bug.

Final benchmark correctness smokes pass locally, through rootless Podman and
through WSL interop; remote smoke timings are not parity measurements. The final
build passes 65 native regressions and 49 Python harness tests; benchmark code
cross-compiles for Windows, with native comparison explicitly Linux-only.
The new CI benchmark smoke checks correctness, never machine-dependent thresholds.
This is neither legacy WSL-bypass comparison nor GUI/scalability qualification;
all dataset rows intentionally retain `qualification: false`.

### Dedicated PTY throughput fixes

Optional fixed-size counters identify avoidable ready-output poll sleeps after
credit restoration. The agent now schedules buffered output before poll, and the
host reuses one DATA-frame-sized scratch buffer plus inline credit payloads
instead of allocating both on every transfer. Queue, frame and credit caps stay
unchanged; regression tests cover scheduling and allocation-free DATA/credit paths.

The original allocator choice is now explicit: old benchmarks used page allocator,
while GUI uses thread-safe DebugAllocator. Controlled before/after tests with
GUI-matched allocator and identical diagnostics show 100 MiB throughput improving
2.51× from the scheduling fix alone, with all observed ready-output poll stalls
removed. With both fixes and diagnostics off, five-run GUI-allocator medians reach
98.1%/101.4% of native 10/100 MiB throughput; prompt p99 delta is +0.274 ms.
Repeating the original page-allocator path reaches 96.0%/100.1%, so this is not
merely an allocator-label change. Individual short-transfer runs still vary below
95%; these local data do not qualify Windows/WSL bypass or GUI rollout.

Four additional raw datasets and exact hashes are preserved in the
[throughput investigation](../benchmarks/agent-pty/2026-10-18-throughput-fix.md).
The regression build executes 104 native tests across targets (including imports),
50 Python unit tests, 16 local fs/exec conformance cases and 11 real PTY cases.
Native Lua contracts pass in prefix/bin and flat layouts; PTY adapters pass through
Podman, WSL interop and fragmented mock sockets. Windows adapter cross-compilation
and both static agent architecture builds pass. Production defaults remain unchanged.

### Initial shared PTY experiment (E2/E3 subset)

An explicit native shared owner supports 1/4/8/16 session adapters. Pane selection
still opens dedicated connections. Filtered per-request completion polling,
separate job/request admission, per-session cancellation tombstones and retained
transport ownership cover isolation and teardown without persistence or replay.
Sixteen PTYs leave request slots for input/resize while preserving the 16-job cap.

Two complete local three-run matrices (180 measurements each) compare native,
dedicated and shared adapters under idle, all-noisy and one-stalled-consumer loads.
A bounded rotating PTY scheduler reduces shared 16-PTY noisy median prompt p99
from 27.92 to 8.61 ms. All consuming background streams make checked progress,
and the stalled shared consumer stays at 64 KiB. However, five of 18 post-change
loaded pairs still exceed a local +5 ms p99 check versus native POSIX, and worst
background delivery gap increases to 80.31 ms. This is **not** a shared rollout
pass, nor a replacement for the legacy WSL-bypass comparison.

A separate five-run dedicated E1 repeat retains 96.9%/97.0% native median
throughput at 10/100 MiB, with slow individual pairs preserved. All datasets,
reconstructable source patches, raw hashes, per-stream/aggregate throughput and
latency graph are in the [shared experiment report](../benchmarks/agent-pty/2026-10-18-shared-pty.md).
The standalone graph passes 120 native test executions (including imported tests)
and 52 Python harness tests. Shared adapter cases also pass through Podman, WSL
interop and fragmented mock sockets; Windows adapter/benchmark compile checks,
real pane integration, fs/exec conformance and installed-layout Lua tests pass.

Keep the bounded scheduler for further opt-in research; reject shared-pane
rollout until focus-aware/tail-fairness, filesystem bulk, CPU/RSS, fault/load,
40/100/200-PTY and native Windows GUI/WSL parity experiments qualify the design.

### Mixed filesystem/exec harness continuation

The headless benchmark can now run bounded repeated `FS_READ`, non-PTY `EXEC`,
or both alongside PTYs. Shared mode reuses the PTY connection; native/dedicated
mode uses a separate agent, explicitly recorded in each result. Every completed
bulk operation verifies exact bytes, and starvation fails rather than silently
producing a clean dataset. Optional periodic foreground resize issuance shares
the prompt path; issuance counts are not applied-size latency measurements.
The existing 16-job limit remains enforced, including bulk workers.

The local `test-agent-pty` target passes 29 tests including imports. New coverage
fills one shared PTY's stopped-consumer buffer to exactly 64 KiB, then checks
filesystem/exec completions, sibling input and post-cancellation progress.
Fixed-size latency-histogram tests and 54 Python harness tests pass. The initial
24-measurement smoke covers all backends, all four bulk modes, stalled background
consumption and resize issuance. CI adds a smaller mixed-load correctness smoke;
no hosted run is claimed.

The [repeated eight-PTY comparison](../benchmarks/agent-pty/2026-10-18-mixed-8.md)
preserves 72 measurements and reconstructable benchmark sources. Shared noisy
median prompt p99 increases from 6.48 ms without bulk to 9.89 ms with mixed bulk;
stalled median p99 increases from 6.62 to 9.40 ms. Every consuming stream and
enabled bulk operation makes checked progress, with the shared stopped consumer
still at exactly 64 KiB. Local loaded-latency comparisons continue to fail.
The 29-test adapter target also passes through Podman and real WSL interop;
16 fs/exec conformance cases and Windows adapter/benchmark compile checks pass.

See [methodology](host-agent-benchmarks.md#mixed-filesystemexec-interference) for
fixture ownership, connection placement and owner-observed timing limits. This
follow-up changes benchmark/test code, not production scheduling or defaults.
At that stage, internal dispatch/control-queue instrumentation, focus-aware
scheduling, split lanes and full Windows/WSL qualification remained open; the
diagnostics below add partial internal timings, not scheduling qualification.

### Agent-side queue diagnostics continuation

`HOLLOW_AGENT_QUEUE_PROFILE` independently enables fixed-size output-span,
dispatch/handler and buffered-command poll timing. The parser validates raw
filesystem reply accounting, partial writes and explicitly censored/dropped
timings. No queue/scheduler/admission/default changes accompany diagnostics.

The [diagnostic report](../benchmarks/agent-pty/2026-10-18-queue-profile.md)
preserves 12 profiling-off, 12 profiling-on and 30 dedicated E1 measurements.
Profiled mixed prompt runs show up to 590,710 wire bytes ahead of input ACKs,
17.29 ms maximum ACK queue residence and 22.75 ms maximum PTY DATA queue
residence. These are aggregate per-connection observations, not causally matched
foreground echoes. No trace overflow occurs; no complete buffered-command poll
occurs. Profiling shifts measured tails and remains opt-in.

Standalone regression targets execute 127 tests including imports; 57 Python
tests and 16 opt-in fs/exec conformance cases pass. Adapter/transport tests pass
with diagnostics off/on; target-enabled adapters pass through Podman and WSL
interop. A Podman mixed smoke captures valid traces. Both static architectures
build and both real pane/terminal integration tests pass; ARM64 execution and
native Windows GUI remain unqualified. Dedicated
diagnostics-off E1 medians remain near native, with one slow sub-95% short-transfer
pair preserved. The local CI diagnostic smoke passes; no hosted result is claimed.
Ready-to-enqueue/per-stream correlation, focus-aware and split-lane scheduling,
fairness/resource/fault matrices and GUI/legacy-bypass parity remain future work.

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
