# Development

Build the standalone CLI without GUI dependencies with
`zig build --build-file build-agent.zig cli cli-all`. Run its shared command and
transport checks with `zig build --build-file build-agent.zig test-cli`.

Command API checks can run without GUI libraries: `zig build test-command`.
This covers command contracts/examples, native CLI parsing, and real loopback
socket validation. `zig build test` also includes these checks.

The bundled LuaJIT 2.1 includes the backported LuaJIT 3.0 syntax extensions,
including safe navigation (`object?.field`) and nil coalescing (`value ?? fallback`).
See [LuaJIT extensions](https://luajit.org/extensions.html). Run `zig build test-luajit`
to exercise the bundled runtime (interpreter, JIT, and bytecode loading).
System `luajit` installations used by `scripts/test-lua.sh` may be older; keep
shared test fixtures compatible or test new syntax through `test-luajit`.

This page covers building Hollow from source, running tests, and the
project layout you'll touch when contributing.

For a release build see [Packaging](packaging.md).
For a quick first run see [Getting started](getting-started.md).
For the per-platform caveats see [Platforms](platforms/README.md).

## Toolchain

- Zig **0.17.0** is the only supported version. The repo pins it in
  `.tool-versions`. The wrapper `scripts/check-zig-version.sh` will
  hard-fail on any other version.
- A C/C++ toolchain for the Zig C backend.
- Git, to fetch submodules.
- Python 3, to generate the checksummed guest-agent bundle included in normal builds.
- Windows-specific: the `x86_64-windows-gnu` Zig target. The
  `launch.sh` wrapper handles the cross-compile from WSL.

```bash
zig version   # must print 0.17.0
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

`setup.sh` initializes submodules, fetches Zig packages, then re-applies the project patches in `patches/` to their pinned dependency sources.
Re-run it any time dependency pins change or `zig-pkg/` is regenerated.

## Build and run

### From WSL (primary)

```bash
./launch.sh                # build and run
./launch.sh --build-only   # build only
./launch.sh --install --build-only # build and copy to C:\Applications\Hollow
./launch.sh --debug        # Debug build instead of ReleaseFast
./launch.sh --pdb          # ReleaseFast with debug symbols for profiling/crashes
./launch.sh --dev          # Debug app + ReleaseFast C deps, app executables only
./launch.sh --safe-render  # disable swapchain glyphs + multi-pane cache
./launch.sh --no-swapchain-glyphs
./launch.sh --no-multi-pane-cache
./launch.sh --list-fonts
./launch.sh --match-font mono
./launch.sh --json
```

`launch.sh` cross-builds `x86_64-windows-gnu` and execs
`zig-out/bin/hollow.exe` with the rest of the args. No Windows tools or
installation are needed for `--build-only`, so it also works on Linux CI.
Use `--install` from WSL to copy executables, available debug symbols,
helpers, Lua files, and config to `C:\Applications\Hollow`. With this flag,
the installed executable runs unless `--build-only` is also set.
Combine `--install --no-build --build-only` to install an existing build.
Pass `--app-arg=...` to forward args the wrapper does not understand.

Lua dev loop: after one build, Lua files under `src/lua/` are loaded
from disk when present, so `--no-build` is enough for Lua-only changes.

### Build-time diagnostics

Keep `ReleaseFast` when measuring the build used day to day:

```bash
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast --summary new
```

The compile step includes semantic analysis, LLVM optimization/code generation,
and linking. A long "linking" progress label does not establish which phase is
expensive. For detailed compiler and LLVM pass timings, use:

```bash
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast --time-report
```

This forces recompilation and opens Zig's build web UI, so it is not a normal
incremental-build timing. Dependencies that are normally cached are rebuilt too.

Normal `ReleaseFast` application builds omit debug information to reduce LLVM
work, but retain the same optimization level. Use `-Dpdb` with `zig build`, or
`--pdb` with `launch.sh`, when you need matching symbols for a profiler or crash
report. Debug builds keep their default debug information.

Windows builds produce `hollow.exe` (console launcher) and `hollow-native.exe`
(GUI), plus the standalone CLI and guest bundles. The redundant console-less
`hollow-gui.exe` launcher is no longer built or installed; existing shortcuts can
point directly to `hollow-native.exe` instead.
Old output/install directories may still contain the former shim or PDBs from
previous builds; they are not deleted automatically. Stage releases from the
current artifact list rather than copying every file from an old output directory.

#### Dev mode

`./dev.sh` (and `make dev`) builds with `launch.sh --dev` by default, which runs
`zig build gui -Ddev`:

- `-Ddev` compiles the app's Zig code in Debug, while freetype, harfbuzz, LuaJIT
  and ghostty stay ReleaseFast, so they are fast at runtime and stay cached.
- The `gui` step installs only `hollow-native.exe` and `hollow.exe` (or `hollow`
  on Linux). It skips the standalone CLI and the musl CLI and agent bundles, so
  edits to shared code don't trigger cross-builds. Existing bundles in `zig-out`
  are left as they are; run a full `zig build` when you change CLI or agent code.

Pass `--release` to `dev.sh` for a ReleaseFast build. `--debug`, `--pdb` and
`--install` also leave dev mode, and `--install` always runs the full install
step. `dev.sh` rebuilds when you switch modes (it tracks the mode in
`zig-out/.launch-build-mode`).

The same `src/main.zig` comment-only edit rebuilds in about 15 s in dev mode,
compared with about 60 s for ReleaseFast. Profile and benchmark with ReleaseFast
builds, not dev mode.

#### Initial measurements (2026-10-30)

Zig 0.17.0, WSL, `x86_64-windows-gnu`, ReleaseFast, warm dependency caches.
Each measurement invalidated `src/main.zig` with the same comment-only edit;
these are single-run observations, not a statistical benchmark.

| Configuration | Source-edit rebuild wall time |
| --- | ---: |
| Original: symbols enabled, two launchers | 83.72 s |
| Symbols omitted, redundant launcher removed | 59.72 s |

The combined change reduced this rebuild by about 29%, without lowering the
optimization level. Separate instrumented app compilations measured LLVM at
87.69 s with debug information versus 64.26 s without it, while link flush was
0.42 s versus 0.16 s. Instrumented runs are not directly comparable to normal
build wall times. The first stripped build also had cold runtime artifacts, so
its total wall time was excluded from the warm-cache comparison.

### From Windows (native)

Open an elevated `x86_64-windows-gnu` shell, then:

```bash
zig build run
```

`zig build run` is non-Windows only; use `launch.sh` for the dev loop
from WSL.

## CLI flags

`hollow.exe` and the wrapper accept the following flags:

| Flag                                  | Effect                                                                              |
| ------------------------------------- | ----------------------------------------------------------------------------------- |
| `--config path`                       | Use `path` as the override config                                                   |
| `--renderer-safe-mode`                | Disable swapchain glyphs and the multi-pane cache                                   |
| `--renderer-disable-swapchain-glyphs` | Only disable the swapchain glyph path                                               |
| `--renderer-disable-multi-pane-cache` | Only disable the multi-pane cache                                                   |
| `--startup-command text`              | Send `text` to the first pane after startup                                         |
| `--startup-command-delay-frames n`    | Wait `n` frames before sending (default 20)                                         |
| `--snapshot-dump path`                | Dump a frame snapshot to `path` for headless debugging                              |
| `--list-fonts`                        | Print available font families                                                       |
| `--match-font query`                  | Filter `--list-fonts` output                                                        |
| `--json`                              | Emit JSON for `--list-fonts`                                                        |
| `--help`                              | Print the usage line                                                                |
| `cli …`                               | Run the [native CLI subcommand](reference/cli/native.md) instead of opening the GUI |

### Wrapper flags

| Flag                                           | Effect                                                                   |
| ---------------------------------------------- | ------------------------------------------------------------------------ |
| `--no-build`                                   | Skip the `zig build` step                                                |
| `--build-only`                                 | Build, then exit without running                                         |
| `--install`                                    | Copy Windows artifacts to `C:\Applications\Hollow` from WSL; run from there unless `--build-only` |
| `--debug`                                      | `-Doptimize=Debug`                                                       |
| `--pdb`                                        | Retain debug symbols in a ReleaseFast build (`-Dpdb`)                    |
| `--dev`                                        | `gui -Ddev`: Debug app, ReleaseFast deps, app executables only          |
| `--target=TARGET`                              | Override the build target (default `x86_64-windows-gnu`)                 |
| `--safe-render`                                | Implies `--renderer-safe-mode` and `--renderer-disable-swapchain-glyphs` |
| `--no-swapchain-glyphs`                        | Forward `--renderer-disable-swapchain-glyphs`                            |
| `--no-multi-pane-cache`                        | Forward `--renderer-disable-multi-pane-cache`                            |
| `--list-fonts`, `--match-font QUERY`, `--json` | Forward to the executable                                                |
| `--app-arg=ARG`                                | Forward `ARG` to the executable                                          |

## Tests

```bash
zig build test
```

The test target runs the host-side unit tests.
`scripts/setup.sh` checks for Busted and installs version 2.3.0 through
LuaRocks when it is missing.
The Lua API suite uses [Busted](https://lunarmodules.github.io/busted/) and
can be installed with LuaRocks:

```bash
luarocks --lua-version=5.1 install busted 2.3.0
./scripts/test-lua.sh
```

Use `zig build test-lua` for the same Lua suite through the Zig build, or
`zig build test-all` to run both native and Lua tests.
The Busted runner discovers every `src/lua/tests/test_*.lua` file, and accepts
normal Busted options such as `--filter`, `--list`, and `--output=junit`.

## Rendering benchmark

Run the workload inside a Hollow pane:

```bash
bench.sh sync-output 120 60 4
```

Arguments are synchronized batches, target batches per second, and updates
per batch. Each batch rewrites the viewport between `CSI ?2026h` and
`CSI ?2026l`. Run once with `synchronized_output = true` and once with
`synchronized_output = false`, then compare renderer CPU and frame behavior.

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
    "%APPDATA%/hollow/types", // Windows
    "~/.config/hollow/types", // Linux/macOS
    "/mnt/c/Users/YOUR_USER/AppData/Roaming/hollow/types", // WSL
  ],
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
│   │   └── hollow/host/pty.lua   pane host selection/pool
│   ├── agent/                    `hollow-agent` (guest-side host agent)
│   │   ├── pty.zig               agent `pty` mode server
│   │   └── pty_protocol.zig      pane PTY frame protocol
│   ├── pty/
│   │   ├── pty_windows.zig       Windows ConPTY
│   │   ├── pty_posix.zig         POSIX PTY (partial; Linux build is broken)
│   │   ├── agent.zig             agent-backed pane PTY client
│   │   └── launch_command.zig    shell launch command builder
│   ├── render/                   Sokol + FreeType + HarfBuzz
│   ├── term/ghostty.zig          libghostty-vt binding
│   ├── ui/                       UI helpers
│   ├── htp_pipe.zig, htp_transport.zig
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
