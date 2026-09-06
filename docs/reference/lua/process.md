# `hollow.process`

Run host processes from Lua. Prefer `spawn` or `exec` in interactive callbacks;
the older `run` and `run_child_process` helpers wait synchronously.

## Asynchronous processes

```lua
local job = hollow.process.spawn({
  cmd = { "git", "status", "--short" },
  cwd = "/path/to/project",
  env = { GIT_OPTIONAL_LOCKS = "0" },
  timeout_ms = 30000,
  output_limit = 1024 * 1024,
  on_complete = function(result)
    print(result.code, result.stdout, result.stderr, result.error)
  end,
})

job:status()  -- "running" or "finished" (completion delivered)
job:result()  -- nil until completion, then the result table
job:cancel()  -- request cancellation; job:kill() is an alias
job:next(function(result) print(result.code) end)
```

`cmd` is an argv array, or a single executable name. Strings are not parsed as
shell commands; pass a shell explicitly when required. `env` overrides inherited
variables. `cwd` defaults to the application's working directory.

Up to 16 jobs may be outstanding per Lua runtime. Output is collected separately
for stdout and stderr, with a default limit of 1 MiB each and maximum of 16 MiB.
Exceeding a limit terminates the job with an error. The default timeout is 30 seconds,
with a maximum of 24 hours. Both limits must be positive integers.

Completion is polled by a deferred callback every 10 ms; delivery depends on the
application tick. `on_complete` runs on the Lua callback thread, never in a worker.
Config reload and runtime shutdown cancel outstanding jobs and release their resources.
Cancellation applies to the direct child; it does not promise process-tree termination.

Results contain `code`, `stdout`, `stderr`, optional `error`, and `canceled`.
A nonzero process exit is a normal result. Spawn failures, timeouts, output-limit
errors, and cancellation use `code = -1` and an `error` string. Output may be absent
on these failures. This API collects output at completion; it does not expose
streaming readers, stdin writers, or a process PID.

## Promises and coroutines

`exec(opts)` returns a promise. It resolves with the result even for a nonzero
exit code; infrastructure failures reject with a result table (or a validation
error string). `spawn` supports cancellation through its returned handle.

```lua
hollow.process.exec({ cmd = { "git", "branch", "--show-current" } })
  :next(function(result) print(result.stdout) end)
  :catch(function(err) print("process failed", err) end)

hollow.async.run(function()
  local job = hollow.process.spawn({ cmd = { "git", "status", "--short" } })
  local result = job:wait() -- yields the coroutine
  print(result.stdout)
end)
```

## Synchronous compatibility helpers

```lua
hollow.process.run_child_process(args, opts?)        -- (ok, stdout, stderr)
hollow.process.run(cmd, args?)                       -- { code, stdout, stderr }
hollow.term.run_domain_process(args, domain?, opts?) -- through a domain shell
```

`opts.hide_window` defaults to true on Windows. These helpers retain their existing
50 KiB per-stream output limits. `run_domain_process` uses the active pane's domain
when none is supplied. Asynchronous jobs currently run on the host; pass an explicit
WSL or SSH executable when required.
