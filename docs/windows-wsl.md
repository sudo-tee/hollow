# Windows & WSL Setup Guide

## Current runtime model

Hollow now embeds Ghostty, FreeType, HarfBuzz, Zlib, and LuaJIT directly into
`hollow-native.exe`.

That means:

- no `ghostty-vt.dll`
- no `lua51.dll`
- no FreeType/HarfBuzz dependency DLL set

For normal development, the only file you need to run is:

- `zig-out/bin/hollow-native.exe`

The default project config is resolved from:

1. `%APPDATA%\hollow\init.lua` on Windows when present
2. `conf/init.lua` in the project root during local development
3. `conf/init.lua` next to the executable for packaged releases

## WSL shell usage

The default Windows config uses:

```lua
hollow.config.set({ shell = "wsl.exe" })
```

This is the recommended development shell on Windows if you primarily work out
of WSL.

Examples:

```lua
hollow.config.set({ shell = "wsl.exe" })
hollow.config.set({ shell = "wsl.exe --distribution Ubuntu" })
hollow.config.set({ shell = "wsl.exe --distribution Ubuntu --exec /bin/fish" })
```

## Native Windows shell usage

You can also run directly with PowerShell or cmd:

```lua
hollow.config.set({ shell = "pwsh.exe" })
-- hollow.config.set({ shell = "powershell.exe" })
-- hollow.config.set({ shell = "cmd.exe" })
```

## Build from WSL

```bash
./launch.sh --build-only
```

The default target is `x86_64-windows-gnu`.

## Release packaging

For a packaged Windows release, include at least:

- `hollow-native.exe`
- `conf/init.lua`
- the `fonts/` directory if your config references bundled font files by path

If you want a self-contained portable release, ship the fonts referenced by
`conf/init.lua` together with the executable.

## Troubleshooting

| Problem | Fix |
|---|---|
| `wsl.exe not found` | Run `wsl --install` from elevated PowerShell |
| `CreatePseudoConsole` error | Upgrade to Windows 10 1809+ or Windows 11 |
| config not loading in packaged build | Put `conf/init.lua` next to the exe |
| missing glyphs | Ship the configured fonts directory with the release |
