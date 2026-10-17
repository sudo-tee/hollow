# `hollow.host`

Experimental connector API for executing commands and accessing files on a host
managed by Hollow's native host bridge.

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
| `info()` | `os`, `arch`, `build`, `protocol_major`, `protocol_minor`, byte-valued `cwd` and `home` |
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

This connector slice is experimental. It does not bootstrap Podman, SSH, or WSL,
and does not migrate session/PTY ownership. Workspace discovery may opt into a
ready host via `source.host`; legacy resolvers remain unchanged without it.
Availability depends on the native host bridge in the running build;
Lua stub tests do not establish that native connector functionality is present.
