# `hollow.host`

Asynchronous connector API for executing commands and accessing files on a host
managed by Hollow's native host bridge. Fs/exec release checks are independent
of experimental PTY rollout; see the [release checklist](../../architecture/host-agent-fs-exec-release.md)
for verified scope and outstanding platform qualification.

```lua
local connecting = hollow.host.connect({
  id = "build-host",                 -- stable caller-selected identifier
  argv = { "my-connector", "--stdio" }, -- exact connector argv
})

connecting:next(function(host)
  host:info():next(function(info) print(info.os, info.arch) end)
  host:exec({ argv = { "git", "status", "--short" }, cwd = "/work" })
    :next(function(result) print(result.exit_code, result.stdout) end)
  host.fs.stat("/work")
  host.fs.list("/work", { offset = 0, limit = 100 })
  host.fs.read("/work/file", { offset = 0, limit = 4096 })
end)

-- Native filesystem/process APIs on the GUI's own OS. No agent subprocess.
hollow.host.local_host():next(function(host)
  host.fs.list("."):next(function(page) print(#page.entries) end)
end)
```

`connect(opts)` returns immediately with a promise. It resolves to a host only
after native status becomes `ready`; a connection failure rejects with a
structured `{ code, message }` error. `host.id` is the stable supplied ID.
Native handles are private. `host:status()` reports `connecting`, `ready`, or
`disconnected`; `host:close()` closes the host. Closing is idempotent.
`host.generation` is an opaque string for cache identity, not a request number.
`local_host()` caches its pending/ready native-local connection under ID `local`;
after close it creates a new generation. For another native host ID, use
`connect({id = "my-local", backend = "local"})` without `argv`.

## Podman configuration

`podman(opts)` bootstraps into an **existing running container**, then returns
the same host API. It does not create/start/remove containers, allocate a TTY,
override the container user, or replay commands after a disconnect.

```lua
hollow.host.podman({
  id = "build",
  container = "my-build-container",
}):next(function(host)
  host:exec({ argv = { "git", "status", "--short" }, cwd = "/work" })
    :next(function(result) print(result.stdout) end)
  hollow.ui.workspace.configure({ sources = { { host = host, roots = { "/work" } } } })
end, function(err) print(err.code, err.message) end)
```

By default, artifacts come from the installed release's `agents/` beside the
executable. For a `prefix/bin/` executable, a missing adjacent manifest also permits
`prefix/agents/`. Flat releases never search outside their executable directory.
There is no CWD, PATH, home-directory or network artifact search. Discovery uses
asynchronous native-local info/read/stat operations within the bootstrap deadline.

The bundle must contain `SHA256SUMS`, `linux-x86_64/hollow-agent`, and
`linux-aarch64/hollow-agent`. The manifest is bounded to 4 KiB and must contain
exactly those two paths, once each, with 64-hex SHA-256 values; traversal, unknown
paths, duplicates and truncated reads fail closed. A corrupt/unreadable adjacent
manifest never triggers fallback to another location. Both binaries must be
nonempty regular files, not symlinks. Transfer verification still checks the
selected binary's bytes before execution.

Overrides, highest priority first:

* `agent_path = "/opt/bin/hollow-agent"`: caller-trusted preinstalled executable.
* `artifacts = { x86_64 = { path = "/absolute/hollow-agent", sha256 = "<64 hex digits>" } }`:
  explicit trusted artifacts; no bundle discovery.
* `agent_dir = "/absolute/agents"`: exactly one trusted bundle directory;
  no executable-relative fallback.

Paths on the client are absolute **client-native** paths (including Windows
paths), but artifacts must be Linux agents. The connector selects
`x86_64`/`aarch64` using the container's architecture, not the GUI's. SHA-256
protects transferred bytes; it does not authenticate an untrusted release,
manifest, container, or Podman executable. Keep the installation/bundle directory
trusted. Missing assets return `agent_install_unavailable` with override guidance.

The connector resolves the selected name to an immutable container ID, preserves
its configured user, and verifies cached/uploaded bytes before installing into
`$HOME/.cache/hollow/agents/linux-<arch>/<sha256>/hollow-agent`. Uploads use unique
temporary paths and same-directory atomic rename. Bootstrap shell scripts use
positional arguments for paths, not shell interpolation. Container tooling needed:
`/bin/sh`, `uname`, `sha256sum`, `mktemp`, `mkdir`, `chmod`, `mv`, `rm`, and a writable,
executable HOME cache. No dependencies are installed automatically.
`mv` must support `-T` (GNU/BusyBox) so a destination directory/symlink is not
silently followed during installation. Bootstrap is not a sandbox against a
malicious process running as the same container user and changing cache paths.

Restricted containers can instead supply `agent_path = "/opt/bin/hollow-agent"`
without `artifacts`. This preinstalled executable is caller-trusted; deployment
and SHA verification are skipped. The ordinary protocol handshake still applies.

Optional `podman` selects the native executable (default `"podman"`).
`timeout_ms` bounds the complete bootstrap (default 60000, maximum 300000).
At most four bootstrap promises are active across connectors. `:cancel()` rejects pending bootstrap
and cancels its current operation; temporary-upload cleanup is best effort after
that operation finishes. Cancellation does not remove installed agents or stop
containers. A later connection always inspects and verifies again.

Container restart/recreation requires explicit reconnect. An in-progress bootstrap
pinned to an old container ID fails instead of silently following a reused name.
After connection, operations use the persistent agent protocol, not per-operation
`podman exec`. Windows Podman runtime behavior remains unqualified.

## WSL configuration

`wsl(opts)` is an experimental **fs/exec-only** host. Existing terminal panes
continue using the existing PTY backends, including WSL bypass. This API neither
implements agent PTYs nor changes a pane's backend.

```lua
hollow.host.wsl({
  id = "ubuntu-work",
  distro = "Ubuntu-26.04", -- explicit existing registered distribution
  -- user = "alice",      -- optional; omitted preserves distro's default user
}):next(function(host)
  host.fs.list("/home/alice/projects")
  host:exec({ argv = { "git", "status", "--short" }, cwd = "/home/alice/projects/demo" })
end, function(err) print(err.code, err.message) end)
```

The connector selects the distro/user through exact `wsl.exe` arguments and
starts Linux commands with `--cd / --exec`, without a login shell or PTY. Normal
WSL launch may start the selected distro; the connector does not install, import,
unregister, terminate or shut down distributions, or silently select root.
It does not change the configured default distro/user.

Artifact selection, executable-relative bundle discovery, SHA verification,
versioned atomic installation, cancellation, deadlines and cleanup use the same
bootstrap engine as Podman. The `artifacts`, `agent_dir`, `agent_path`, and
`timeout_ms` overrides have the same precedence. Optional `wsl` overrides the
native launcher executable (default `"wsl.exe"`). WSL additionally needs `wslpath`
and `cp` inside the selected distro for automatic deployment. Artifact paths must
be Windows-accessible: `wslpath -a -u` converts the client path inside the selected
distro, then `cp --` copies it without guessing drive mounts or shell quoting.
Restricted or inaccessible artifact mounts can use a preinstalled `agent_path`.

After bootstrap, one long-lived `wsl.exe --exec <agent> stdio` connection carries
all common fs/exec RPCs. Linux paths/argv/results remain raw bytes inside the
protocol; launcher distro/user/client paths use native Windows string semantics.
RPCs are never replayed after disconnection. Reconnect is explicit and gets a new
generation. Unlike Podman's immutable container ID, the CLI selects a distro by
registration name; replacing a registration during bootstrap is not pinned or
qualified by this slice. Do not replace registrations during active use.

Real launcher tests currently run **Linux → Windows interop → WSL**. They supply
a Windows UNC artifact override because native Linux bundle paths are not Windows
paths. This does not qualify automatic discovery in a native Windows client,
Windows GUI teardown, WSL PTY latency, or the complete fault/security matrix.
Separate [native Windows dispatcher smoke](../../validation/2026-10-19-windows-fs-exec-smoke.md)
now executes native-local and preinstalled WSL fs/exec through production native
HostManager. Public Lua bootstrap and automatic Windows bundle discovery remain
unverified; that smoke does not qualify them or change the pane backend.

## SSH configuration

`ssh(opts)` is an experimental Linux fs/exec connector, not a terminal/session
backend. It uses the same agent, bootstrap engine, limits and asynchronous API:

```lua
hollow.host.ssh({
  id = "build-server",
  destination = "build", -- trusted SSH config alias, hostname or IP
  -- user = "alice", port = 2222,
  -- identity_file = "/home/alice/.ssh/id_ed25519",
  -- known_hosts = "/home/alice/.ssh/known_hosts",
  -- config_file = "/home/alice/.ssh/config",
}):next(function(host)
  host:exec({ argv = { "git", "status", "--short" }, cwd = "/srv/project" })
end, function(err) print(err.code, err.message) end)
```

Authenticate and trust the server before connecting. Bootstrap forces
`BatchMode=yes` and `StrictHostKeyChecking=yes`: unknown/changed host keys and
unavailable noninteractive credentials reject; no password, passphrase or trust
prompt is shown. Unlocked SSH-agent credentials may authenticate. An explicit
`identity_file` additionally selects `IdentitiesOnly=yes`. Client file overrides
must be absolute native paths without control characters. `known_hosts` selects
the user host-key database; normal system host-key policy still applies.

Normal trusted SSH configuration may supply aliases, users, ports and ProxyJump
or ProxyCommand routes. Configuration is trusted executable policy, not a sandbox.
The connector overrides RemoteCommand, TTY allocation, local commands, forwarding
(including agent/X11), and interactive escape handling. ControlMaster,
ControlPath and ControlPersist are disabled: neither deployment nor the live
transport depends on shared OpenSSH connections. Each bootstrap step can open a
new authenticated connection; established-agent RPCs share one persistent
`ssh -T ... 'exec <quoted-agent> stdio'` process. No RPC replay occurs on loss.

Artifact overrides/discovery, SHA-256 verification, versioned atomic installation,
cancellation, deadlines and best-effort cleanup are shared with Podman/WSL.
Optional `ssh`/`scp` select native executables. Deployment forces `scp -s -B`
(SFTP), preserving the same SSH configuration, identity, host-key and port policy.
It never falls back to legacy remote-shell SCP; an unavailable SFTP subsystem or
old client requires a preinstalled `agent_path`. The remote also needs the common
Linux bootstrap utilities and a POSIX-compatible login shell. Shell command
arguments are explicitly POSIX-quoted; SFTP target paths are literal, not shell
quoted. Connected paths/argv/results travel as bytes inside the common protocol.

Linux OpenSSH client/server tests cover deployment and common conformance using
an owned non-root fixture, including quoted/space-containing HOME and client
paths, unknown/changed host keys and unauthorized credentials. Native Windows
OpenSSH, jump hosts, network fault injection, and the full security matrix remain
unqualified. This API does not change existing SSH/WSL PTYs or session ownership.

## Docker configuration

`docker(opts)` selects an **existing running Linux container**, just like Podman:

```lua
hollow.host.docker({
  id = "api-dev",
  container = "api-dev",
  -- context = "desktop-linux", -- optional explicit Docker context
}):next(function(host)
  host.fs.list("/work")
end, function(err) print(err.code, err.message) end)
```

Docker and Podman share container selection and bootstrap policy, not only the
agent handlers. Inspect resolves a full immutable container ID; every subsequent
probe, upload and persistent `exec -i` transport uses that ID. Neither connector
creates, starts, stops, removes or restarts containers or overrides the configured
user. Container replacement/disconnection does not replay EXEC requests.

Optional `docker` selects the native executable (default `"docker"`). Optional
`context` is copied before asynchronous work and supplied as `--context` on every
Docker command, including cleanup. Omission preserves Docker's configured
context/environment selection; users must not change that selection during
bootstrap. Explicit contexts still rely on trusted Docker client configuration;
the connector does not pin mutable context definitions or daemon identity.

`artifacts`, `agent_dir`, `agent_path` and `timeout_ms` have the same precedence
and bounds as Podman. Deployment uses `cp`, then reopens the copied inode and
recreates the reserved temporary under the configured user (Docker's archive
copy can assign root ownership). No privileged exec or chown is used. Shared
SHA-256 verification, mode 0700 and atomic installation follow restaging.
The copied artifact must be readable by that user; bundled mode-0755 binaries
meet this requirement. A writable executable cache is required; restricted targets can
use a preinstalled `agent_path`. Windows containers are unsupported.

Local validation covers Docker-shaped mocks and actual native integration using
Podman's compatible CLI via an explicit executable override. **No real Docker
client/daemon was available locally.** This evidence does not qualify Docker
ownership semantics, Docker Desktop, remote Docker contexts or Windows clients.
A dedicated CI job is configured for a real Docker/non-root fixture; its result
has not been observed locally. Docker remains experimental until those gates pass.

## Operations

### Read-only workspace loading

```lua
hollow.workspace.load_host(host, "/work/demo/.hollow/workspace.json")
  :next(function(spec)
    -- Inspect the document. Choose pane/domain/bootstrap policy separately.
    print(spec._path)
  end, function(err) print(err.code, err.message) end)
```

`workspace.load_host(host, path, {max_bytes = 1048576})` returns a cancellable
promise, reads bounded pages through the same host filesystem API, and validates
the JSON workspace document. No local path probing, shell command, remote script
execution or pane creation occurs. It preserves path bytes and rejects oversized
files rather than accepting truncated JSON. `max_bytes` must be 1–1,048,576;
default 1 MiB. Cancellation rejects immediately and forwards cancellation to the
active read, whose native completion is still drained. Pages use ordinary host
operation deadlines; the sequence is not an atomic file snapshot. Existing
synchronous local `workspace.load(path)` and resolver aliases remain unchanged.

### Primitive host operations

`info`, `exec`, and `fs.stat/list/read` return Hollow promises. Each operation
promise supports `:cancel()`, which requests cancellation once; its promise
settles only when native completion is reported. Operation failures reject with
structured errors. An `exec` command's nonzero exit code is a successful result,
not an infrastructure rejection. Read results are binary Lua strings and may
contain NUL bytes or invalid UTF-8. Paths, argv entries, environment keys, and
environment values reject NUL bytes; environment keys also reject `=`. `argv`
must be a dense array of strings.

Results:

| Operation | Fields |
|---|---|
| `info()` | `os`, `arch`, `build`, `protocol_major`, `protocol_minor`, byte-valued `cwd` and `home`; native-local only: optional `executable_dir` |
| `exec(opts)` | `exit_code`, binary `stdout`, binary `stderr` |
| `fs.stat(path)` | `kind`, `mode`, `size`, `mtime` (lstat semantics) |
| `fs.list(path, opts)` | `entries = {{name, kind}, ...}`, `next_offset`, `eof` |
| `fs.read(path, opts)` | binary `bytes`, `eof` |

Agent directory entry kinds are currently `"unknown"`; native-local listings
return available native kinds. Query `stat` explicitly when needed. Native-local
`stat.mode` contains native POSIX bits where available, otherwise `0` on Windows;
Windows attributes are not fabricated as POSIX permissions. Pagination is not a
directory snapshot. Integers larger than Lua's exact
53-bit range are decimal strings, not rounded numbers. Request ids and connection
generations stay opaque and use strings in the native bridge.

Limits: eight registered hosts, 64 retained requests across hosts, 256 directory
entries per page, 16 KiB per file read and 1 MiB combined exec output. Exec defaults
to a 30-second deadline; `timeout_ms` accepts 1–86,400,000. Empty argv arguments
are preserved; only argv[1] must be nonempty. `env` overrides inherited values.
Native-local `hollow.process.*` behavior is unchanged.
Directory page limits are 1–256; zero is rejected rather than yielding a
non-advancing pagination cursor.

Native-local operations run on bounded cancellable workers (16 retained requests
per local host). Owner-thread cancel only sets a flag; worker watchdogs interrupt
I/O and join before publishing completion. Native exec uses the existing native
process API's direct-child cleanup semantics, **not** Linux agent guardians or a
process-tree sandbox. Descendant cleanup and Windows runtime qualification remain
release gates. Its stdout/stderr collection uses individually bounded buffers
(up to 2 MiB combined transient capture); accepted results obey the 1 MiB combined
output limit. Windows native paths/argv use WTF-8 per Zig's native API; Linux
agent paths/argv remain opaque bytes.

Polling runs through deferred callbacks, so completion depends on the
application tick. This API does not automatically replay requests or reconnect
after disconnection.

This connector slice is experimental and does not migrate session/PTY ownership.
Workspace discovery may opt into a
ready host via `source.host`; legacy resolvers remain unchanged without it.
Availability depends on the native host bridge in the running build;
Lua stub tests do not establish that native connector functionality is present.
