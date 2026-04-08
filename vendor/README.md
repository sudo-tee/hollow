# Vendored Dependencies

This directory contains only dependencies that still need local patches or local
wrapper logic.

Current contents:

- `ghostty-fontdeps/`
  - Small Zig wrapper package that builds `zlib`, `freetype`, and `harfbuzz`
    from pinned upstream source tarballs.
  - This follows the same URL/hash-fetch pattern Ghostty uses for its own font
    stack, without checking full upstream source trees into this repo.
- `zluajit/`
  - Local copy of `zluajit` with cross-build fixes for the WSL/Linux host to
    `x86_64-windows-gnu` release path used by Hollow.
- `luajit-upstream/`
  - LuaJIT upstream source tree consumed by the patched `zluajit` build.

Why these are vendored:

- `sokol` is patched separately under `third_party/sokol`.
- `ghostty` is fetched remotely via `build.zig.zon`.
- `zluajit` and the LuaJIT upstream build still need local fixes for the current
  Windows cross-build flow.
- The font stack uses a tiny local wrapper so Hollow can follow Ghostty's
  package style while keeping the exact build graph under this repo's control.
