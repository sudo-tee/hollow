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

## Connector hosts

`wsl`, `ssh`, `podman` and `docker` connect to a Linux host by running commands
through a **connector**: a native command prefix such as `wsl.exe`, `ssh` or
`podman exec -i`. Hollow installs the agent through it (see
[Agent deployment](#agent-deployment)), then keeps one long-lived
`<connector> <agent> stdio` process for all RPCs. They resolve to the same host
API as `connect`.

```lua
hollow.host.wsl({ id = "ubuntu", distro = "Ubuntu-26.04" })
hollow.host.ssh({ id = "build", destination = "build" })
hollow.host.podman({ id = "dev", container = "dev" })
hollow.host.docker({ id = "api", container = "api-dev", context = "desktop-linux" })
  :next(function(host)
    host:exec({ argv = { "git", "status", "--short" }, cwd = "/work" })
  end, function(err) print(err.code, err.message) end)
```

| Type | Options | Connector |
|---|---|---|
| `wsl` | `distro`, `user?`, `wsl?` (launcher, default `wsl.exe`) | `wsl.exe --distribution <distro> [--user <user>] --cd / --exec` |
| `ssh` | `destination`, `user?`, `port?`, `identity_file?`, `known_hosts?`, `config_file?`, `ssh?` | `ssh -T -o <policy>... <destination>` |
| `podman` | `container`, `podman?`, `via?` | `[wsl.exe ... --exec] podman exec -i <container>` |
| `docker` | `container`, `context?`, `docker?`, `via?` | `[wsl.exe ... --exec] docker [--context <c>] exec -i <container>` |

All types also accept the agent options `agent_path`, `agent_dir`, `artifacts`
and `timeout_ms`.

- **WSL** never installs, starts or stops distributions and never selects root;
  omitting `user` keeps the distro default.
- **SSH** is non-interactive: `BatchMode=yes` and `StrictHostKeyChecking=yes`, so
  unknown host keys or missing credentials reject instead of prompting. Remote
  commands, TTYs, forwarding, local commands, escape characters and connection
  sharing are disabled; `identity_file` adds `IdentitiesOnly=yes`. Trusted SSH
  config may still supply aliases, users, ports and jump hosts. File options are
  absolute native paths. SSH hands the command to the remote shell, so Hollow
  passes it as one POSIX-quoted `exec '...'` word.
- **Containers** must already be running; Hollow does not create, start, stop
  or restart them, and preserves the container's configured user. `via =
  { type = "wsl", distro, user? }` runs the container CLI inside WSL (then
  `podman`/`docker` name the Linux executable). A restarted container needs an
  explicit reconnect.

Connections never replay RPCs after a disconnect; reconnecting gets a new
`generation`. Deploy failures reject with `connector_unavailable` (connector
missing or host unreachable), `unsupported_arch`, `checksum_mismatch`, `timeout`
or `agent_install_unavailable`, with a readable `message`.

`connect` takes the same shape directly:
`connect({ id, connector = { argv, remote_shell? }, agent? = { path?, dir?, artifacts?, timeout_ms? } })`.

Workspace sources accept a descriptor without `id`:

```lua
hollow.ui.workspace.configure({ sources = { {
  name = "Container projects",
  host = { type = "podman", container = "dev", via = { type = "wsl", distro = "Ubuntu-26.04" } },
  roots = { "/work" }, -- host paths
} } })
```

A source's `host` does not route panes; give a terminal domain the same
descriptor for that (see [Pane PTYs](#pane-ptys)).

## Agent deployment

Connections and pane PTYs share one native installer (`src/host/deploy.zig`).
It runs off the UI thread, bounded by `timeout_ms` (default 60000, max 300000):

1. **Probe:** `<connector> /bin/sh -c ...` reports `uname -m` and whether
   `$HOME/.cache/hollow/agents/linux-<arch>/<sha256>/hollow-agent` exists with
   the expected digest.
2. **Upload** (when missing): the binary streams over the connector's stdin
   into a temporary file, is checked with `sha256sum`, and renamed into place.
3. **Run** `<connector> <agent> stdio` (or `pty` for panes).

The host needs `/bin/sh`, `uname`, `mkdir`, `mktemp`, `cat`, `sha256sum`,
`chmod` and `mv`, and a writable, executable `$HOME`. Nothing else is installed
or copied: no `scp`, `docker cp` or `wslpath`.

Where the agent comes from, highest priority first:

- `agent_path = "/opt/bin/hollow-agent"`: preinstalled on the host; skips the
  deploy. Use it for restricted hosts.
- `artifacts = { x86_64 = { path, sha256 }, aarch64 = { ... } }`: explicit
  client-native binaries.
- `agent_dir = "C:\\hollow\\agents"`: one bundle directory.
- Default: the release bundle in `agents/` beside the executable, or
  `../agents` when the executable is in `bin/`.

A bundle holds `SHA256SUMS` and `linux-<arch>/hollow-agent`. SHA-256 protects
the transferred bytes; it does not authenticate the bundle, so keep the
installation directory trusted. The installer is not a sandbox against other
processes running as the same host user.

Pane PTYs remember verified installs for the session and skip straight to step
3; connections always probe.

## Pane PTYs

The host descriptors above also drive terminal panes. Set `host` on a domain to
run each of its panes as `hollow-agent pty` on that host:

```lua
hollow.config.set({
  domains = {
    build = { host = { type = "ssh", destination = "build" } },
    dev   = { host = { type = "podman", container = "dev" } },
    Ubuntu = { host = { type = "wsl", distro = "Ubuntu", path_style = "wsl" } },
  },
})
```

`host` accepts `type = "wsl"|"ssh"|"podman"|"docker"` plus that connector's
options (no `id` needed), and optional `path_style = "posix"|"wsl"`. `"wsl"`
(default for `type = "wsl"`) converts Windows cwd and path-like environment
values to WSL paths; other types default to `"posix"`.

- Lua only describes the connector (`hollow._pty_host`). Hollow installs the
  agent natively (see [Agent deployment](#agent-deployment)), off the UI
  thread, while keystrokes are buffered, then runs `<connector> <agent> pty`.
  If a remembered agent fails to start (container recreated, cache wiped), the
  pane deploys again once.
- Each pane runs its own connector process. Multiplexing panes over one
  connection is future work.
- The agent spawns the host user's login shell (WSL launcher shells keep their
  inner command), with full escape-sequence passthrough, shell integration and
  resize.
- Explicit hosts are remote: no local PID or cwd tracking. Failures show a red
  `[hollow] <message>` banner in the pane, which then exits with status 125.
- On Windows, WSL domains with `wsl_distro`, or a shell like `wsl.exe -d X` /
  `--distribution X`, use `{ type = "wsl", distro = X }` implicitly. They keep
  local semantics and silently fall back to a native ConPTY `wsl.exe` launch on
  failure. `host = false` opts a domain out.
- [`term:spawn`](events.md) filters do not apply to agent panes.
- Failures are logged as `agent pty: ...` warnings in `hollow.log`.

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
