# Packaging

This page covers what to ship in a release, the runtime layout
end-users will see, and how to bundle the WSL bypass helper and the
Python `hollow-cli` client.

For build flags see [Development](development.md#build-and-run).
For the WSL bypass helper shipped with Windows releases see
[WSL → Bypass helper](platforms/wsl.md#bypass-helper).
For the Python client see
[Python `hollow-cli`](reference/cli/hollow-cli.md).

Debug symbols (`.pdb` files) are deliberately not bundled in releases.
See [Crash reports](#crash-reports) below for how to symbolicate
crashes when a user reports them.

## Release artifacts (Windows)

A Windows release zip should contain:

| File                                         | Role                                         |
| -------------------------------------------- | -------------------------------------------- |
| `hollow.exe`                                 | Console launcher and `hollow cli …` host     |
| `hollow-gui.exe`                             | Console-less GUI shim                        |
| `hollow-native.exe`                          | Actual GUI process                           |
| `hollow-cli` _(optional)_                    | Python HTP client (talks OSC over a tty)     |
| `conf/init.lua` _(optional)_                 | Editable shipped base config                 |
| `hollow-wsl-bypass`                           | Linux-side WSL helper binary (auto-deployed) |
| `scripts/install-wsl-bypass.sh` _(optional)_ | Legacy manual install script                 |
| `README.md`, `LICENSE`                       | Standard release files                       |

`hollow-wsl-bypass` is auto-deployed by Hollow on first use — copy
from alongside the exe to `/tmp/hollow-wsl-bypass` inside the WSL
distro. Without it, WSL panes still work through ConPTY but with
limitations: no image protocol, no Sixel, and no Python `hollow-cli`
over a redirected WSL pty.
See [WSL → Bypass helper](platforms/wsl.md#bypass-helper).

Without `hollow-cli`, end users can still drive Hollow from outside
via the native [`hollow cli …`](reference/cli/native.md) subcommand
that talks to the host command socket. The Python client is for
shell-side and PowerShell-side use cases where no host-side
executable is reachable.

## Default runtime layout

After a user unpacks a release and runs `hollow.exe` once:

```text
<install dir>/
  hollow.exe
  hollow-gui.exe
  hollow-native.exe
  hollow-cli                  # Python client, if shipped
  conf/
    init.lua                  # shipped base, if shipped
  hollow.log                  # log file, written next to the executable
  %APPDATA%\hollow\
    init.lua                  # user override (does not exist by default)
    plugins\                  # cloned git plugins
    layouts\                  # named workspace layouts
      default.json
    state\                    # runtime state (UI cache, etc.)
```

The base config in `conf/init.lua` is loaded first; the user override
at `%APPDATA%\hollow\init.lua` is merged on top.
With no override, Hollow runs the shipped base config verbatim.

## Editable base config

Ship `conf/init.lua` in the release if you want the user to be able to
fork the base config without rebuilding.
Without it, Hollow falls back to the embedded base compiled into
`hollow-native.exe`, which can only be changed by rebuilding.

The shipped base config is intentionally minimal — no personal SSH
hosts, no project paths, no machine-specific automation. Encourage
users to put overrides in `%APPDATA%\hollow\init.lua`.

## Build commands

```bash
# Release build (default)
zig build -Doptimize=ReleaseFast

# Debug build
./launch.sh --debug

# Build only, no run
./launch.sh --build-only
```

`launch.sh` is the dev loop; `zig build -Doptimize=ReleaseFast` is the
shape of a CI release build.

## WSL bypass helper

The bypass helper is now built as part of the default build step.
`zig build` produces `hollow-wsl-bypass` alongside the main exe:

```bash
zig build -Doptimize=ReleaseFast
```

At runtime, Hollow auto-deploys it to `/tmp/hollow-wsl-bypass` inside
the WSL distro on first use. No manual install is required.

If you ship a release bundle, include `hollow-wsl-bypass` alongside
`hollow-native.exe` in the same directory. The auto-deploy finds it
there automatically.

The legacy manual install (`zig build install-wsl-bypass` →
`/usr/local/bin/hollow-wsl-bypass`) still works as a fallback.
See [WSL → Bypass helper](platforms/wsl.md#bypass-helper).

## Crash reports

Releases do not include `.pdb` files, so the shipped bundle cannot
symbolicate a crash on its own.
To symbolicate a user-reported crash:

1. Build the matching release with `zig build -Doptimize=ReleaseFast`
   from the same source tree.
2. Capture `hollow.pdb`, `hollow-gui.pdb`, and `hollow-native.pdb`
   from `zig-out/bin/`.
3. Ask the user for `hollow.log` from the install dir.
4. Resolve addresses from `hollow.log` against the matching PDB.

The log file records panics, including the error return trace and the
host stack trace, written by `src/main.zig:panic`. The matching PDB
turns those addresses into function and source line info.

If you do not have a build with matching PDBs, ask the user for a
debug build (`./launch.sh --debug`) and the matching log. End users
do not need to keep PDBs locally to use Hollow; they are only
required to interpret a captured crash dump.

## See also

- [Development](development.md) — build flags
- [WSL → Bypass helper](platforms/wsl.md#bypass-helper)
- [Troubleshooting](troubleshooting.md)
