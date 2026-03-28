# Native Rewrite Architecture

This branch pivots `hollow` away from Love2D and toward a small Zig-native core.

## Goals

- Keep the core small and explicit.
- Preserve LuaJIT hackability for config, actions, and future plugins.
- Keep `libghostty-vt` as the terminal state engine.
- Treat Windows as a first-class target instead of a late compatibility layer.
- Leave room for a renderer swap between `sokol` now and a future `webgpu` path.

## New shape

```text
native/
  src/
    main.zig              CLI/bootstrap entry point
    app.zig               top-level composition and startup order
    config.zig            owned runtime config state
    platform.zig          host detection and library path policy
    lua/luajit.zig        dynamic LuaJIT loader + tiny host API
    term/ghostty.zig      dynamic libghostty-vt loader + bootstrap ABI
    render/
      backend.zig         renderer selection seam
      null_backend.zig    current bootstrap backend
```

## Startup order

1. Resolve config file path.
2. Load LuaJIT dynamically.
3. Expose a tiny `hollow` table into Lua.
4. Let Lua mutate the runtime config.
5. Load `libghostty-vt` dynamically.
6. Create a terminal and render-state handle.
7. Hand control to the renderer backend.

## Why dynamic loading

- Keeps the Zig core buildable before the full dependency graph is pinned.
- Lets Windows consume `ghostty-vt.dll` without inventing a second bootstrap path.
- Makes the branch usable as a migration scaffold while the rendering layer changes.

## Planned next slices

- Add a real renderer implementation behind `render/backend.zig`.
- Add PTY backends in Zig: POSIX PTY on Unix and ConPTY on Windows.
- Stream VT bytes from the PTY into `libghostty-vt`.
- Replace the bootstrap renderer with a real glyph atlas and frame loop.
- Expand the Lua host API from config-only to actions, events, and pane/workspace control.
