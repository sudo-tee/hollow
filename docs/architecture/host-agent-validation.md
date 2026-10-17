# Agent foundation validation — 2026-10-17

This records local execution, not hosted CI results or completion of the v4
plan. Environment: x86_64 Linux under WSL2, Zig 0.16.0, rootless Podman 5.7.0,
`docker.io/library/alpine:3.21`. No Windows GUI or SSH qualification ran.

| Check | Result |
|---|---|
| Static Linux musl x86_64 and aarch64 builds | Pass; `file` confirms static ELF |
| Protocol / filesystem native tests | 5 / 3 pass |
| Python harness / deployment / fault-safety unit tests | 16 pass |
| Persistent native transport integration / imported protocol tests | 5 / 5 pass |
| Windows x86_64 GNU transport cross-compile | Pass; compile only, no Windows execution |
| Local SIGKILL / EOF descendant containment | 6 pass |
| Rootless Podman SIGKILL / EOF descendant containment | 6 pass |
| Typed request/result tests | Pass; byte encoding, owned results, invalid metadata and allocation failure |
| HostManager tests | 4 real-agent integration + 1 handle validation pass (10 with imported protocol tests) |
| Native Lua host promises through local / rootless Podman | Pass, same headless integration test; local Lua 5.1 API |
| Complete Lua suite | 326 pass under Lua 5.1; host suite 8 and host workspace suite 15 pass |
| Native-local operations | 6 pass; byte paths/argv/env, pagination, symlink stat/read, direct-child cancellation/deadlines and combined output cap |
| Native-local manager | 3 integration tests pass (10 including imports); shared dispatch, reconnect isolation and retained-request bounds |
| HostManager and native Lua adapter Windows compile checks | Pass; no runtime execution |
| Full Windows GUI cross-build | Blocked by two generated FreeType binding unused-constant errors; not a passing app build |
| Local-subprocess conformance | 16 pass |
| Rootless Podman conformance | 19 pass |
| Podman configured UID/GID 1000, fs/exec subset | 2 pass; no root override |
| SHA256SUMS verification for both artifacts | Pass |
| Isolated build without GUI sources, submodules or vendor tree | Pass |
| ARM64 execution | Not verified; cross-build only |
| Windows WSL connector / GUI latency, SSH, Docker | Not verified |

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
deployments and all portability runners) is still incomplete. Production
connector configuration/bootstrap, broader read-only query migration and native
Windows qualification remain incomplete; all PTY extraction/multiplexing
milestones remain unimplemented.
