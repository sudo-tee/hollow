# FAQ

Short, opinionated answers to recurring questions.

## Hollow vs. other terminals

### How is Hollow different from WezTerm?

WezTerm is the closest analogue. Hollow's design goals are the same:
treat configuration as code, lean on Lua, ship a real terminal
emulator.
The differences are mostly structural:

- Hollow is built on Zig (vs. Rust) and uses libghostty-vt (vs.
  WezTerm's own VTE-derived parser).
- Hollow is Windows-first; WezTerm is cross-platform from day one.
- Hollow ships an HTP-style protocol for shell-to-host integration;
  WezTerm uses a similar model.
- Hollow's plugin system is git-clone based, similar to lazy.nvim-style
  plugin managers.

### Why not just use Ghostty?

You can. Ghostty is excellent.
Hollow adds a Lua scripting layer and a richer pane/workspace model on
top of a Ghostty-derived VT core.
If you do not need Lua and want the polished, well-supported experience,
use Ghostty. If you want to script the terminal itself, Hollow is the
option.

### Why not Alacritty?

Alacritty is fast and minimal. It is intentionally not programmable
beyond its TOML config.
Hollow treats the Lua runtime as a first-class extension surface and
ships a widget model on top of it.

## Configuration

### Should I copy `conf/init.lua` into my override?

No.
The override is merged on top of the base, so a small personal
`init.lua` with just the keys you want to change is enough. Copying
the whole base file forks it and makes upgrades harder.

### How do I know which keys the runtime actually read?

`hollow.config.snapshot()` returns the merged config.
Print it from a one-shot script:

```lua
print(require("hollow").json.encode(hollow.config.snapshot()))
```

### Where does Hollow look for fonts?

`./hollow.exe --list-fonts` lists everything Hollow sees on the
current host. The same inventory is available in Lua via
`hollow.fonts.list()`, `hollow.fonts.find(query)`, `hollow.fonts.has(...)`,
and `hollow.fonts.pick(candidates)`.

## Shell integration

### Do I have to use HTP?

No. HTP is opt-in.
Without it, panes still work, but `pane.cwd` and `foreground_process`
fall back to whatever the host can infer.

For ambient metadata, the shell-side helpers in
[`shell-integration/`](../shell-integration) are the lightest path.
For one-shot automation, the
[native `hollow cli …`](reference/cli/native.md) is faster and does
not need a tty.

### `hollow cli` or `hollow-cli`?

| | `hollow cli …` | `hollow-cli` |
| --- | --- | --- |
| Talks to | Host command socket | OSC over tty |
| Needs a tty | no | yes |
| Needs shell integration | no | yes |
| Best for | scripts, CI, automation | prompt hooks |

Both ship. The native subcommand is the recommended path for
host-side automation. See
[CLI index](reference/cli/README.md).

## Plugins

### Where are my plugins stored?

`hollow.fs.data_dir() .. "/plugins"`. On Windows that is
`%APPDATA%\hollow\plugins`. The directory is created on first use.

### How do I update a plugin?

```lua
hollow.plugins.sync()
```

It walks every declared plugin and runs
`git pull --ff-only --recurse-submodules`. Restart Hollow to pick up
new code.

### Can plugins depend on each other?

Not in v1. Plugins load in declaration order and cannot declare
dependencies. See [`hollow.plugins`](reference/lua/plugins.md) for
out-of-scope notes.

## WSL

### Is Hollow a Linux terminal?

No. Hollow is a Windows app.
WSL is one of the shells Hollow can launch; the bypass helper is a
small Linux-side binary that skips ConPTY.

### What if I want the WSL helper to do more?

The bypass helper is a small Linux-side binary in
[`src/wsl_bypass.zig`](../src/wsl_bypass.zig). It speaks a tiny
APC-based protocol defined in
[`src/pty/wsl_bypass_protocol.zig`](../src/pty/wsl_bypass_protocol.zig).
Extending it is feasible but is a separate project from the terminal
itself.

## See also

- [Getting started](getting-started.md)
- [Configuration](configuration.md)
- [Troubleshooting](troubleshooting.md)
