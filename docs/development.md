# Development

This page covers building Hollow from source, running tests, and the
project layout you'll touch when contributing.

For a release build see [Packaging](packaging.md).
For a quick first run see [Getting started](getting-started.md).
For the per-platform caveats see [Platforms](platforms/README.md).

## Toolchain

- Zig **0.15.2** is the only supported version. The repo pins it in
  `.tool-versions`. The wrapper `scripts/check-zig-version.sh` will
  hard-fail on any other version.
- A C/C++ toolchain for the Zig C backend.
- Git, to fetch submodules.
- Windows-specific: the `x86_64-windows-gnu` Zig target. The
  `launch.sh` wrapper handles the cross-compile from WSL.

```bash
zig version   # must print 0.15.2
```

If you use `asdf` or `mise`, the local `.tool-versions` installs the
right toolchain:

```bash
asdf install
# or
mise install
```

## First-time setup

```bash
./scripts/setup.sh
```

`setup.sh` initializes submodules, then re-applies the project patches
in `patches/` to `third_party/sokol` and `third_party/lua-zluajit`.
Re-run it any time the submodules change.

## Build and run

### From WSL (primary)

```bash
./launch.sh                # build and run
./launch.sh --build-only   # build only
./launch.sh --debug        # Debug build instead of ReleaseFast
./launch.sh --safe-render  # disable swapchain glyphs + multi-pane cache
./launch.sh --no-swapchain-glyphs
./launch.sh --no-multi-pane-cache
./launch.sh --list-fonts
./launch.sh --match-font mono
./launch.sh --json
```

`launch.sh` cross-builds `x86_64-windows-gnu`, copies the executables
into the repo root, and execs `hollow.exe` with the rest of the args.
Pass `--app-arg=...` to forward args the wrapper does not understand.

Lua dev loop: after one build, Lua files under `src/lua/` are loaded
from disk when present, so `--no-build` is enough for Lua-only changes.

### From Windows (native)

Open an elevated `x86_64-windows-gnu` shell, then:

```bash
zig build run
```

`zig build run` is non-Windows only; use `launch.sh` for the dev loop
from WSL.

## CLI flags

`hollow.exe` and the wrapper accept the following flags:

| Flag | Effect |
| --- | --- |
| `--config path` | Use `path` as the override config |
| `--renderer-safe-mode` | Disable swapchain glyphs and the multi-pane cache |
| `--renderer-disable-swapchain-glyphs` | Only disable the swapchain glyph path |
| `--renderer-disable-multi-pane-cache` | Only disable the multi-pane cache |
| `--startup-command text` | Send `text` to the first pane after startup |
| `--startup-command-delay-frames n` | Wait `n` frames before sending (default 20) |
| `--snapshot-dump path` | Dump a frame snapshot to `path` for headless debugging |
| `--list-fonts` | Print available font families |
| `--match-font query` | Filter `--list-fonts` output |
| `--json` | Emit JSON for `--list-fonts` |
| `--help` | Print the usage line |
| `cli …` | Run the [native CLI subcommand](reference/cli/native.md) instead of opening the GUI |

### Wrapper flags

| Flag | Effect |
| --- | --- |
| `--no-build` | Skip the `zig build` step |
| `--build-only` | Build, then exit without running |
| `--debug` | `-Doptimize=Debug` |
| `--target=TARGET` | Override the build target (default `x86_64-windows-gnu`) |
| `--safe-render` | Implies `--renderer-safe-mode` and `--renderer-disable-swapchain-glyphs` |
| `--no-swapchain-glyphs` | Forward `--renderer-disable-swapchain-glyphs` |
| `--no-multi-pane-cache` | Forward `--renderer-disable-multi-pane-cache` |
| `--list-fonts`, `--match-font QUERY`, `--json` | Forward to the executable |
| `--app-arg=ARG` | Forward `ARG` to the executable |

## Tests

```bash
zig build test
```

The test target runs the host-side unit tests.
There is also a small Lua runtime test under
[`src/lua/tests/runtime_test.lua`](../src/lua/tests/runtime_test.lua);
the Lua bridge picks it up when the Lua test harness is wired in.

## Editor support (LuaLS)

The public Lua API surface is described as
[EmmyLua](https://github.com/EmmyLua/EmmyLua) annotations in
[`types/hollow.lua`](../types/hollow.lua). The shipped base config
embeds that file into the binary at build time, so you get the same
type information at runtime, but to get type hints, jump-to-def, and
inline docs in your editor, point LuaLS at it from a `.luarc.json`
next to your config or plugin:

```jsonc
{
  "runtime.version": "LuaJIT",
  "workspace.library": [
    "%APPDATA%/hollow/types",  // Windows
    "~/.config/hollow/types"   // Linux/macOS
  ]
}
```

The `types/` directory is a copy of `types/hollow.lua` from the
Hollow repo. The shipped base config writes it to your config dir
on first run, so the path above resolves once Hollow has been
launched at least once. To pull a fresh copy from a newer Hollow
release, copy `types/hollow.lua` from the repo at the matching tag.

### Plugin authors

Open the Hollow repo alongside your plugin in your editor, or
symlink the types dir into your plugin root:

```bash
ln -s /path/to/hollow/types ./types
```

That lets LuaLS see both your plugin modules and the `hollow.*`
namespaces without any per-plugin `runtime.path` hacks.

### Updating types

When the Lua API changes, the matching edits to
`types/hollow.lua` ship in the same commit. See
[Conventions](#conventions) below.

## Project layout

```text
hollow/
├── conf/init.lua                 shipped default config (and the default UX)
├── types/hollow.lua              LuaLS EmmyLua typings for the public Lua API
├── src/
│   ├── main.zig                  CLI parsing, logging, startup into App
│   ├── app.zig                   config resolution, runtime wiring, host behavior
│   ├── config.zig                config schema and merging
│   ├── mux.zig                   tab + workspace + pane multiplexer
│   ├── pane.zig                  individual pane state
│   ├── command.zig               host-side command dispatch
│   ├── command_ipc.zig           command IPC
│   ├── native_cli.zig            `hollow cli …` subcommand
│   ├── platform.zig              platform-specific paths and defaults
│   ├── lua/                      Lua-side runtime (core, config, ui, theme, ...)
│   ├── pty/
│   │   ├── pty_windows.zig       Windows PTY + WSL bypass logic
│   │   ├── pty_posix.zig         POSIX PTY (partial; Linux build is broken)
│   │   ├── launch_command.zig    shell launch command builder
│   │   └── wsl_bypass_protocol.zig  APC frame protocol
│   ├── render/                   Sokol + FreeType + HarfBuzz
│   ├── term/ghostty.zig          libghostty-vt binding
│   ├── ui/                       UI helpers
│   ├── htp_pipe.zig, htp_transport.zig
│   ├── wsl_bypass.zig            Linux-side WSL bypass helper
│   └── selection.zig, fastmem.zig
├── examples/                     example configs, plugins, HTP helpers
├── shell-integration/            shell-side HTP helpers
├── scripts/                      build, install, helper scripts
├── patches/                      patches applied by scripts/setup.sh
├── third_party/                  git submodules
├── vendor/                       vendored C dependencies
├── docs/                         this documentation
├── launch.sh                     primary dev workflow
└── build.zig / build.zig.zon     Zig build config
```

## Conventions

- Zig source follows existing conventions; no formatter is enforced,
  match the surrounding code.
- Lua is formatted with `stylua`; `stylua.toml` is at the repo root.
- Docs use sentence-per-line Markdown; `npx markdownlint docs/` should
  stay clean.
- Do not hand-edit vendored deps under `vendor/` or `third_party/`
  unless the task is explicitly about dependencies.
- When adding or changing Lua API surface, update `types/hollow.lua`
  in the same commit so LuaLS picks it up.

## See also

- [Packaging](packaging.md) — release artifacts
- [Platforms](platforms/README.md) — per-OS build notes
- [Troubleshooting](troubleshooting.md) — common build issues
