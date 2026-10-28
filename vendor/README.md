# Vendored Dependencies

This directory contains only dependencies that still need local patches or local
wrapper logic.

Current contents:

- `ghostty-fontdeps/`
  - Small Zig wrapper package that builds `zlib`, `freetype`, and `harfbuzz`
    from pinned upstream source tarballs.
  - This follows the same URL/hash-fetch pattern Ghostty uses for its own font
    stack, without checking full upstream source trees into this repo.

Why these are vendored:

- `sokol` is patched separately under `third_party/sokol`.
- `ghostty` is fetched remotely via `build.zig.zon`.
  The current pin is `ghostty-org/ghostty` `6ba144158577d033ccb6ed4b574e4013957c9161`
  (`1.4.1-dev`, requiring Zig 0.17.0).
- `third_party/lua-zluajit` and `third_party/luajit-upstream` are patch-oriented
  upstream trees and no longer live under `vendor/`.
- Intended upstream pins:
  `third_party/lua-zluajit` -> `negrel/zluajit` `v0.2.0` (`41bdb6c518edec5252ae4ea7656dc68cf99b6f56`)
  `third_party/luajit-upstream` -> `LuaJIT/LuaJIT` `v2.1` (`a4c064539ea931274d407e1249b4bb575424a0f4`), including the backported LuaJIT 3.0 syntax extensions (`?.`, `??`, and others).
  `patches/luajit-relver.patch` embeds this commit's timestamp, `1792588164`,
  so Zig builds report `LuaJIT 2.1.1792588164` without relying on a Git working directory.
- The font stack uses a tiny local wrapper so Hollow can follow Ghostty's
  package style while keeping the exact build graph under this repo's control.
