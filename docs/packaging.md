# Packaging

This page covers what to ship in a release, the runtime layout
end-users will see, and how to bundle the Linux guest agents and the
standalone Zig `hollow-cli` client (plus the retained Python fallback).

For build flags see [Development](development.md#build-and-run).
For the Linux agents shipped with Windows releases see
[Linux agents](#linux-agents) and [WSL → Agent PTY](platforms/wsl.md#agent-pty).
For CLI packaging and transports see [Standalone Zig CLI](reference/cli/standalone.md).

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
| `hollow-cli.exe`                             | Standalone shared Zig CLI                   |
| `hollow-cli.py` _(optional)_                 | Legacy Python compatibility client          |
| `cli/SHA256SUMS`                             | Checksums for standalone guest CLIs         |
| `cli/linux-x86_64/hollow-cli`                | Static Linux x86_64 CLI                     |
| `cli/linux-aarch64/hollow-cli`               | Static Linux aarch64 CLI                    |
| `conf/init.lua` _(optional)_                 | Editable shipped base config                 |
| `agents/SHA256SUMS`                         | Checksums for the bundled guest agents      |
| `agents/linux-x86_64/hollow-agent`           | Static Linux x86_64 guest agent             |
| `agents/linux-aarch64/hollow-agent`          | Static Linux aarch64 guest agent            |
| `README.md`, `LICENSE`                       | Standard release files                       |

The `agents/` bundle is auto-deployed by Hollow into WSL distros, SSH
hosts and containers on first use. Without it, WSL panes still work
through ConPTY but with limitations: no image protocol, no Sixel, and
no OSC CLI traffic over the tty.
See [Linux agents](#linux-agents).

`hollow-cli` and [`hollow cli …`](reference/cli/native.md) share one parser and
typed command implementation. Linux agents embed an architecture-matched CLI
and install it in their shell bundle, without a guest Python dependency. The
separate `cli/` binaries are useful for manual SSH/WSL installation.

## Default runtime layout

After a user unpacks a release and runs `hollow.exe` once:

```text
<install dir>/
  hollow.exe
  hollow-gui.exe
  hollow-native.exe
  hollow-cli.exe              # standalone Zig CLI
  hollow-cli.py               # Python compatibility fallback
  cli/
    SHA256SUMS
    linux-x86_64/hollow-cli
    linux-aarch64/hollow-cli
  agents/
    SHA256SUMS
    linux-x86_64/hollow-agent
    linux-aarch64/hollow-agent
  conf/
    init.lua                  # shipped base, if shipped
  %APPDATA%\hollow\
    init.lua                  # user override (does not exist by default)
    hollow.log                # log file
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

Normal `zig build` also installs the selected-target CLI, both Linux agent
architectures under `zig-out/agents/`, and both Linux CLIs under `zig-out/cli/`,
with separate `SHA256SUMS` manifests. `launch.sh --install` copies both complete bundles beside
the Windows executable. With `--no-build`, a missing bundle fails installation
with build guidance rather than installing an app unable to deploy guest agents.
Guest connections verify/deploy the selected bundled binary automatically; there
is no network download. See [`hollow.host`](reference/lua/host.md) for trusted
bundle overrides, guest prerequisites and platform qualification.

## Linux agents

`hollow-agent` is a static Linux binary that serves both fs/exec RPCs
(`hollow-agent stdio`) and pane PTYs (`hollow-agent pty`). Releases ship
one per architecture plus checksums:

```text
agents/
  SHA256SUMS
  linux-x86_64/hollow-agent
  linux-aarch64/hollow-agent
```

Build the bundle on its own with:

```bash
zig build --build-file build-agent.zig agent-all
zig build --build-file build-agent.zig cli-all
```

Normal `zig build` also produces it under `zig-out/agents/`.

Ship the `agents/` folder beside `hollow-native.exe`. At runtime Hollow
picks the guest's architecture, verifies it against `SHA256SUMS`, and
installs it into the guest user's cache. WSL panes use it implicitly;
SSH/Podman/Docker panes use it through `domains.<name>.host`.
See [WSL → Agent PTY](platforms/wsl.md#agent-pty) and
[`hollow.host` → Pane PTYs](reference/lua/host.md#pane-ptys).

## Crash reports

Releases do not include `.pdb` files, so the shipped bundle cannot
symbolicate a crash on its own.
To symbolicate a user-reported crash:

1. Build the matching release with `zig build -Doptimize=ReleaseFast`
   from the same source tree.
2. Capture `hollow.pdb`, `hollow-gui.pdb`, and `hollow-native.pdb`
   from `zig-out/bin/`.
3. Ask the user for `%APPDATA%\hollow\hollow.log`.
4. Resolve addresses from `%APPDATA%\hollow\hollow.log` against the matching PDB.

The log file records panics, including the error return trace and the
host stack trace, written by `src/main.zig:panic`. The matching PDB
turns those addresses into function and source line info.

If you do not have a build with matching PDBs, ask the user for a
debug build (`./launch.sh --debug`) and the matching log. End users
do not need to keep PDBs locally to use Hollow; they are only
required to interpret a captured crash dump.

## See also

- [Development](development.md) — build flags
- [WSL → Agent PTY](platforms/wsl.md#agent-pty)
- [Troubleshooting](troubleshooting.md)
