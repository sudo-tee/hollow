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
zig build --build-file build-agent.zig -Doptimize=ReleaseSafe test-host-transport
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

The full v4 matrix (including allocation-failure fuzzing, read-only/noexec
deployments and all portability runners) is still incomplete. HostManager, typed
host adapters, production Lua integration and all PTY extraction/multiplexing
milestones remain unimplemented.
