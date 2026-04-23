# Windows And WSL

Windows and WSL are the primary validated environment for Hollow today.

Hollow is a Windows-native app in this workflow. WSL is an optional shell domain
and integration target, not a separate Linux build path for the main app.

## At A Glance

- Primary validated environment: Windows with optional WSL integration
- Main dev workflow: `./launch.sh`
- Main user config path on Windows: `%APPDATA%\hollow\init.lua`
- Current shipped Windows default domain: `pwsh`

## Use This Page To

- build and run Hollow in its main validated environment
- understand how config behaves on Windows
- switch between PowerShell and WSL-based workflows
- troubleshoot common Windows and WSL setup issues

## Development

First-time setup:

```bash
./scripts/setup.sh
```

Build and run:

```bash
./launch.sh
```

Build only:

```bash
./launch.sh --build-only
```

Debug build:

```bash
./launch.sh --debug
```

The wrapper cross-builds `x86_64-windows-gnu` and produces
`zig-out/bin/hollow-native.exe`.

Useful wrapper-only troubleshooting flags:

- `./launch.sh --safe-render`
- `./launch.sh --no-swapchain-glyphs`
- `./launch.sh --no-multi-pane-cache`

## Packaging

For a packaged release, ship at least:

- `hollow-native.exe`

Optional but recommended:

- `conf/init.lua` next to the executable, if you want the packaged defaults to stay editable without rebuilding

## Config On Windows

Hollow resolves config in two layers:

1. a base config
2. an override config

Base config resolution:

1. `conf/init.lua` next to the executable
2. otherwise `conf/init.lua` in the project directory
3. otherwise the embedded fallback in the executable

Override config resolution:

1. the file passed with `--config path`
2. otherwise `%APPDATA%\hollow\init.lua`, if present

The host process is the Windows app, so the normal personal config path in this
workflow is the Windows roaming config location:

- `%APPDATA%\hollow\init.lua`

Hollow always loads base first and override second.

## Windows Domains

The shipped Windows config currently defaults to `pwsh`.

Bundled Windows domains:

- `pwsh`
- `powershell`
- `cmd`
- `wsl`

The bundled `wsl` domain points at `C:\Windows\System32\wsl.exe`.

Use WSL as the default instead:

```lua
local hollow = require("hollow")

hollow.config.set({
  default_domain = "wsl",
})
```

Customize the shipped WSL domain:

```lua
local hollow = require("hollow")

hollow.config.set({
  domains = {
    wsl = {
      shell = "C:\\Windows\\System32\\wsl.exe",
    },
  },
})
```

## WSL Workflow

Using `wsl` as the default domain is a good fit when your daily shell,
toolchain, and SSH setup live inside Linux while Hollow itself remains a Windows
desktop app.

This is especially useful for:

- Linux-first shell workflows on a Windows machine
- WSL-backed SSH domains with `backend = "wsl"`
- workspace discovery rooted in WSL paths or UNC shares

Related docs:

- [configuration.md](configuration.md) for domain and SSH examples
- [htp-shell-examples.md](htp-shell-examples.md) for shell-to-host integration

## Troubleshooting

| Problem | Fix |
|---|---|
| `wsl.exe not found` | Install WSL with `wsl --install` from elevated PowerShell |
| config changes are ignored | Edit `%APPDATA%\hollow\init.lua` or use `--config path`, then reload with `<leader>uu` |
| packaged build starts without your custom settings | Put your overrides in `%APPDATA%\hollow\init.lua` or launch with `--config path` |
| packaged build cannot find `conf/init.lua` | Hollow falls back to the embedded base config; ship `conf/init.lua` only if you want an editable packaged default |
| rendering glitches from a repo checkout | Try `./launch.sh --safe-render` |
| rendering glitches from a packaged build | Try `hollow-native.exe --renderer-safe-mode` |
| missing glyphs | Set `fonts.family` or `fonts.fallbacks` to fonts installed on that machine |
