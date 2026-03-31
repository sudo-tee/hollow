# Hollow

This branch is the start of the native rewrite.

The old Love2D/Lua code is still in the repo as reference material, but the new work now starts in `native/` with a Zig-first core that still keeps `libghostty-vt` and LuaJIT in the loop.

## Direction

- `Zig` for the core runtime, platform layer, PTY layer, and terminal orchestration
- `LuaJIT` as the hackable host scripting layer
- `libghostty-vt` as the VT/parser/render-state engine
- renderer seam shaped for `sokol` now and a future `webgpu` backend later
- Windows treated as a first-class target instead of a fallback port

## Current layout

```text
build.zig
conf/init.lua
native/
  src/
    app.zig
    config.zig
    main.zig
    platform.zig
    lua/luajit.zig
    term/ghostty.zig
    render/
      backend.zig
      null_backend.zig
docs/rewrite-architecture.md
```

## What works today

- native Zig build entry point via `./launch.sh`
- dynamic LuaJIT loading and a tiny `hollow` Lua API
- config bootstrap from `conf/init.lua` or `~/.config/hollow/init.lua`
- dynamic `libghostty-vt` loading and terminal/render-state bootstrap
- Windows-first `sokol_app` frontend path with a native event loop
- ConPTY backend for Windows and `forkpty` backend for Unix
- full-grid terminal rendering from Ghostty row/cell state into a native window
- split panes, tabs, tab bar, and status bar rendering
- configurable native font rendering with custom faces, fallback fonts, smoothing, and ligatures

## Build

```bash
./launch.sh
./launch.sh --build-only
```

The Windows executable is emitted at `zig-out/bin/hollow-native.exe`.

For Windows, place a LuaJIT runtime DLL next to the exe as one of:

- `zig-out/bin/luajit-5.1.dll`
- `zig-out/bin/luajit.dll`
- `zig-out/bin/lua51.dll`

The app already installs `zig-out/bin/ghostty-vt.dll` during a Windows build.

The runtime now also searches relative to the executable directory, not just the current working directory.

## Windows-first runtime

- `native/src/render/sokol_runtime.zig` runs the app through `sokol_app`
- Windows uses `D3D11` via Sokol; Linux keeps a fallback GL path for now
- `native/src/pty/pty_windows.zig` uses ConPTY for the shell bridge
- terminal content comes from `libghostty-vt` row/cell iteration, then gets painted into the Sokol window

Current renderer status:

- full terminal grid is rendered through the native FreeType/HarfBuzz atlas path
- keyboard, mouse, focus, resize, and scroll events are wired into Ghostty + PTY
- split borders, panes, tabs, and top-bar/status content are rendered natively
- font config supports custom regular/bold/italic faces, fallback stacks, smoothing, and ligatures

## Config model

The new Lua host API is intentionally tiny right now:

```lua
hollow.set_config({
    backend = "sokol",
    shell = "pwsh.exe",
    ghostty_library = "ghostty-vt.dll",
    fonts = {
        size = 14.5,
        smoothing = "grayscale",
        hinting = "light",
        ligatures = true,
        regular = "fonts/YourMono-Regular.ttf",
        bold = "fonts/YourMono-Bold.ttf",
        italic = "fonts/YourMono-Italic.ttf",
        bold_italic = "fonts/YourMono-BoldItalic.ttf",
        fallbacks = {
            "fonts/YourSymbols.ttf",
        },
    },
    cols = 120,
    rows = 34,
    scrollback = 20000,
    window_title = "hollow",
})
```

Available helpers:

- `hollow.log(...)`
- `hollow.platform.os`
- `hollow.platform.is_windows`
- `hollow.platform.is_linux`
- `hollow.platform.is_macos`
- `hollow.platform.default_shell`

## Next steps

- harden ConPTY process lifecycle and Windows packaging of LuaJIT + `libghostty-vt`
- add text selection and copy/paste
- add workspaces on top of the existing tabs + splits model
- expand Lua from config-only into events, actions, and layout control
