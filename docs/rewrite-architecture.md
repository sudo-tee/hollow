# Native Rewrite Architecture

This branch pivots `hollow` away from Love2D and toward a small Zig-native core.

## Goals

- Keep the core small and explicit.
- Preserve LuaJIT hackability for config, actions, and future plugins.
- Keep Ghostty's VT core as the terminal state engine.
- Treat Windows as a first-class target instead of a late compatibility layer.
- Leave room for a renderer swap between `sokol` now and a future `webgpu` path.

## New shape

```text
src/
  main.zig CLI/bootstrap entry point
  app.zig top-level composition and startup order
  config.zig owned runtime config state
  platform.zig host detection and path policy
  lua/luajit.zig embedded LuaJIT bridge + tiny host API
  term/ghostty.zig embedded Ghostty bootstrap ABI
  render/
    backend.zig renderer selection seam
    null_backend.zig current bootstrap backend
```

## Startup order

1. Resolve config file path.
2. Initialize embedded LuaJIT.
3. Expose a tiny `hollow` table into Lua.
4. Let Lua mutate the runtime config.
5. Initialize embedded Ghostty VT state.
6. Create a terminal and render-state handle.
7. Hand control to the renderer backend.

## Why embedding

- Keeps the release artifact self-contained.
- Avoids separate runtime DLL packaging for Ghostty and LuaJIT.
- Makes the Windows release path much closer to the Linux one.

## Planned next slices

- Add a real renderer implementation behind `render/backend.zig`.
- Add PTY backends in Zig: POSIX PTY on Unix and ConPTY on Windows.
- Stream VT bytes from the PTY into Ghostty's VT core.
- Replace the bootstrap renderer with a real glyph atlas and frame loop.
- Expand the Lua host API from config-only to actions, events, and pane/workspace control.
