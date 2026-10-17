# Hollow Host Runtime & Universal Agent — Implementation Plan (v4)

**Baseline:** [`sudo-tee/hollow`, branch `feat/improve-api-surface`](https://github.com/sudo-tee/hollow/tree/feat/improve-api-surface)  
**Status:** Architectural proposal, not implemented or benchmarked  
**Design priority:** Eliminate environment-specific process and filesystem hacks **without sacrificing Hollow's existing low-latency PTY path**.  
**Primary validation environment:** rootless **Podman** with disposable Linux containers; WSL and SSH are mandatory portability tests, not separate agent implementations.  
**Delivery strategy:** **Ship universal agent fs/exec first and keep WSL PTYs on `hollow-wsl-bypass` initially. Multiplexed agent PTYs remain an explicit research and engineering goal, with dedicated experiments and performance gates; they are not silently abandoned if the first prototype fails.**

## 1. Executive decision and invariants

Build a **single, small Linux `hollow-agent`** with a versioned, transport-independent protocol. Its first responsibility is filesystem and process execution in the target environment. It is the *same binary and RPC implementation* whether the connection is opened through `podman exec`, `wsl.exe`, `ssh -T`, or eventually `docker exec` or vsock/hvsock. A connector differs only in discovery, bootstrap, binary deployment, transport setup, and lifecycle observation.

Preserve the Windows Hollow GUI, LuaJIT runtime, multiplexer, Ghostty VT parser, terminal scrollback, layout, key handling and current PTY backend. The initial architecture is **not** a Tern-like always-running multiplexer. An agent is connection-scoped and **does not own Hollow panes** in the first production phase.

Non-negotiable invariants:

1. No `wsl.exe`, `ssh`, `podman exec` or shell-string wrapping for *normal fs/exec operations*. They are used only to establish and maintain the agent connection.
2. The Zig host layer stays thin: connector/transport/protocol and async request dispatch in Zig; discovery, workspace policy and UI state remain in Lua.
3. No regression to interactive PTYs merely to deliver fs/exec. **Legacy WSL bypass remains the default until a separate PTY performance gate is passed.**
4. Raw terminal data is forwarded without interpreting VT sequences; Ghostty remains the sole terminal parser.
5. Host paths belong to a host and are transmitted as bytes, not translated to Windows/UNC forms for internal use.
6. A shared agent connection is **not** required to own multiple PTYs; a shared failure domain is an explicit tradeoff, not an incidental side effect.
7. No listener ports, elevated privilege, mandatory system service, UDP, mandatory TCP or remote plugin runtime in the first version.
8. The only environment-dependent code is connector/bootstrap code; adding Podman, Docker or vsock must not change the core host operations.

### First product deliverable

From a normal Hollow Lua workflow, a host can list files and run `git status` in a Podman container, WSL distro, or SSH server through the same `host.fs.*` / `host.exec()` contract. No per-operation environment launcher is invoked after connection. Existing panes continue to run through the proven PTY implementations.

## 2. Current Hollow architecture: preserve the good parts

Verified entry points on `feat/improve-api-surface`:

| Current component | Current role | Planned change |
| --- | --- | --- |
| `src/wsl_bypass.zig` | Linux `forkpty`, raw byte relay, resize, child cleanup | **Keep operational**; later extract reusable PTY engine |
| `src/pty/wsl_bypass_protocol.zig` | One-PTY framed stdio protocol | Keep compatible for legacy; introduce a **different** agent v1 protocol |
| `src/pty/pty_windows.zig` | WSL bypass auto-deploy and ConPTY fallback | Leave alone in fs/exec milestones; later add opt-in AgentPty adapter |
| `src/pty/pty_posix.zig` | POSIX PTY implementation | Reuse concepts; do not conflate GUI-local and agent ownership |
| `src/mux/mux.zig`, `src/pane.zig` | GUI-owned panes and layouts | **No structural PTY changes** until late milestones |
| `src/lua/hollow/workspace.lua` | Workspace load/save, project path resolution, WSL UNC logic | Switch project-aware I/O to the selected host, from Lua |
| `hollow.ui.workspace` | `local` / `wsl` / `ssh` special-case resolvers | Replace execution logic with host.fs calls; maintain configuration aliases |
| `hollow.process.spawn/exec` | Existing host-local async jobs | Preserve semantics; add explicit host-aware counterpart |
| `hollow.term.run()` | Promise around a command in an existing shell | Preserve; **not** the same operation as non-PTY host.exec |
| HTP, Hollow CLI | Existing shell-to-GUI communications | Preserve; complementary to agent RPC |

Hollow's existing WSL bypass uses one `wsl.exe`-launched helper **per pane**, which isolates helper failure. The first universal agent should not replace that isolation to solve a filesystem problem.

## 3. Ownership model and architecture

```text
Hollow GUI (Windows, still owns all workspaces and panes)
  ├── Renderer / Ghostty VT / Lua UI / mux
  ├── Existing PTY backends (unchanged initially)
  │     ├── Windows ConPTY
  │     └── WSL bypass (one helper per pane)
  └── Host API dispatcher (small Zig async primitive surface)
          ├── LocalHost: local process/filesystem implementations
          └── AgentHost: framed requests + responses
                    ├── PodmanConnector  -> podman exec -i  -> hollow-agent
                    ├── WSLConnector     -> wsl.exe --exec -> SAME hollow-agent
                    ├── SSHConnector     -> ssh -T         -> SAME hollow-agent
                    ├── DockerConnector  -> docker exec -i -> SAME hollow-agent
                    └── future connector -> vsock/hvsock    -> SAME agent/protocol

Dedicated follow-on research track (§10A), never a prerequisite for fs/exec:
  RemotePtyAdapter -> agent PTY engine -> one or many PTYs per agent connection
  Compare with dedicated connections, split control/data, and legacy bypass
```

### 3.1 Distinguish hosts, domains and panes

- **Host** = execution location and filesystem namespace, identified by stable `host_id` plus a **connection generation**.
- **Domain** = shell, environment, cwd and launch defaults associated with a host. Existing domain names/config remain valid.
- **Pane** = a GUI-managed view with a PTY backend; **not** synonymous with a host connection or agent stream.
- **Agent connection** = an ephemeral control transport used by the host for RPC; it is **not** a persistent session registry.

Internally, the path identity is `(host_id, opaque_path_bytes)`; `"/app"` on `podman:api` is not `"/app"` on `ssh:buildbox`.

### 3.2 Keep the host side thin

In Zig provide only:

- `HostConnection` / `Connector`: establish, close, reconnect, report connection state.
- `AgentTransport`: nonblocking framed reads and writes with request correlation, deadlines and bounded memory.
- `host.exec`, `host.fs.stat`, `host.fs.list`, `host.fs.read` (and later write), delivered through existing async callback / promise machinery.
- Capability/version information, failure reasons and generation tracking.

In Lua keep:

- Workspace discovery and aggregation, caching, project roots, sorting and display.
- Policy for automatic workspace bootstrap, filenames, project descriptors, actions and notifications.
- Mapping a workspace's domain to a host and interpreting returned directory entries.

Do **not** implement a Zig workspace scanner for WSL and a second one for SSH. Zig provides primitives; Lua composes them.

### 3.3 Small initial host API

| Operation | Notes |
| --- | --- |
| `host.info()` | Agent protocol/build/OS/arch, cwd/home, capability flags |
| `host.fs.stat(path)` | File kind, mode, size, mtime; report symlinks explicitly |
| `host.fs.list(path, opts)` | Bounded/paginated directory entries, byte-preserving names |
| `host.fs.read(path, offset, limit)` | Bounded response, raw bytes (large files later streamed) |
| `host.exec({argv,cwd,env,timeout_ms,...})` | Exact argv, separate stdout/stderr, exit status, cancellation |
| `host.fs.write(...)` | **Later**, after read-only operations are proven; no implicit retries |
| `host.process.spawn(...)` | **Later**, only when actual use cases demand streaming non-PTY jobs |
| `host.pty.*` | **Deferred to the last development milestone** |

All remote calls are asynchronous; never block the renderer, frame loop or Lua event callbacks waiting for remote I/O. Preserve existing host-local `hollow.process.*` behavior rather than changing its default host behind users' backs.

## 4. Universal agent: Podman-first validation, not Podman-specific architecture

**Podman is the first test harness** because an automated coding agent can create and destroy deterministic Linux containers, test binaries and protocol recovery, and run the same conformance suite repeatedly. Nothing in the agent should know it is running in Podman.

### 4.1 Why Podman first

- Fast, reproducible test fixtures; no reliance on access to a developer's WSL installation or private SSH machine.
- Easy to simulate a missing binary, incompatible version, read-only directory, process crash and container restart.
- Enables Linux-native protocol/agent testing in CI, plus disposable distro diversity (Debian/Ubuntu, Alpine, minimal/distroless where practical).
- Exercises a genuine connector boundary and file namespace rather than testing the agent only as a local subprocess.
- Reveals the exact coupling the design is supposed to prevent: if the Podman connector needs changes in fs/exec operation code, the abstraction is wrong.

Podman being easiest to **test** does not mean it is the only production environment shipped. The same agent must be verified through WSL and SSH before claiming universal support.

### 4.2 Development/CI fixture

Example commands (illustrative; actual container IDs and paths must come from the harness):

```sh
podman run -d --name hollow-agent-test --entrypoint /bin/sh docker.io/library/alpine:latest -c 'sleep 3600'
# Build agent for the container's target architecture and copy it in:
podman cp ./zig-out/bin/hollow-agent hollow-agent-test:/tmp/hollow-agent
podman exec hollow-agent-test chmod 700 /tmp/hollow-agent
# Harness owns stdin/stdout as binary pipes; do NOT use -t:
podman exec -i hollow-agent-test /tmp/hollow-agent stdio
```

The executable's **stdout is exclusively protocol** and stderr is diagnostic-only. `podman exec -i` keeps stdin attached; `-t` allocates a PTY, combines/changes streams and must not be used for framed binary RPC. Use the actual image/architecture in CI rather than assuming `alpine:latest` is universally available. The production deployment uses a verified, versioned location instead of `/tmp`.

Automated tests should **not** run the final command interactively in a terminal. The test harness launches it as a child with captured binary pipes, sends frames, asserts responses, and kills/restarts the container when testing failures.

### 4.3 Portable conformance suite

Run the *same tests*, changing only connector configuration:

```text
agent-conformance --connector local-subprocess
agent-conformance --connector podman --container hollow-agent-test
agent-conformance --connector wsl --distro Ubuntu
agent-conformance --connector ssh --alias test-ssh
```

For a coding agent's first milestone, run `local-subprocess` and `podman` on Linux. Use a Windows runner or dedicated host for WSL; use a controlled test SSH service/container for SSH. **Do not describe WSL parity as confirmed based on Podman passing.**

Minimum cases: HELLO/capability negotiation, fs.stat/list/read, invalid paths, Unicode and non-UTF-8 paths, arbitrary argv bytes, `cwd`, environment, stdout/stderr separation, nonzero exit, cancel/timeout, concurrent requests, large bounded outputs, partial frames, corrupted frames, mid-request disconnect, hot replacement of the binary, permission failures and container recreation.

### 4.4 Bootstrap options and deployment

For Podman, start with `podman cp` for binary deployment and `podman exec -i` for binary-clean transport. Both are **connector methods**, not fs/exec implementations. Use rootless Podman by default and preserve the container's configured user (don't silently switch to root).

A container may have read-only/noexec filesystem policies or lack a conventional home directory. Report an actionable `agent_install_unavailable`; allow a preinstalled agent path or legacy shell fallback rather than changing container security settings.

## 5. Protocol v1: transport-independent and precise

Start with length-prefixed framing over stdio. The same codec must be usable over local sockets, SSH pipes, and potential vsock/hvsock transports without any environment checks.

### 5.1 Frame layout

```text
payload_length : u32 LE  (bytes after fixed header; hard maximum 1 MiB)
kind           : u8      (HELLO / REQUEST / RESPONSE / ERROR / DATA / ...)
flags          : u8      (v1 MUST be zero; reserved for negotiated extensions)
request_id     : u64 LE  (0 for events with no correlated request)
stream_id      : u64 LE  (0 = connection/control; nonzero = stream)
payload        : bytes   (exactly payload_length bytes)
```

The wire spec must pin field sizes, endianness, valid message/state transitions, endian tests, length overflow rejection, and errors for unknown mandatory kinds and nonzero unnegotiated flags. Do not repurpose `flags` opportunistically later; allocate explicit bits with capability negotiation.

Metadata can use JSON initially; PTY output, stdout/stderr, and file contents use **raw binary DATA**, never JSON-escaped bytes.

### 5.2 IDs, ordering and limits

- `stream_id = 0` is reserved for connection/control requests.
- **Client-initiated streams have even IDs** (`2, 4, 6, ...`). **Server-initiated streams have odd IDs** (`1, 3, 5, ...`). A stream's ID is allocated by its initiator and never reused within one connection generation.
- Requests always have a unique nonzero `request_id` until completed; response IDs echo the request. Exhaustion requires a new connection, never silent wrap/reuse.
- Initial limits: **128 concurrent streams**, **256 in-flight RPCs** per connection. Negotiate lower limits and reject excess with `resource_exhausted` rather than unbounded buffering.
- Maximum frame payload: **1 MiB absolute safety bound**. Maximum **DATA chunk 16 KiB** for PTY and bulk streams; metadata responses should have a smaller configured limit or pagination. Large files require streaming or incremental reads.
- Frames on one transport arrive in byte order; each stream's DATA and its terminal EXIT/CLOSED event must be **delivered to the consumer in order**. On natural process exit, drain accepted PTY bytes and emit EXIT **after** the last DATA for that stream. Never dispatch EXIT ahead of still-queued DATA.
- No cross-stream ordering guarantee; code must not infer that output on stream 2 occurred before output on stream 4 because it was delivered first.
- On explicit *abort*, discard undelivered output and deliver a distinct CANCELLED/CLOSED terminal event. The completion explicitly indicates truncation; **no DATA is emitted after its terminal event**.
- Requests that mutate state must never be auto-replayed after an ambiguous disconnect. Each connection includes a generation/nonce; stale replies cannot attach to newly created panes or hosts.

### 5.3 Example protocol operations

Control: `HELLO`, `HELLO_ACK`, `REQUEST`, `RESPONSE`, `ERROR`, `PING`, `PONG`, `CANCEL`, `WINDOW_UPDATE`.  
Initial operations: `HOST_INFO`, `FS_STAT`, `FS_LIST`, `FS_READ`, `EXEC`.  
Later operations: `FS_WRITE`, streaming `EXEC_DATA/EXEC_EXIT`, `PTY_OPEN`, `PTY_INPUT`, `PTY_OUTPUT`, `PTY_RESIZE`, `PTY_EXIT`, `PTY_CLOSE`.

Use typed errors: `unsupported`, `not_found`, `permission_denied`, `invalid_path`, `invalid_argv`, `timeout`, `cancelled`, `output_limit`, `resource_exhausted`, `transport_disconnected`, `protocol_mismatch`, and `session_gone`. A nonzero process exit is a **successful protocol result** with a nonzero exit status, not an RPC failure.

### 5.4 POSIX path and argv bytes (non-UTF-8 safe)

Linux filenames and argv are **bytes**, not necessarily UTF-8. For v1 JSON control payloads, use explicit base64 byte fields rather than lossy text paths:

```json
{
  "op": "EXEC",
  "argv_b64": ["Z2l0", "c3RhdHVz", "LS1zaG9ydA=="],
  "cwd_b64": "L2hvbWUvbWUvcHJvamVjdA=="
}
```

Likewise `FS_LIST` returns `name_b64`, and env entries use byte-valued key/value representation. Optional validated UTF-8 `display_name` is for UI only and must never be used as a path identity. Reject embedded NUL bytes in argv/path and oversize fields with explicit errors. Lua strings are already byte strings; encode them without assuming UTF-8. If a future codec offers native byte strings (e.g. CBOR), the external Lua contract needn't change.

### 5.5 Per-stream flow control (required for future PTY multiplexing)

**Bounded queues alone are insufficient.** A pane whose GUI consumer stops draining must not stop the agent from serving other panes.

- Establish a **per-stream, per-direction credit window**. Suggested initial outbound credit: **256 KiB** per stream; tune from benchmarks.
- Sending DATA consumes credit. Receiver sends `WINDOW_UPDATE(stream_id, consumed_bytes)` **only after** its consumer actually drains bytes (not merely when the transport parser buffers them).
- When a PTY's outbound credit reaches zero, the agent **stops reading that PTY master**. The child may block naturally on PTY backpressure, but other PTYs and control RPCs remain active.
- Maintain global memory caps in addition to stream caps. Reserve control-plane queue capacity for CANCEL, resize and WINDOW_UPDATE so a blocked data queue cannot deadlock recovery.
- Fairly schedule ready streams; high-priority control and interactive input precede bulk file DATA. The scheduler must not allow one sender to fill the entire kernel pipe with bulk frames.
- Cap **each PTY and bulk DATA chunk at 16 KiB**, since a frame cannot be interrupted once a write begins. Keep writes nonblocking, handle partial writes and do not assume a single `write()` writes the whole frame.
- If same-pipe head-of-line delays exceed performance gates even with credit/fairness, support a **second control connection** (or a dedicated PTY transport). This is a transport detail, not a new RPC protocol.

`WINDOW_UPDATE` semantics are specified now and must be tested in the codec, but the full PTY credit scheduler need not ship until the optional multiplexed PTY milestone. For initial bounded fs/exec results, use capped responses/paginated reads and reject attempts to exceed configured output limits.

### 5.6 Agent child lifecycle, reaping, cancellation

- Use a single process registry, keyed by stable job/session ID plus generation. Never rely on PID alone after reaping or reuse.
- Set up a reliable **SIGCHLD wakeup + `waitpid(-1, WNOHANG)` reap loop**, draining until there are no further exited children; use `signalfd` or a self-pipe/event-loop integration. Signal handlers must do only async-signal-safe operations.
- For non-PTY `exec` create an isolated process group/session when possible. `CANCEL` and timeout send **SIGTERM to the job's process group**, allow **1500 ms** grace, then **SIGKILL**, and reap. Record whether result is cancelled/timed out versus natural nonzero exit.
- For PTY children later, `forkpty()` establishes the controlling-terminal context; terminate the appropriate process group, handle inherited subprocesses carefully, and report POSIX `128 + signal` status where applicable.
- On connection shutdown, cancel outstanding non-PTY jobs by the same policy; never leave processes running silently under a connection-scoped contract.
- If the agent itself is SIGKILLed, it cannot clean up children; a parent-death arrangement (Linux `PR_SET_PDEATHSIG` where appropriate), cgroup containment or supervisor may be required. Test this failure explicitly—stdio EOF alone does not cover agent crashes.
- On graceful PTY close, drain already accepted output to a bounded byte/time budget, then send EXIT/CLOSED after DATA. On abort, discard and report truncation. Never leave buffered data indefinitely waiting for credit after the consumer has detached.

## 6. Failure isolation and shared-fate decision

A **single agent connection** removes redundant `wsl.exe` launches, but if it later owns all PTYs, agent crash/hang/OOM can kill or freeze every pane in that host. The current bypass's **one helper per pane** has better failure isolation. This risk is serious enough to keep PTY migration optional.

### 6.1 Early fs/exec release

- One agent per environment handles **fs/exec only**.
- An agent crash invalidates requests/discovery, **but existing PTYs remain alive** on current backends.
- Reconnect lazily; fail in-flight requests exactly once. Never silently repeat a `write` or `exec` that may already have run.
- Use watchdogs for missed liveness checks and connection stalls; report rather than blocking Hollow's GUI.

### 6.2 If/when agent PTYs are added

Investigate one of these **before** enabling shared PTYs by default:

1. A connection-oriented agent **supervises separately forked PTY workers**, so crashes can be isolated and reported per pane. A supervisor itself must be restartable/recoverable; forking alone does not prevent a supervisor OOM or transport failure from stalling everyone.
2. A small host-local **supervisor/daemon** manages PTY workers while the connection handler is disposable; this makes reconnection and persistence easier but is more code.
3. Keep **per-pane legacy/dedicated transports** for interactive PTYs while using the shared agent for files/processes, if performance or failure isolation warrants it.

The decision requires kill/hang/OOM fault-injection results, not only throughput benchmarks. A watchdog can detect failure, but cannot rescue a PTY master held solely by a dead process.

## 7. Automatic install, versioning and portability

### 7.1 User experience

On first use: connector probes target → finds compatible versioned agent or uploads one → verifies SHA-256 → starts it over binary-clean stdio → negotiates protocol → `Ready`. On subsequent use: launch cached compatible binary. No administrator privileges or service management in supported environments.

### 7.2 Versioned, atomic paths

```text
~/.cache/hollow/agents/linux-<arch>/<binary-sha256>/hollow-agent
```

Probe platform and user-writable executable locations, upload to unique sibling temp name, verify hash, `chmod`, atomically rename, then launch. Avoid replacing a live binary and avoid permanent mutable deployment into `/tmp`. When home/cache is unavailable (minimal containers), connector may use a validated configured writable executable path, a preinstalled binary, or an explicit unsupported status.

**Never execute an unverified upload.** Only install binaries Hollow bundled/verified; the agent does not download unauthenticated self-updates. Version the **wire protocol separately** from Hollow's application release. Negotiate supported major/minor features and operational limits; never infer compatibility from an executable filename alone.

### 7.3 Packaging baseline

Default release artifacts: **statically linked Linux musl `x86_64` and `aarch64` agents**, cross-built by Zig and shipped with Hollow plus SHA-256 manifests. The agent must not link the GUI, Ghostty, Sokol or LuaJIT. Validate with representative Debian/Ubuntu (glibc userspace), Alpine (musl), and minimal images; treat restrictions such as `noexec`/read-only/no-PTY as environment capability failures, not a reason to add per-distro logic to the agent.

If static musl fails for a required feature or platform, document the exact exception and add a target-specific artifact. Support manual agent paths for restricted systems. CI cross-compiles both targets; integration runners execute whichever native target is supported (ARM64 execution requires appropriate hardware/emulation).

### 7.4 Connector contracts and transport

A connector provides: `probe`, `agent_status`, `deploy`, `connect`, `disconnect`, `identity`. It should not implement `fs.list` or `exec` by spawning one process per request.

| Connector | Bootstrap/transport | Portability detail |
| --- | --- | --- |
| `local` | Direct native host implementation or local subprocess | No extra launcher for local Windows |
| `podman` | `podman cp`, `podman exec -i` (no `-t`) | Primary reproducible integration test; rootless preferred |
| `wsl` | `wsl.exe -d <distro> --exec <agent> stdio` | Preserve Linux user and ConPTY-free binary stream |
| `ssh` | SCP/SFTP or checked stdin-upload, then `ssh -T` | Honor SSH config/host-key verification; no new open ports |
| `docker` | `docker cp`, `docker exec -i` | Mirrors Podman without new runtime operations |
| `vsock` / `hvsock` (future) | Host-specific connection establishment | **Only** connector/transport changes; no agent RPC or Lua API changes |

The long-lived SSH agent connection **removes the need to launch SSH for each remote operation**, and avoids relying on Windows OpenSSH's lack of Unix-style ControlMaster multiplexing. Existing SSH authentication and configuration still govern the initial connection. This does **not** promise session persistence if the SSH transport disappears.

Agent transport is abstracted as a reliable ordered byte stream. Stdio is first; later Unix socket, TCP, vsock/hvsock use the same codec. UDP is not planned.

### 7.5 Security

- No unauthenticated listening ports and no privileged installation by default.
- Respect container UID/user namespaces; do not silently run as root or escalate host capabilities.
- Keep bootstrap shell commands minimal, carefully quoted or argument-based and visibly confined to the connector.
- No shell interpretation of `EXEC` argv; use OS exec argv directly.
- Limit payload/frame sizes, path lengths, number of jobs and output volume; prevent decompression bombs (no compression in v1).
- Keep diagnostics on stderr, never protocol stdout; redact credentials/environment secrets from logs.
- SSH never disables host-key verification for automation convenience.

## 8. Lua/config integration and compatibility

### 8.1 Proposed configuration (not implemented)

```lua
hollow.config.set({
  hosts = {
    windows = { connector = "local" },
    podman_dev = { connector = "podman", container = "hollow-agent-test", agent = "auto" },
    ubuntu = { connector = "wsl", distro = "Ubuntu", agent = "auto" },
    buildbox = { connector = "ssh", alias = "buildbox", agent = "auto" },
    docker_dev = { connector = "docker", container = "api-dev", agent = "auto" },
  },
  domains = {
    pwsh = { host = "windows", shell = "pwsh.exe" },
    ubuntu = { host = "ubuntu", shell = "/bin/zsh" },
    container = { host = "podman_dev", shell = "/bin/sh" },
    remote = { host = "buildbox", shell = "/bin/bash" },
  },
})
```

Keep legacy domains and resolver settings functional and migrate internally. A host is the execution location; a domain is the shell/config preset. A workspace does not assume all panes belong to the same host.

### 8.2 Proposed Lua primitives (not implemented)

```lua
local host = hollow.host.get("podman_dev")

hollow.async.run(function()
  local entries = host.fs.list("/workspace"):await()
  local result = host.exec({
    argv = { "git", "status", "--short" },
    cwd = "/workspace",
    timeout_ms = 30000,
  }):await()
  print(result.stdout)
end)

-- Existing pane launch stays on the current PTY backend until the optional migration:
hollow.term.new_tab({ domain = "ubuntu", cwd = "/home/me/projects" })
```

Names and return values are illustrative until locked in the API RFC. One explicit host-aware operation should replace separate `wsl` and `ssh` strategies within workspace discovery. Keep Lua caches and UI logic in Lua, not in the transport layer. File writes and project bootstrap should be migrated after read-only operations are proven.

## 9. PR sequence: fs/exec and portability first, PTYs last

The PRs below are **independently reversible**, with feature flags and their own acceptance tests. PR numbering supersedes the earlier plan.

### PR 0 — RFC, protocol specification and measured baseline

**Implement:** ownership map, connector interface, fixed wire schema/IDs/bytes policy/limits, cancellation/reaping/failure decisions, **reproducible baseline and experimental benchmark harness**, plus the multiplexing experiment matrix (§10A). Identify version matrix and auto-install requirements. Define numeric performance gates **before writing any new PTY path** (see §10).  
**Accept:** a reviewer can identify who owns each resource; all protocol corner cases have a written response; baseline WSL bypass data can be reproduced.

### PR 1 — Universal Linux agent with local-subprocess fs/exec

**Implement:** standalone `hollow-agent` Linux-musl binary; HELLO, `fs.stat/list/read`, `exec`, timeout/cancel, bounded output, child reaping, safe protocol framing; local-subprocess connector for test harness. Build and package x86-64/ARM64. **No PTY support needed.**  
**Accept:** byte-safe paths/argv and cancellation tests pass entirely on Linux without WSL, Windows GUI, SSH or containers. Agent has zero WSL/Podman/SSH conditional branches.

### PR 2 — Podman transport, auto-install and end-to-end conformance

**Implement:** `PodmanConnector`, rootless container fixtures, binary architecture detection, atomic/versioned deployment, SHA verification, `podman exec -i` connection, full fs/exec conformance matrix and failure injection. **This is the first real cross-environment validation.**  
**Accept:** disposable container: install → HELLO → list/read files → execute command → cancel timed-out process → reconnect/reinstall; no `podman exec` per normal operation and no changes to agent operation implementations.

### PR 3 — Thin Hollow host API and Lua migration

**Implement:** small Zig dispatcher/HostManager and async Lua `host.info`, `host.exec`, `host.fs.*` bindings. Move workspace discovery and read-only project queries to generic host operations while preserving old resolver configs. Retain existing PTY code.  
**Accept:** the *same Lua code* lists and executes against a local host and Podman test container. No platform-specific fs/exec branches in workspace Lua modules.

### PR 4 — WSL connector and auto-deployment (fs/exec only)

**Implement:** `WSLConnector` using `wsl.exe` for bootstrap and one long-lived binary-clean control transport; Linux user/distro selection; agent install/version flow; concurrency and reconnect. **Do not change `hollow-wsl-bypass`.**  
**Accept:** WSL project discovery and Git operations use zero per-operation `wsl.exe` calls; existing WSL panes still use the bypass/ConPTY fallback untouched. Same agent conformance suite from PR 2 passes.

### PR 5 — SSH connector and universal production parity

**Implement:** `SSHConnector` using native SSH identities/config and `ssh -T`, install and HELLO; optional controlled SSH-container CI fixture. Keep remote banner/stdout contamination as a clear error.  
**Accept:** the same Lua fs/exec code and conformance tests pass on Podman, WSL and SSH without introducing per-environment operation handlers. Long-lived connection avoids per-op SSH and does not depend on OpenSSH ControlMaster.

### PR 6 — Docker connector, hardening and fs/exec release gate

**Implement:** minimal Docker connector reusing Podman pattern; watchdog/liveness, connection generation, failure diagnosis, security audit, resource caps, release/docs matrix and legacy fallbacks. Add vsock/hvsock design-test fixture (mock connector) to prove interface independence.  
**Accept:** fs/exec is reliable and releasable independently of any PTY migration. Podman integration tests run automatically; WSL/SSH supported runners or controlled manual qualification are documented. Docker requires no agent/core operation changes.

### PR 7 — Extract reusable POSIX PTY engine (separate, no behavioral switch)

**Implement:** refactor `forkpty`/resize/reap/process groups from `src/wsl_bypass.zig` into a **transport-agnostic library**, retaining the existing helper on its legacy protocol. Engine APIs do not assume they are connection-scoped; an eventual daemon may embed the same engine.  
**Accept:** all existing WSL bypass tests and performance benchmarks remain unchanged; no user sees a new PTY backend by default. Failure isolation remains one bypass helper per pane.

### PR 8 — Multiplexed agent PTY research prototype (explicit development goal)

**Implement:** optional PTY RPCs, stream windows, fair scheduler, ≤16 KiB DATA chunks, `AgentPty` bridge into GUI PTY interface, child supervisor/watchdog strategy, kill/hang/OOM injection tests and WSL terminal parity suite. **Build and measure multiple competing transport modes rather than assuming the single shared stream is best** (see §10A): one connection per PTY, one connection for all PTYs, and split control/data connections. Keep Ghostty parsing local.  
**Accept:** multiple agent PTYs work in Linux/Podman tests; WSL performance experiments yield comparable measurements for every mode; shell/HTP events, Neovim, alternate screen, mouse, bracketed paste and resize work; PTY shared-fate/failure behavior is documented. This is an experiment, not a default-backend rollout.

### PR 9 — Multiplexed PTY optimization, qualification and decision

**Implement:** run the complete §10A experiment matrix (**10/25/50 sessions, 3–5 panes each, active-pane/session priority**, idle/concurrent load, blocked consumer, bulk transfers, input/resize priority, pane start-up, fault injection). Optimize the shared scheduler and transport, compare against dedicated connections and the legacy bypass, and publish measurement artifacts. Decide among (a) shared multiplexed PTY connection, (b) separate control + PTY transports, or (c) dedicated/per-pane PTY transports. Roll out behind an explicit flag **only if** parity/fault-isolation gates pass.  
**Accept:** numeric requirements in §10 and the reproducibility requirements in §10A are met. If the first shared-connection design fails, retain the research findings and pursue the best next experiment without blocking fs/exec or removing the bypass. A multiplexed PTY design becomes the default **only** after it outperforms or meets the existing backend on critical metrics.

### Future: optional daemon / persistence

Only when justified, introduce local supervisor/daemon ownership, session attach/detach, screen replay or snapshot recovery. This is **not** an acceptance condition for the universal fs/exec agent.

## 10. Performance specification and release gates

Capture all baselines in PR 0 using today's WSL bypass on identical hardware and workloads. New PTY code is not accepted merely because it is subjectively fast. Distinguish host/transport delay from renderer/frame delay; report p50/p95/p99 and sample counts, both idle and under load.

| Metric | Required gate for agent PTYs versus legacy WSL bypass |
| --- | --- |
| **Input-to-echo latency**, idle | **p99 excess ≤ 2 ms**; measured at transport/VT intake boundary with repeatable local echo workload |
| **Input-to-echo latency**, loaded | **p99 excess ≤ 5 ms** while ≥4 PTYs are active and one streams heavy output or bounded fs reads |
| **Time to first prompt**, warm | p95 ≤ **max(1.10 × bypass p95, bypass p95 + 50 ms)**; measure connection reuse; cold install reported separately |
| **Large-output throughput** | ≥ **95% of bypass throughput** draining 10 MiB and 100 MiB `cat`-like outputs |
| **GUI interactivity** | No sustained frame-loop stalls caused by transport; record p99 frame time and dropped/waiting frames and reject obvious regressions |
| **Memory/backpressure** | Bounded memory with a stopped consumer; other stream/control operations complete within specified test timeout |
| **Failure isolation** | Killing or OOMing one PTY worker does not silently terminate unrelated panes; agent/transport failure is visible, bounded and recoverable where ownership permits |

These values are **engineering acceptance targets, not measured claims**. Measure p99 against thousands of samples, same build flags, renderer settings and Windows/WSL load; use a loopback echo test plus real Neovim input under output stress. If the hard targets cannot be achieved, do **not** weaken the baseline quietly—keep the bypass and document the architecture tradeoff.

For fs/exec, measure cold/warm `HELLO`, `fs.list`, small/large `fs.read`, and `exec` latency against repeated `wsl.exe` invocations. Expected improvement is fewer launch overheads, but benchmark rather than assume. Crucially, **fs/exec deployment is not blocked by future PTY performance**.

## 10A. Multiplexed PTY agent: architecture experiments and performance research track

**Status: a committed design/exploration goal, not part of the first fs/exec release.** The goal is to learn whether a single **long-lived agent can efficiently serve multiple PTYs** while retaining Hollow's low-latency behavior and enabling portable session backends. A failed first prototype is not a reason to discard multiplexing; it is evidence for choosing a different scheduler, transport layout, or failure boundary. Conversely, do not replace a faster, more isolated bypass just to satisfy the architectural goal.

### 10A.1 Hypotheses to test, not assumptions to bake in

1. A warm, shared agent avoids one `wsl.exe` startup and one Linux helper per pane, reducing **additional-pane start time** and total helper/process overhead for N panes.
2. Raw VT forwarding through a framed router is cheap compared with tmux-style terminal parsing/redrawing, *provided* the agent does not interpret terminal sequences and the GUI still runs Ghostty's VT parser.
3. Multiplexing introduces **contention that doesn't exist in per-pane pipes**: shared write serialization, queued bulk data, flow-control stalls, scheduler latency and shared-agent failure. Whether these costs matter at p99 must be measured, especially while Neovim is interactive.
4. A common agent process may improve RPC latency and deployment without improving PTY latency. The fs/exec win and the PTY hypothesis are **independent results**.
5. A **single agent per host** is an administrative choice, not a mandate to share one data pipe or failure domain. Keep the protocol capable of multiple transport sessions and per-PTY workers.

### 10A.2 Experimental layouts (implement behind one backend selector)

```text
A. CURRENT BASELINE — legacy WSL bypass (one helper + one pipe pair / PTY)
   Hollow GUI ── wsl.exe ── bypass ── PTY 1
              └─ wsl.exe ── bypass ── PTY 2

B. CONTROLLED AGENT BASELINE — agent protocol, dedicated PTY transports
   Hollow GUI ── control connection ── agent
              ├─ transport 1 ── PTY worker 1
              └─ transport 2 ── PTY worker 2

C. FULL MULTIPLEXING — one connection carrying all PTY/control/bulk streams
   Hollow GUI ══ [framed shared byte stream] ══ agent ── PTY 1 ... PTY N

D. SPLIT CONTROL / DATA — shared agent, independent priority lane
   Hollow GUI ══ [input/resize/control] ══ agent
              ╚═ [multiplexed output + fs bulk] ══ agent ── PTYs

E. HYBRID — shared fs/exec agent; performance-sensitive PTYs dedicated
   Hollow GUI ══ agent control (fs/exec) ══ agent
              └── dedicated bypass/PTY links for terminal streams
```

The diagrams describe **candidate arrangements**, not existing code or guaranteed SSH/WSL transport capabilities. Mode D's extra channel may require an extra OS pipe, a second `wsl.exe`/SSH connection, or local sockets; account for its actual bootstrap and resource overhead. Mode B isolates *transport contention* from *agent framing cost*. Mode E is a valid product outcome, not a research failure.

**Shared PTY engine:** factor `forkpty`/read/write/resize/exit handling into a standalone Zig library that accepts an allocator, event-loop hooks and callbacks. It must not assume an RPC connection lifetime. Both a connection-scoped test agent and a future supervising daemon can embed it. Support multiple child handles, bounded per-PTY queues and independent lifecycle. The agent should forward bytes, not build a terminal screen, parse OSC/CSI, or own GUI layout.

### 10A.3 Scheduling and credit-window experiments

The first multiplexing scheduler should deliberately prioritize correctness and observability over speculative optimization. **The GUI's focused workspace/session and focused pane are explicit inputs to the scheduler**, not inferred from traffic volume:

- **Per-stream window/credit:** the GUI grants credit only after bytes have been accepted into a *bounded downstream consumer buffer*. When credit is exhausted, stop reading **that** PTY master, not all PTYs. Provide `WINDOW_UPDATE` based on consumed/accepted bytes; never grant credit merely because a protocol frame has been parsed if downstream can still block indefinitely.
- **Separate reservations:** bound each stream's pending bytes and enforce a global cap, but reserve capacity for control traffic (`CANCEL`, `WINDOW_UPDATE`, close, input/resize). A stuck bulk transfer must not prevent cancellation or resizing another pane.
- **Fairness / focus:** compare simple round-robin, weighted round-robin and **hierarchical active-session priority** scheduling; lower-priority panes must make progress under sustained focused-pane activity. The agent must not infer focus from which stream is loudest. Use a maximum **16 KiB PTY or bulk DATA payload** and nonblocking, partial-write-aware I/O. Track how much queued data lies ahead of an interactive message. A frame already partially written cannot be preempted; prioritization starts at the *next* frame boundary.
- **Backpressure tuning:** run experiments with initial windows of **64 / 256 / 1024 KiB per PTY**, then tune update frequency and high/low-water marks. These are **test parameters**, not final protocol constants. Measure throughput, p99 response and allocations; prevent one high-volume stream from monopolizing the socket/pipe.
- **Flow-control edge cases:** pause the GUI's consumption of PTY A indefinitely while typing in PTY B and running a file operation on the same host. PTY B and the control plane must continue promptly. Exercise close/cancel and `WINDOW_UPDATE` on a zero-credit stream; test stream closure while output is in flight.
- **Ordering:** per-stream DATA must precede natural EXIT; abort must report truncation and never deliver output after CLOSED. Avoid cross-stream ordering dependencies. Detect output loss, duplicate bytes and accidental interleaving with checksums/sequence counters in test-only instrumentation.

### 10A.3A Event-driven execution: 200 PTYs do not mean 200 threads

**Session means the GUI's logical workspace/session grouping; PTY means an independent subprocess with a PTY master FD.** One logical session may contain 3–5 panes, so the required **10 / 25 / 50 session** benchmark represents roughly **30–50 / 75–125 / 150–250 PTYs** (a fixed four-pane profile is 40 / 100 / 200 PTYs). All of those can reside on one Linux agent for a deliberate worst-case test, while real deployments may spread sessions across different hosts/agents. The GUI still owns workspaces and tab layouts.

Do **not** allocate a thread per session or per PTY by default. On Linux, start with a **single nonblocking `epoll` I/O loop per agent**, watching: all PTY master FDs; agent stdin for framed GUI commands; agent stdout for writable readiness; and SIGCHLD notification via `signalfd`/self-pipe. An `epoll` wakeup dispatches bounded work from a ready FD and returns to the scheduler. Each PTY remains an OS process/process group, with independent exit and flow-control state. This is an event-loop hypothesis to benchmark; add I/O threads only when CPU profiles identify an actual bottleneck.

An agent stdio connection is **two independent byte streams**: GUI → agent stdin and agent stdout → GUI. The GUI sends `PTY_INPUT`, `PTY_RESIZE`, `FOCUS_UPDATE`, `WINDOW_UPDATE` and control frames into stdin; the agent sends `PTY_OUTPUT`, completion and filesystem data through stdout. All frames carry `stream_id` and length, so the client demultiplexes to the right pane. **Only one writer owns agent stdout** (or an equivalent serialization lock), so frame bytes cannot interleave. Nonblocking writes must handle `EAGAIN` and partial frames; a partially written frame must be finished before switching streams. Multiple producer threads must never write framed stdout concurrently.

```text
  GUI: 50 logical sessions × 4 panes = 200 panes
           ├── stdio stdin  → framed input / focus / resize / credit
           └── stdio stdout ← framed, priority-scheduled output
                                 │
                      ONE agent epoll event loop
                        ├── PTY master FD #1   → zsh
                        ├── PTY master FD #2   → Neovim
                        ├── PTY master FD #3   → build
                        └── PTY master FD #200 → shell
```

Do not execute long-running directory scans, blocking network-filesystem calls or wait-for-process operations on that I/O loop. Initial fs/exec should already use async/bounded dispatch; when combining it with agent PTYs, prefer bounded worker processes or carefully isolated workers. **Beware `forkpty()` in a multithreaded process**: after `fork()` in the child, avoid non-async-signal-safe activity before `exec()`, or use an isolated single-threaded PTY spawning supervisor. `epoll` reduces sleeping-thread overhead but does not eliminate OS limits (FD counts, PTY counts, child memory, WSL scheduling, per-process resource limits). Expose those limits in `HOST_INFO` and report allocation failures.

### 10A.3B Focus-aware scheduling over a single stdio output pipe

Focus is a GUI/UI fact, not a shell property. On active pane or logical session changes, send a small **`FOCUS_UPDATE { generation, sequence, active_session_id, active_stream_id }`** control message; IDs are scoped to that host/connection. `sequence` prevents delayed focus changes from overriding newer ones. The agent uses this metadata *only for prioritization*, never to own workspace layout. Priority applies **first across sessions, then across the panes of each session**.

Suggested starting classes (tune from evidence, not a compatibility promise):

| Class | Example | Candidate scheduling weight |
| --- | --- | --- |
| P0: control | CLOSE / CANCEL / resize / WINDOW_UPDATE / focus | Service promptly, rate-limited to resist starvation |
| P1: focused pane | Neovim where the user is typing | 16 |
| P2: other panes in active session | Live build / tests / shell in same workspace | 4 |
| P3: background sessions | Shells and watchers in other workspaces | 1 |
| P4: bulk RPC data | Large file downloads and exec-output streams | Lowest; explicit throughput floor when idle capacity exists |

Test **hierarchical deficit round robin** (DRR) or weighted fair queuing at frame boundaries, not absolute P1-first priority that can starve other sessions. Cap each dispatch cycle's per-stream output budget, and ensure background streams make progress when they have credit. Control traffic is prioritized in *its transmission direction*; because stdio is full duplex, focus/input frames GUI→agent do not directly wait behind output frames agent→GUI, but GUI input queuing and the agent's stdout backlog can still add latency. Keep buffers small enough that the OS pipe isn't filled with already committed low-priority output. Choose **4 / 8 / 16 KiB** maximum frame payloads as experiment variables, with **16 KiB as a hard ceiling**, and track time blocked on a partial frame.

Use credit per stream: a background pane with exhausted GUI credit stops being read, **without starving other PTYs**. The GUI must continue consuming/parsing enough background output to maintain useful progress without spending foreground rendering time on invisible panes; `WINDOW_UPDATE` must reflect downstream consumption, not a mere protocol decode. Treat GUI render scheduling (focused pane first) as a **separate benchmark variable**; agent priority alone cannot fix a saturated GUI parser or renderer.

A shared stdout pipe remains a serialization point even with perfect `epoll` and DRR. If the 50-session trials show unacceptable p99 stalls, compare the same agent with **a second control lane**, **a separate bulk lane**, and **dedicated streams for focused panes**. Keep those transport choices behind the connector/PTY backend, not workspace policy.

### 10A.4 Benchmarks: workloads and measurement locations

Build a reusable `agent-bench` harness (Zig CLI or lightweight standalone test executable) that can run in `local-subprocess` and Podman on Linux **first**. The same script/harness then runs against real Windows + WSL for final performance qualification; Linux/Podman numbers alone **cannot** prove WSL input latency. Avoid benchmarking the GUI while a CI machine has uncontrolled competing workloads.

| Workload | What it isolates | Modes / conditions |
| --- | --- | --- |
| **Keystroke-to-echo probe** | Interactive input transport and scheduling | A/B/C/D; idle, 4/8/16 panes, then **10/25/50 sessions**; 5,000+ focused echo samples per run |
| **Neovim editing & rapid scrolling** | Real-world VT bursts, alternate screen, interactive rendering | A/C/D/E; latency + visible frame pacing; paste and syntax-highlighted redraws |
| **Large PTY output (`cat`-like)** | PTY drain throughput and CPU overhead | 10 MiB and 100 MiB fixed binary-safe output; one and four simultaneous producers |
| **Noisy-neighbor load** | Cross-stream head-of-line blocking | One PTY floods output, another echoes short keystrokes; repeat with 8 PTYs |
| **Bulk file concurrency** | fs/exec DATA competing with interactive PTYs | Continuous large `fs.read` and `exec` output while typing and resizing |
| **Stalled GUI consumer** | Per-stream flow control and isolation | Pause PTY A's drain for 2–10 seconds; verify PTY B and RPC progress |
| **Pane creation / first prompt** | Warm connection reuse versus helper startup | Open 1, 4, 8, 16 panes sequentially and concurrently; separate cold and warm |
| **Rapid resize + input** | Priority control traffic responsiveness | Burst `PTY_RESIZE` and input while output saturated |
| **Disconnect / crash / OOM** | Shared-fate and recovery | Kill one worker, agent, bridge and container; force heartbeat timeout |
| **Idle memory and CPU** | Cost of N live inactive shells | N = 1, 4, 8, 16, then 10/25/50 sessions × 3–5 panes; measure agent + helpers + child shells separately |

#### Mandatory 10 / 25 / 50 session scalability and priority matrix

The benchmark must exercise **logical sessions/workspaces**, *not merely* 10/25/50 PTY streams. Use a deterministic topology with a mix of panes in **every** session: an interactive echo/shell pane, a VT-heavy Neovim-like redraw pane, a periodic watcher pane, and a bursty `cat`/build-output pane. Run a fixed **4-pane profile** for direct comparison: **10 × 4 = 40**, **25 × 4 = 100**, and **50 × 4 = 200** simultaneous PTYs. Add irregular **3–5 panes per session** to detect hidden assumptions about uniform groups. Use a small number of real Neovim instances plus deterministic VT generators for repeatability and machine capacity; then perform a real-world Neovim qualification run.

For each of 10, 25 and 50 sessions, run all of the following against the legacy per-pane bypass baseline, shared-agent multiplexing and (when ready) split/hybrid variants:

| Scenario | Focus and background workload | Primary signal |
| --- | --- | --- |
| **All idle** | Focused echo pane; other panes open but mostly idle | Baseline p99 and idle CPU/RSS/FD footprint |
| **10% noisy** | Roughly 10% of background panes generate sustained output | Focused p99 and scheduler queue delay |
| **50% noisy** | Half of background panes emit intermittent VT bursts/build output | Focused p99, aggregate throughput and fairness |
| **All busy** | Every session has at least one continuous producer; active pane still echoes | Overload response and bounded memory, worst-case p99 |
| **Bulk RPC mixed** | `fs.read` + 1–4 large `exec` outputs compete on same connection | PTY priority over bulk DATA |
| **Stalled consumer** | One *inactive* PTY has zero credit; others run normally | No head-of-line deadlock; unaffected focused latency |
| **Rapid focus switching** | Switch focus across sessions and panes repeatedly under load | Time from FOCUS_UPDATE to change in scheduler priority; stale focus suppression |
| **Background fairness** | Continuous active output and lower-priority output at the same time | Nonzero background progress; no indefinite starvation |
| **Resizes and closures** | Resize active pane, close background panes, reap children during load | Control delay and exit ordering; no zombie buildup |

**Quantitative pass/fail requirements (proposed, before measurement):** For 10/25/50 sessions, focused pane p99 transport input-to-echo **must be no more than +5 ms versus the per-pane-bypass baseline at the same load**, and idle overhead must remain **≤ +2 ms**. This is intentionally strict: if 50 sessions make a single stdout pipe miss the gate, record that as evidence for split/hybrid transport rather than weakening the requirement or declaring multiplexing 'fast enough'. Warm time-to-first-prompt and output throughput must meet §10 where applicable; report **per-stream throughput and aggregate throughput separately**, since aggregate bandwidth is finite and a single busy pane cannot be promised 95% throughput while 200 others are also busy. Demand **zero background starvation** (monotonic delivered bytes in every continuously ready, credited background stream during a bounded sustained test), bounded queues/RSS and zero frame/data corruption. Track `FOCUS_UPDATE` scheduler application delay p99, frame-size-induced head-of-line waits, and agent event-loop dispatch delay. Treat any starvation or multi-second interactive stall as a release blocker even if median latency is acceptable.

Also test the **same sessions distributed across multiple agents/hosts** to distinguish single-agent scalability from GUI/render scalability. Record machine CPU saturation and resource-limit failures independently, and do not mislabel hardware capacity limits as wire-protocol failures. Run headless transport harness tests under rootless Podman first, then real Windows/WSL GUI tests for final qualification.

**Timing methodology:** Record input dispatch and corresponding echoed bytes on the **same clock in the GUI/test client**, as a monotonic input-to-consumption latency; do not subtract timestamps from unsynchronized Windows/Linux/SSH clocks. Mark each injected echo with a unique token so heavy output cannot cause false matches. Separately record agent-local monotonic spans (read, enqueue, schedule, write) to locate stalls, and GUI parser-to-present spans to distinguish network/IPC latency from renderer work. Use a transport-only harness *and* end-to-end Hollow GUI runs.

Capture all of: p50/p95/**p99** input-to-echo, worst-case tail, pane time-to-first-prompt (warm and cold), PTY output MiB/s, CPU time/MB, context switches/wakeups, allocations and queued bytes, high-water marks, process RSS, frame-time p95/p99 and failures/truncations. Measure the **extra cost versus A**; report absolute times too. Use release-optimized builds with identical Hollow, fonts, renderer options, power settings and workloads. Warm caches where testing steady state. Repeat **at least 5 independent runs**, preserve raw samples and report median run plus between-run variability. Note background WSL/Windows load and the connector in every report.

Instrumentation counters in the agent should include: `bytes_in/out`, `frame_count`, `active_streams`, `queued_bytes_by_stream`, `credit_starvation_duration`, `scheduler_wait_ns`, `control_queue_wait_ns`, `short_write_count`, `dropped_or_rejected_bytes` (expected zero except explicit abort), child exit/reap lag and reconnect count. The renderer already has performance instrumentation; use it to verify the agent is not mistaken for the rendering bottleneck. Instrumentation itself must be bounded and benchmarkable with telemetry enabled/disabled.

### 10A.5 Experiment ladder and stop/go gates

The experiments are deliberately ordered from low-risk isolation to real-world deployment. PR 7 extracts reusable PTY code but keeps the bypass behavior. PR 8 runs experiments; PR 9 optimizes and qualifies the winner.

| Experiment | Method | Decision / artifact |
| --- | --- | --- |
| **E0 — Reproducible legacy baseline** | Instrument current bypass on Windows/WSL, record PR-0 workloads and variability | Locked reference dataset with source revision and exact runner hardware |
| **E1 — Agent PTY without sharing** | Dedicated agent PTY transport per pane using new engine/protocol | Isolate framing/agent engine overhead from multiplexing overhead |
| **E2 — N:1 multiplexed transport** | Run 1/4/8/16 panes, then **10/25/50 sessions × 4 panes** over one stdio in Linux/Podman | Validate ordering, credit, no interleaving, resource scaling to 200 PTYs |
| **E3 — Noisy-neighbor stress** | Saturate PTY A and fs bulk while probing PTY B under zero/low credit | Quantify p99 spikes, fair scheduling and deadlock prevention |
| **E4 — Active-session scheduling / channels A/B** | Compare round-robin, weighted session/pane priority (DRR), focus switching, 4/8/16 KiB chunks, split control/data | Quantify focused-pane p99 at 10/25/50 sessions and background fairness |
| **E5 — Real WSL parity** | Run same workload against A/B/C/D on the user's Windows/WSL stack | Enforce input latency, throughput, first prompt and renderer gates |
| **E6 — Fault domains** | Kill worker / agent; hang agent; force memory pressure; disconnect stdout | Document independent-pane survival, detection and recovery limits |
| **E7 — Opt-in dogfood** | Work normally in Neovim, shell, build tools for an extended test cycle | Record regressions; keep instant revert to legacy backend |

**Qualification thresholds (from §10 and §10A.4):** scale tests include **10/25/50 sessions × 4 panes**, with focused echo and multi-pane background loads; idle input-to-echo **p99 delta ≤ 2 ms** versus A; loaded **p99 delta ≤ 5 ms**; 10/100 MiB PTY throughput **≥ 95%** of A; warm p95 time-to-first-prompt **≤ max(1.10 × legacy, legacy + 50 ms)**; memory is bounded, zero-credit stalls are contained, no unexplained loss/reordering, and failure behavior is explicit. These are provisional engineering gates established *before* the experiment and can be adjusted only with documented data and rationale. Monitor worst-case latency spikes even if p99 passes.

**Outcome policy:**

- **C passes all gates:** keep it opt-in through a soak period, then consider shared multiplexed PTYs as default on qualified environments. Continue supporting a dedicated transport as a fallback.
- **C fails but D passes:** choose split control/data or dedicated transport for latency-sensitive traffic; it is still a **multiplexed agent** architecture, without putting every byte on one pipe.
- **Neither C nor D passes:** retain the legacy bypass/default dedicated PTYs and ship the universal fs/exec agent. Keep the agent PTY engine and measurement work as a usable research result; propose the next measured optimization rather than forcing migration.
- **Latency passes but failure isolation fails:** do not default to shared PTY ownership; investigate per-PTY workers or a restartable supervisor. Detection alone is insufficient for persistence/survival.

A watchdog can detect agent failure, but **cannot preserve PTYs whose master file descriptors die with the agent**. True detach/reattach requires different resource ownership (a supervisor/daemon holding the PTYs) and a screen/output recovery design; that belongs to the later persistence track, not a claim of this prototype.

### 10A.6 Deliverables and reproducibility

Each experiment must produce a machine-readable dataset (`JSONL` or CSV), build SHA/commit, environment manifest, exact test command, counters/latency distribution, and a short **keep/change/reject** conclusion. Publish side-by-side graphs for input latency by pane count and loaded/unloaded mode, output throughput, memory/cpu scaling and fairness under noisy-neighbor tests. Do not cherry-pick a fast run or compare a warm agent to a cold legacy launch without labeling the distinction.

The research milestone is **complete when a decision can be made from evidence**, even if the best choice is a hybrid. The product milestone (making multiplexing the default) has a stricter performance and failure-isolation gate. This keeps multiplexing an active, testable ambition without putting Hollow's existing performance at risk.

## 11. Test and CI matrix

| Test | Linux subprocess | Podman | WSL | SSH | Docker |
| --- | --- | --- | --- | --- | --- |
| HELLO/version/limits | PR 1 | PR 2 | PR 4 | PR 5 | PR 6 |
| Byte-safe fs.stat/list/read | PR 1 | PR 2 | PR 4 | PR 5 | PR 6 |
| exec cwd/env/exit/timeout/cancel | PR 1 | PR 2 | PR 4 | PR 5 | PR 6 |
| Concurrent RPC / EOF / reconnect | PR 1 | PR 2 | PR 4 | PR 5 | PR 6 |
| Auto-install / bad hash / atomics | N/A | PR 2 | PR 4 | PR 5 | PR 6 |
| Agent crash / hung process / OOM | PR 1 | PR 2 | PR 4 | PR 5 | PR 6 |
| Two+ agent PTYs / flow-control stress | PR 8 | PR 8 | PR 8 | PR 8 | optional |
| Legacy WSL bypass regression | N/A | N/A | every PR; numeric gate PR 9 | N/A | N/A |

Additional adversarial tests (also exercised by the dedicated multiplexing experiments in §10A):

- Frame fragmentation at every byte boundary, zero-length payloads, invalid frame lengths, unknown flags/kinds, duplicate IDs, unsafe unwraps and buffer exhaustion.
- Stalled GUI consumer for one stream while another stream remains interactive; no block/deadlock at zero credit.
- Active bulk transfer plus 4–8 concurrent PTYs; **also run 10/25/50 sessions × 4 panes (40/100/200 PTYs)** with hierarchical active-session priority, repeated focus switches, and background fairness.
- Non-UTF-8 filenames, names containing quotes/spaces/colons, argv shell metacharacters, embedded-NUL rejection, symlink policy, huge directory pagination.
- SIGTERM/SIGKILL escalation and SIGCHLD reaping with dozens of concurrently exiting children; no leaked zombies or orphaned process groups.
- Container restart and auto-install mismatch; SSH disconnect; WSL shutdown; subprocess cancellation race and reload generation changes.
- CI marks unavailable runners **skipped/not verified**, not “passed.” A local AI coding agent can validate Linux/Podman thoroughly; real Windows WSL latency and platform behavior still require a Windows target.

## 12. Risks and mitigations

| Risk | Mitigation / release rule |
| --- | --- |
| **Shared fate: one agent crash, hang or OOM affects all agent-owned PTYs** | Keep legacy PTYs until late phase; supervisor/worker isolation, watchdog, fault-injection gate; preserve dedicated PTY option |
| One stopped consumer stalls every pane on one connection | Per-stream **credit/window updates**; stop reading that PTY master when credit exhausted; reserved control capacity |
| Active session loses responsiveness to 50 background sessions | GUI-driven focus hints; hierarchical DRR priority, GUI-side focus-first consumption/rendering, 40/100/200-PTY workload and p99 gate |
| Head-of-line blocking from large serialized frames | **≤16 KiB PTY/bulk DATA chunks**, fair scheduling, nonblocking I/O; separate control transport if p99 gate fails |
| Agent protocol complexity becomes a second terminal emulator | Raw VT bytes only; rendering/screens stay local; no persistent screen engine in v1 |
| Host architecture becomes too large in Zig | Keep host Zig primitives thin; host-specific discovery/workspace policy in Lua |
| Podman passing hides WSL/SSH differences | Universal conformance suite and explicit platform-specific qualification gates |
| Static agent fails in minimal/restricted images | musl artifacts; ABI/container matrix; `agent_path` / unsupported fallback, no privilege elevation |
| Stale replies target newly reused sessions | Connection generation + unique request/stream IDs, never recycle within generation |
| Agent install updates running binary | Hash-scoped immutable paths, checksum verification, atomic rename and bounded cache cleanup |
| Process cancellation leaves grandchildren | Process groups; SIGTERM → 1500 ms → SIGKILL; SIGCHLD reap loop; agent-death containment tests |
| Unbounded output/file operations exhaust memory | Bounded capture, pagination, stream credit/limits, protocol error instead of unbounded growth |
| Optimizing for persistence derails immediate win | Connection-scoped fs/exec now; reusable PTY library later; daemon explicitly future |
| VSock/hvsock or Podman requires core special cases | Connector abstraction test: **zero new `if (podman)` / `if (vsock)` outside connector/bootstrap** |

## 13. Completion criteria and architectural decision gate

**Universal fs/exec milestone is complete when:**

1. The **same agent source, binary artifact by architecture, framing, and operation handlers** work via local subprocess, Podman, WSL and SSH; no per-environment variants of `FS_LIST` or `EXEC`.
2. One live connection serves repeated fs/exec requests without relaunching `podman`, `wsl.exe`, or SSH for each request.
3. Lua workspace discovery and read-only project lookup use host-aware fs operations; project policy remains in Lua; no UNC path normalization inside remote filesystem code.
4. Automatic checksum-verified versioned deployment, reconnection and explicit errors work in supported targets.
5. Current WSL PTYs **continue using the existing bypass**, with no terminal responsiveness or lifecycle regression.
6. CI conformance passes in Linux subprocess and Podman; WSL/SSH verification status is explicit and required before advertising those targets as supported.
7. Connecting a mocked vsock/hvsock transport or implementing Docker requires only a new connector and no change to agent RPCs or Lua operations.

**Multiplexed agent PTY research milestone is *separately* complete only if:**

- Per-stream credit/backpressure and ≤16 KiB scheduling pass stress tests.
- Reaping, cancellation, output-before-exit ordering and shared-fate recovery are verified.
- The competing transport/scheduler designs in §10A have reproducible **10/25/50-session** benchmark datasets, including **focused-pane priority and background fairness**, and explicit pass/fail outcomes against numeric performance thresholds.
- Making multiplexed PTYs **the default** requires those thresholds to be met against the existing WSL bypass; the *research milestone itself* can complete with a justified hybrid/dedicated-transport outcome.
- The project retains a per-pane/dedicated transport option if a shared stream remains worse.

## 14. First coding-agent assignment (bounded, verifiable)

Give a coding agent this single initial implementation task instead of requesting a sweeping mux rewrite:

> Build `hollow-agent` as a standalone statically linked Linux musl x86-64/aarch64 Zig program. Define and test protocol v1 HELLO, FS_STAT, FS_LIST, FS_READ, EXEC and CANCEL with length-prefixed frames and byte-safe metadata. Add a local-subprocess conformance test harness and a Podman integration fixture using `podman exec -i` (never `-t`). Verify automatic deployment with a versioned checksum path, cancellation/reaping, reconnection, non-UTF-8 paths and malformed frames. Do not modify `src/pty/pty_windows.zig`, `src/wsl_bypass.zig`, `src/mux/mux.zig`, or switch any user PTYs. Report actual test commands/results and note platform tests that cannot run.

On passing that, proceed to **thin Lua host bindings**, then WSL and SSH connectors. Only after fs/exec is stable should anyone touch the universal PTY engine. **Then explicitly execute the §10A multiplexing experiments** rather than treating them as an optional footnote.

**Architectural pass/fail test:** If adding Podman, Docker or future vsock/hvsock requires edits to the agent's filesystem/process handlers, workspace policy in Zig, or the visible PTY mux, the boundary is not yet clean enough.

---

## References and validation notes

- [Hollow feature branch](https://github.com/sudo-tee/hollow/tree/feat/improve-api-surface)
- [Current WSL bypass source](https://github.com/sudo-tee/hollow/blob/feat/improve-api-surface/src/wsl_bypass.zig)
- [Current WSL bypass protocol](https://github.com/sudo-tee/hollow/blob/feat/improve-api-surface/src/pty/wsl_bypass_protocol.zig)
- [Current Windows PTY implementation](https://github.com/sudo-tee/hollow/blob/feat/improve-api-surface/src/pty/pty_windows.zig)
- [Current Lua workspace implementation](https://github.com/sudo-tee/hollow/blob/feat/improve-api-surface/src/lua/hollow/workspace.lua)
- [Podman exec documentation](https://docs.podman.io/en/v5.3.0/markdown/podman-exec.1.html): `-i` preserves stdin, `-t` allocates a PTY that can alter combined/redirected byte streams.
- [Podman cp documentation](https://docs.podman.io/en/v5.0.1/markdown/podman-cp.1.html): copying artifacts between host and container.

All snippets and numerical thresholds above are proposed, not statements that Hollow currently implements them. No repository code has been changed and no Podman/WSL/SSH integration tests have been executed as part of this planning document. This v3 update adds an explicit multiplexed-PTY experiment track, not measured evidence of its performance.
