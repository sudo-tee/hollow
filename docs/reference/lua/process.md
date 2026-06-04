# `hollow.process`

Run child processes from Lua.
The simple tuple helpers are the recommended path today;
`spawn` and `exec` are placeholders for a future richer API.

## Functions

```lua
hollow.process.run_child_process(args, opts?)       -- returns (ok, stdout, stderr)
hollow.process.run(cmd, args?)                      -- returns { code, stdout, stderr }
hollow.term.run_domain_process(args, domain?, opts?) -- runs through a domain shell
```

`run_child_process` is the WezTerm-style tuple helper.
`run` returns a structured table with `code`, `stdout`, `stderr`.
`run_domain_process` resolves the configured domain shell and runs
the argv through it; if `domain` is omitted it uses the current
pane's domain.

## `opts`

```lua
{
  hide_window = true,   -- default true; suppresses a console window on Windows
}
```

## Examples

```lua
local ok, out, err = hollow.process.run_child_process({
  "git", "rev-parse", "--show-toplevel",
})

if ok then
  print("top-level:", out)
else
  print("git failed:", err)
end
```

Run a process through the active pane's domain:

```lua
local ok, out, err = hollow.term.run_domain_process({
  "ls", "-la",
})
```

Run a process through a specific domain:

```lua
local ok, out, err = hollow.term.run_domain_process({
  "uname", "-a",
}, "UbuntuWSL")
```

## Placeholders

`hollow.process.spawn(opts)` and `hollow.process.exec(opts)` are
declared in the API surface but are not implemented yet.
Use the helpers above for now.

## See also

- [`hollow.term.run_domain_process`](term.md#run-a-process-in-a-domain)
- [`hollow.fs`](fs.md) — filesystem helpers
- [Plugins](../../plugins.md) — uses `hollow.process.run` to clone repos
