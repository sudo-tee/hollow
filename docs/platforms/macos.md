# macOS

> **Status:** macOS is not a validated runtime target.
> The notes below describe what the Lua-side code path expects once a
> build is available.

## What works

- The Lua API surface — every namespace documented in
  [Reference](../reference/lua/README.md) is platform-neutral.
- Config files using the same syntax as Windows; the personal config
  location is `$XDG_CONFIG_HOME/hollow/init.lua` or
  `$HOME/.config/hollow/init.lua` (the XDG path is honoured on macOS).
- The shipped base config falls back to a `unix` domain that uses
  `hollow.platform.default_shell` (typically `/bin/zsh`).

## What does not work

- The renderer. There is no macOS build target.
- There is no packaged macOS release.

## If you want to add macOS support

The host bridge is Windows-shaped; making it build on macOS would
require:

- A Sokol backend that targets Metal
- A PTY path that does not depend on ConPTY (see
  [`src/pty/pty_posix.zig`](../../src/pty/pty_posix.zig) for the
  closest existing attempt)
- A clipboard and pasteboard bridge
- Hyperlink and font discovery paths adjusted for the macOS toolkits

These are large pieces of work; the project has chosen to focus on
Windows and WSL first.

## See also

- [Platforms matrix](README.md)
- [Linux](linux.md) — closest analogue
- [Troubleshooting](../troubleshooting.md)
