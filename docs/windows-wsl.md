# Windows And WSL

Windows and WSL are the primary validated environment for Hollow today.

Hollow is a Windows-native app in this workflow. WSL is an optional shell domain
and integration target, not a separate Linux build path for the main app.

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
- `wsl/hollow-wsl-bypass` and `scripts/install-wsl-bypass.sh` if you want users to enable the WSL PTY bypass from the release bundle
- `hollow-native.pdb` next to the executable, so Windows crash addresses can be resolved to functions and source lines

## Debug Symbols

Windows builds emit a `hollow-native.pdb` file next to `hollow-native.exe`.

Keep that file with the exact executable that produced a crash. Without the
matching PDB, Windows stack traces in `hollow.log` will only show raw
addresses.

For packaged releases, ship both:

- `hollow-native.exe`
- `hollow-native.pdb`

When diagnosing a crash on Windows, keep these together and then resolve the
addresses from `hollow.log` with a debugger or symbol-aware stack tool against
that matching PDB.

## WSL PTY Bypass

Hollow can launch WSL panes through a small Linux-side helper instead of ConPTY.
This bypass is optional.

How it works:

- Hollow tries the helper only for `wsl.exe`-backed domains
- if the helper is installed in the WSL distro `PATH`, Hollow uses it
- if the helper is missing or fails to start, Hollow falls back to the normal ConPTY path automatically

Benefits:

- avoids the extra ConPTY layer for WSL shells
- improves throughput and interactive latency in WSL-heavy workflows

Install from a source checkout:

```bash
zig build install-wsl-bypass
```

That target builds `hollow-wsl-bypass` and installs it to:

- `/usr/local/bin/hollow-wsl-bypass` inside the default WSL distro

Install from a release bundle:

```bash
wsl sh -lc 'sudo install -d -m 755 /usr/local/bin && sudo install -m 755 /mnt/c/path/to/hollow/wsl/hollow-wsl-bypass /usr/local/bin/hollow-wsl-bypass'
```

Requirements:

- `/usr/local/bin` must be on the WSL shell `PATH`
- Hollow must launch WSL through `wsl.exe` as usual

If you do nothing, WSL still works through ConPTY.

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

| Problem                                            | Fix                                                                                                               |
| -------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `wsl.exe not found`                                | Install WSL with `wsl --install` from elevated PowerShell                                                         |
| WSL bypass does not activate                       | Install `hollow-wsl-bypass` into WSL `PATH` with `zig build install-wsl-bypass`; otherwise Hollow will use ConPTY |
| config changes are ignored                         | Edit `%APPDATA%\hollow\init.lua` or use `--config path`, then reload with `<leader>uu`                            |
| packaged build starts without your custom settings | Put your overrides in `%APPDATA%\hollow\init.lua` or launch with `--config path`                                  |
| packaged build cannot find `conf/init.lua`         | Hollow falls back to the embedded base config; ship `conf/init.lua` only if you want an editable packaged default |
| rendering glitches from a repo checkout            | Try `./launch.sh --safe-render`                                                                                   |
| rendering glitches from a packaged build           | Try `hollow-native.exe --renderer-safe-mode`                                                                      |
| missing glyphs                                     | Set `fonts.family` or `fonts.fallbacks` to fonts installed on that machine                                        |
