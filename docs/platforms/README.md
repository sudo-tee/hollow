# Platforms

Hollow's primary validated target is Windows, with WSL as a first-class
shell domain.
Other platforms are partially supported; the table below summarises the
state of the build and runtime on each one.

| Platform | App build | Runtime status | Notes |
| --- | --- | --- | --- |
| Windows (10/11, x86_64) | Yes | Primary | See [Windows](windows.md) |
| WSL (Ubuntu, others) | Helper only | First-class shell domain | See [WSL](wsl.md) |
| Linux (native, X11) | Yes | Basic | See [Linux](linux.md) |
| macOS | Broken | Not validated | See [macOS](macos.md) |

## What "primary validated" means

A primary validated target is one where:

- The build succeeds with the pinned toolchain
- A packaged `hollow.exe` runs and renders
- Tabs, panes, workspaces, copy mode, themes, hyperlinks, and the
  native CLI all work as documented
- The default keymap is exercised by the test suite

WSL is not a build target for the app; it is a shell domain. WSL
shells are launched from the Windows host, with an optional Linux-side
helper that skips ConPTY.

Linux currently uses Sokol's X11 backend. It can run through XWayland, but
native Wayland is not yet supported.

## Cross-platform config

Config files use the same Lua API on every host.
The shipped base config branches on `hollow.platform.is_windows` to pick
defaults:

```lua
local hollow = require("hollow")
local is_windows = hollow.platform.is_windows == true

local default_domain = is_windows and "pwsh" or "unix"
local domains = {}

if is_windows then
  domains.pwsh       = { shell = "pwsh.exe" }
  domains.powershell = { shell = "powershell.exe" }
  domains.cmd        = { shell = "cmd.exe" }
else
  domains.unix = { shell = hollow.platform.default_shell }
end
```

This is also why some guides in this site say "Windows only" or
"non-Windows hosts" — the behavior genuinely differs.

## Choosing a platform guide

- New to Hollow on Windows? Start with [Windows](windows.md).
- Want WSL as the default shell? Read [WSL](wsl.md).
- Trying to run on Linux or macOS? Read the caveats in
  [Linux](linux.md) or [macOS](macos.md) before opening an issue.
