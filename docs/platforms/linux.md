# Linux

> **Status:** Basic Linux/X11 support. The app builds, runs a native shell,
> renders terminals, and supports tabs, keyboard input, and borderless window
> move/resize. Windows and WSL remain primary validated targets.

## What works

- Native X11/GLX rendering, terminal input, tabs, panes, Lua configuration,
  and the default keymaps.
- The default `unix` domain uses `$SHELL`, with `/bin/sh` as fallback.
- Config files use the same syntax as Windows; user config lives at
  `$XDG_CONFIG_HOME/hollow/init.lua` or `$HOME/.config/hollow/init.lua`.
- `window_titlebar_show = false` uses X11 window-manager hints. Top-bar drag
  and edge/corner resize work on window managers and XWayland compositors that
  allow client-managed windows.

## What does not work

- Native Wayland is not supported; Hollow currently uses Sokol's X11 backend.
  It may run through XWayland, subject to compositor policy.
- Linux support has not received the same breadth of runtime validation as
  Windows/WSL. Report reproducible gaps with compositor, desktop environment,
  GPU driver, and session type.
- The WSL bypass helper is for Windows-host WSL domains and is not required by
  native Linux Hollow.

## Build dependencies

The dependency list in the project README is the starting point:

```bash
sudo apt install -y libx11-dev libxi-dev libxcursor-dev \
  libgl1-mesa-dev libasound2-dev pkg-config
```

These provide the `-lX11 -lXi -lXcursor -lGL -lasound` libraries
required by the linker.

Then build and run:

```bash
./scripts/setup.sh
zig build run
```

## See also

- [Platforms matrix](README.md)
- [macOS](macos.md)
- [Troubleshooting](../troubleshooting.md)
