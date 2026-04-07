# Hollow

<div align="center">
    <img src="assets/banner.png" alt="Hollow demo" width="600"/>
</div>

Hollow is a terminal emulator built in Zig with a LuaJIT scripting layer and `libghostty-vt` for VT parsing and rendering. The project is currently in early development, but the goal is to create a fast, hackable, and cross-platform terminal with a Windows-first approach.

This project is built out of self interest and a desire to create a wezterm-like terminal emulator that is hackable and extensible through Lua scripting.

## Disclaimer

This project was heavily prototyped with the help of AI. The current state of the codebase is a mix of human-written and AI-generated code, and there may be some rough edges and inconsistencies as a result. However, the core architecture and design decisions were made by me.

## Direction

- `Zig` for the core runtime, platform layer, PTY layer, and terminal orchestration
- `LuaJIT` as the hackable host scripting layer
- `libghostty-vt` as the VT/parser/render-state engine
- renderer seam shaped for `sokol` now and a future `webgpu` backend later
- Windows treated as a first-class target instead of a fallback port

## Why the name Hollow?

- The terminal is like a hollow shell that you can fill with whatever you want. It's a place where you can run your commands, scripts, and applications. It's also a nod to the idea of a "hollow" project that is meant to be filled in and built upon by the community.
- The the concept of "hollowness" is deeply connected to spirits, ghosts, and the supernatural, often appearing as a physical or spiritual trait of restless entities. This ties into the use of `libghostty-vt` as the VT parsing and rendering engine, which is a key component of the terminal's architecture.
- In the theme of spirits, you can also see Hollow as a spiritual successor to popular "WezTerm".

## Current layout

```text
build.zig
conf/init.lua
src/
  app.zig
  config.zig
  main.zig
  platform.zig
  lua/luajit.zig
  term/ghostty.zig
  render/
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

- `src/render/sokol_runtime.zig` runs the app through `sokol_app`
- Windows uses `D3D11` via Sokol; Linux keeps a fallback GL path for now
- `src/pty/pty_windows.zig` uses ConPTY for the shell bridge
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
    padding = 12,
    fonts = {
        size = 14.5,
        line_height = 1.0,
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
    -- Scrollback is a byte budget, not a line count.
    -- 64_000_000 ~= 64 MB of history per terminal.
    scrollback = 64_000_000,
    scrollbar = {
        enabled = true,
        width = 10,
        min_thumb_size = 24,
        margin = 2,
        jump_to_click = true,
        track = "#1b1d25",
        thumb = "#5f667a",
        thumb_hover = "#7a839b",
        thumb_active = "#9fb8e8",
        border = "#2d3140",
    },
    hyperlinks = {
        enabled = true,
        shift_click_only = true,
        prefixes = "https:// http:// file:// ftp:// mailto:",
        delimiters = " \t\r\n\"'<>[]{}|\\^`",
        trim_trailing = ".,;:!?)]}",
    },
    window_title = "hollow",
})
```

Shift-click hyperlink opening:

- Hollow detects URLs in visible terminal rows using the configurable `hyperlinks.prefixes`, `hyperlinks.delimiters`, and `hyperlinks.trim_trailing` rules.
- With `hyperlinks.shift_click_only = true`, hold `Shift` and left-click a URL to open it in the system browser.

Available helpers:

- `hollow.log(...)`
- `hollow.copy_selection()`
- `hollow.paste_clipboard()`
- `hollow.platform.os`
- `hollow.platform.is_windows`
- `hollow.platform.is_linux`
- `hollow.platform.is_macos`
- `hollow.platform.default_shell`

Default clipboard bindings now live in Lua, so you can override them from config:

```lua
hollow.keymap.del("ctrl+shift+v")
hollow.keymap.del("shift+insert")
hollow.keymap.set("alt+v", "paste_clipboard")
hollow.keymap.set("ctrl+shift+c", "copy_selection")
```

Default scrollback bindings:

```lua
hollow.keymap.set("alt+shift+page_up", "scrollback_page_up")
hollow.keymap.set("alt+shift+page_down", "scrollback_page_down")
hollow.keymap.set("ctrl+shift+home", "scrollback_top")
hollow.keymap.set("ctrl+shift+end", "scrollback_bottom")
```

## Next steps

- harden ConPTY process lifecycle and Windows packaging of LuaJIT + `libghostty-vt`
- add text selection and copy/paste
- add workspaces on top of the existing tabs + splits model
- expand Lua from config-only into events, actions, and layout control
