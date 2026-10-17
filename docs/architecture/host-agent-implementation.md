# Universal host runtime implementation

The design source is `hollow-agent-architecture-plan-v4.md`. Implementation is
staged; this change does **not** complete the entire plan or switch any pane to
an agent PTY.

## Current scope

* PR 0: [wire and ownership RFC](host-agent-v1.md), legacy benchmark harness and
  [qualification methodology](host-agent-benchmarks.md). Windows/WSL GUI baseline
  qualification remains a prerequisite for future PTY experiments.
* PR 1: GUI-independent Linux agent, bounded read-only filesystem operations and
  non-PTY exec, protocol tests, local-subprocess conformance harness.
* PR 2: test-harness Podman connector, checksum-verified versioned installation,
  rootless disposable-container conformance, and a dedicated CI job.
* Crash hardening: per-EXEC subreaper guardians and repeatable local/Podman
  SIGKILL/EOF descendant-cleanup gates, including detached double-fork children.
* PR 3, in progress: persistent asynchronous Zig subprocess transport,
  bounded runtime-owned HostManager, typed byte-safe request/results, and
  `hollow.host` Lua promises for explicit subprocess connectors. Native/Lua
  end-to-end tests run the same contract locally and through rootless Podman.
* PR 3 continuation: native-local fs/exec workers exposed as
  `hollow.host.local_host()`, plus opt-in asynchronous workspace directory
  discovery through `source.host`. Legacy resolver aliases remain operational.
* PR 3 Podman continuation: Lua-side production bootstrap for existing containers,
  configured per-architecture artifacts and expected checksums, or a preinstalled
  executable. All remote operations still use the existing persistent transport.
* PR 3 packaged discovery: release jobs include both Linux musl agents and a
  header/architecture-validated SHA-256 manifest. Bootstrap discovers trusted
  executable-relative bundles asynchronously, with explicit overrides and strict
  manifest path allowlisting. Native integration tests cover flat and prefix/bin
  installation layouts; full GUI release archives are not locally qualified.

These are foundational agent/test components, **not yet a production GUI host
runtime**. The Podman connector currently lives in the conformance harness, not
Hollow's Zig dispatcher. `hollow.host.connect({id, argv})` is an explicit,
experimental host API; WSL/SSH connectors and host-aware project
load/bootstrap/write migration are not implemented yet. Existing
`hollow.process` and all PTYs retain their behavior.
See [executed validation and known blockers](host-agent-validation.md).

## Build and test

Use Zig **0.16.0** for this implementation. Zig 0.17 removes `@cImport` and is
not currently compatible with Hollow's libc-based sources. The agent-only graph
does not configure, fetch or link GUI, Ghostty, Sokol or LuaJIT dependencies:

```sh
zig build --build-file build-agent.zig -Doptimize=ReleaseSafe agent agent-all test-agent test-agent-fs
zig build --build-file build-agent.zig -Doptimize=ReleaseSafe test-host-transport
zig build --build-file build-agent.zig -Doptimize=ReleaseSafe test-host-operations test-host-manager
zig build --build-file build-agent.zig -Doptimize=ReleaseSafe test-host-local
# Optional: requires LuaJIT's Lua 5.1 API headers and library.
zig build --build-file build-agent.zig -Doptimize=ReleaseSafe test-host-lua
python3 scripts/agent_host_tests.py --connector podman --agent zig-out/bin/hollow-agent -- zig build --build-file build-agent.zig -Doptimize=ReleaseSafe test-host-lua
python3 -m unittest discover -s scripts/tests -v
python3 scripts/agent_conformance.py --connector local-subprocess --agent zig-out/bin/hollow-agent
python3 scripts/agent_conformance.py --connector podman --agent zig-out/bin/hollow-agent --image docker.io/library/alpine:3.21
(cd zig-out/agents && sha256sum -c SHA256SUMS)
```

`agent` installs the selected x86_64/aarch64 architecture to
`zig-out/bin/hollow-agent`. `agent-all` installs both static Linux musl binaries
under `zig-out/agents/linux-<arch>/hollow-agent` plus `SHA256SUMS`. ARM64
cross-compilation is not ARM64 runtime qualification. Python 3 is required by
packaging and test tooling, not by the agent.

The Podman fixture creates a uniquely named disposable container and removes
only that container on completion. `--container NAME` uses an existing container
without deleting it. It preserves the configured container user, never uses
`--privileged`, never allocates a TTY and never disables security policy to
install the binary. Bootstrap requires standard `sh`, `uname`, `printenv`,
`mkdir`, `chmod`, `mv` and `sha256sum` tools. Restricted/minimal targets may need
a preinstalled agent; automatic deployment is not promised there.

## Next gates, in order

1. Finish adversarial/fault coverage and review the standalone agent before
   depending on it from the GUI. Do not equate a green conformance subset with
   the full v4 security and failure-injection matrix.
2. PR 3: finish native-local lifecycle
   qualification, and remaining host-aware read-only project queries on HostManager and Lua
   promises. Preserve `hollow.process` defaults. No remote I/O runs in Lua's
   owner thread; runtime reload cancels and joins the previous manager before
   its Lua state is destroyed, invalidating old generations.
3. PR 4–6: production WSL, SSH and Docker connectors; shared conformance,
   verified deployment, watchdogs, generation handling and release hardening.
4. PR 7: extract PTY engine without a backend change, only after reproducible
   legacy WSL measurements exist.
5. PR 8–9: explicitly execute dedicated/shared/split/hybrid transport and
   scheduling experiments. Include 40/100/200 PTYs, focus priority, background
   fairness, stopped consumers and worker/agent fault injection. Keep raw
   datasets; default-backend rollout requires the numeric v4 gates.

Agent fs/exec success does not imply PTY performance, detach/reattach, persistent
sessions after agent SIGKILL, Windows GUI parity, SSH portability or WSL support.
Those require their own tests and resource-ownership decisions.
