# Windows

Hollow is a Windows-native terminal emulator.
This page covers install, layout, default domains, and the renderer
flags the wrapper exposes for Windows debugging.

For the build walkthrough see [Development](../development.md).
For the Windows-side WSL setup see [WSL](wsl.md).
For the shipped executable layout see [Packaging](../packaging.md).

## Install a release

Download the latest release from
[GitHub Releases](https://github.com/sudo-tee/hollow/releases).
A release zip contains:

| File | Role |
| --- | --- |
| `hollow.exe` | CLI launcher and `hollow cli …` host |
| `hollow-gui.exe` | Console-less GUI shim |
| `hollow-native.exe` | Actual GUI process |
| `hollow-cli` | Python HTP client (optional, OSC over tty) |
| `wsl/hollow-wsl-bypass` | Linux-side WSL helper (optional) |

Debug symbols (`.pdb` files) are not bundled in releases.
For crash symbolication, see
[Packaging → Crash reports](../packaging.md#crash-reports).

## Runtime layout

`hollow.exe` is a thin console launcher; it parses flags, opens
`hollow.log`, then spawns `hollow-native.exe` (the GUI) as a sibling.
The console returns immediately so the terminal you launched from is
not blocked.

```text
hollow.exe
  └─ hollow-native.exe  (D3D11 + Sokol renderer)
       └─ hollow-gui.exe (present for completeness; not used directly)
```

## Config paths

| What | Path |
| --- | --- |
| Bundled base config | `conf/init.lua` next to the executable |
| Personal override | `%APPDATA%\hollow\init.lua` |
| Explicit override | `--config path\to\init.lua` |
| Log file | `hollow.log` next to the executable |
| Data dir (plugins) | `%APPDATA%\hollow` |

The base config is loaded first, the override is merged on top.
See [Configuration](../configuration.md) for the full model.

## Default domains

The shipped base config defines these on Windows:

| Domain | Shell | Notes |
| --- | --- | --- |
| `pwsh` | `pwsh.exe` | Default |
| `powershell` | `powershell.exe` | Windows PowerShell 5.x |
| `cmd` | `cmd.exe` | Command Prompt |
| `wsl` | `C:\Windows\System32\wsl.exe` | See [WSL](wsl.md) |
| `*WSL` | one per installed distro | Populated by `populate_wsl_domains()` |

Switch the default:

```lua
hollow.config.set({ default_domain = "wsl" })
```

Customize the WSL domain:

```lua
hollow.config.set({
  domains = {
    wsl = { shell = "C:\\Windows\\System32\\wsl.exe" },
  },
})
```

## CLI flags

`hollow.exe` accepts the flags listed in [Development](../development.md#cli-flags).
The most useful Windows-specific flags:

| Flag | Effect |
| --- | --- |
| `--config path` | Use `path` as the override config |
| `--renderer-safe-mode` | Disable swapchain glyphs and the multi-pane cache |
| `--renderer-disable-swapchain-glyphs` | Only disable the swapchain glyph path |
| `--renderer-disable-multi-pane-cache` | Only disable the multi-pane cache |
| `--list-fonts`, `--match-font query`, `--json` | Dump the font inventory |
| `--startup-command text` | Send `text` to the first pane after startup |
| `--snapshot-dump path` | Dump a frame snapshot for headless debugging |
| `--help` | Print the usage line |

`launch.sh` exposes `--safe-render`, `--no-swapchain-glyphs`,
`--no-multi-pane-cache` as the dev-loop equivalents. See
[Development → Wrapper flags](../development.md#wrapper-flags).

## Debugging

- `hollow.log` is written next to the executable; every panic and
  every log line lands there.
- The shipped base config sets `debug_overlay = false` and
  `command_timing = false`. Flip them on in your personal config to
  get the on-screen overlay.
- For crash reports, send `hollow.log`; symbolication requires a
  build with matching PDBs as described in
  [Packaging → Crash reports](../packaging.md#crash-reports).

## See also

- [WSL](wsl.md) — Windows-side WSL setup and the bypass helper
- [Development](../development.md) — build from source
- [Packaging](../packaging.md) — release artifacts, runtime layout, crash reports
- [Troubleshooting](../troubleshooting.md) — common Windows issues
