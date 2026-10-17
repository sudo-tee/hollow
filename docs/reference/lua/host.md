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
```

`connect(opts)` returns immediately with a promise. It resolves to a host only
after native status becomes `ready`; a connection failure rejects with a
structured `{ code, message }` error. `host.id` is the stable supplied ID.
Native handles are private. `host:status()` reports `connecting`, `ready`, or
`disconnected`; `host:close()` closes the host. Closing is idempotent.

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

Directory entry kinds are currently `"unknown"`; query `stat` explicitly when
needed. Pagination is not a directory snapshot. Integers larger than Lua's exact
53-bit range are decimal strings, not rounded numbers. Request ids and connection
generations stay opaque and use strings in the native bridge.

Limits: eight registered hosts, 64 retained requests across hosts, 256 directory
entries per page, 16 KiB per file read and 1 MiB combined exec output. Exec defaults
to a 30-second deadline; `timeout_ms` accepts 1–86,400,000. Empty argv arguments
are preserved; only argv[1] must be nonempty. `env` overrides inherited values.
Native-local `hollow.process.*` behavior is unchanged.

Polling runs through deferred callbacks, so completion depends on the
application tick. This API does not automatically replay requests or reconnect
after disconnection.

This connector slice is experimental. It does not bootstrap Podman, SSH, or WSL,
does not replace the default local host, and does not migrate workspace/session
ownership. Availability depends on the native host bridge in the running build;
Lua stub tests do not establish that native connector functionality is present.
