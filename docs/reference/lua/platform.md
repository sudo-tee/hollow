# `hollow.platform`

Read-only platform information.
Useful for branching config by OS.

## Shape

```lua
HollowPlatformInfo = {
  os            = "windows" | "linux" | "macos" | "freebsd" | "other",
  is_windows    = boolean,
  is_linux      = boolean,
  is_macos      = boolean,
  default_shell = string,
}
```

`default_shell` is the host's preferred shell, e.g.:

- Windows: `cmd.exe` (the runtime does not auto-pick PowerShell)
- Linux / macOS / WSL: `$SHELL` if set and executable, else `/bin/sh`

## Example

```lua
local hollow = require("hollow")

if hollow.platform.is_windows then
  hollow.config.set({ default_domain = "pwsh" })
else
  hollow.config.set({ default_domain = "unix" })
end
```

The shipped base config uses this branch to pick the default domain
and the set of bundled Windows domains.

## See also

- [Configuration](../../configuration.md#domains-and-shells)
