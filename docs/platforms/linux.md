# Linux

> **Status:** The Linux build is currently broken and Linux is not a
> validated runtime target.
> The notes below describe what would be needed to make it work and
> what to expect from `zig build run` today.

## What works

- The Lua API surface — every namespace documented in
  [Reference](../reference/lua/README.md) is platform-neutral.
- Config files using the same syntax as Windows; the personal config
  location is `$XDG_CONFIG_HOME/hollow/init.lua` or
  `$HOME/.config/hollow/init.lua`.
- The shipped base config falls back to a `unix` domain that uses
  `hollow.platform.default_shell`.

## What does not work

- The renderer. The Linux build is currently broken and `zig build run`
  is not expected to succeed. The README's "Linux build prerequisites"
  call this out explicitly.
- There is no packaged Linux release.
- The WSL bypass helper runs on Linux, but the helper alone is not a
  terminal — you need the Windows host to drive it.

## If you want to fix the Linux build

The dependency list in the project README is the starting point:

```bash
sudo apt install -y libx11-dev libxi-dev libxcursor-dev \
  libgl1-mesa-dev libasound2-dev pkg-config
```

These provide the `-lX11 -lXi -lXcursor -lGL -lasound` libraries
required by the linker.

After the build is restored, the runtime surface should mostly mirror
the macOS plan in the next file:
[macOS](macos.md).

## See also

- [Platforms matrix](README.md)
- [macOS](macos.md) — closest analogue once the build is restored
- [Troubleshooting](../troubleshooting.md)
