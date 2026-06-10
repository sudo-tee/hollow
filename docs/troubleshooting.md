# Troubleshooting

This page is the in-between for "I read the docs and it still does not
work." Each section lists the symptom, the most likely cause, and the
fix.

For deeper platform-specific notes see
[Windows](platforms/windows.md#troubleshooting) and
[WSL](platforms/wsl.md#troubleshooting).

## Build

### `zig version` is not `0.15.2`

Zig `0.16.x` is not yet compatible.
The `scripts/check-zig-version.sh` script will refuse to build with
any other version.

```bash
zig version
# 0.15.2
```

Use `asdf install` or `mise install` to pick up the pinned toolchain
from `.tool-versions`.

### `zig build run` fails on Linux

The Linux build is currently broken and not a validated target. See
[Linux](platforms/linux.md).

### Submodule drift after a pull

Run `./scripts/setup.sh` again. It re-applies the project patches in
`patches/` to `third_party/sokol` and `third_party/lua-zluajit`.

## Runtime

### Window opens but renders garbage

Try the safe-render path:

```bash
./launch.sh --safe-render
```

That sets `--renderer-safe-mode`, which disables swapchain glyphs and
the multi-pane cache. If the safe path renders correctly, file an
issue with the renderer flags your machine exposes.

### Config changes are ignored

`hollow.config.set(...)` writes to the in-memory config, but the
change persists only if it lives in a file Hollow reads. The runtime
loads `conf/init.lua` (base) and `%APPDATA%\hollow\init.lua` (override)
on startup and on `<leader>uu` reload.

Verify the file Hollow is reading:

- Personal override: `%APPDATA%\hollow\init.lua`
- Explicit override: pass `--config path` to the executable

Then trigger a reload with `<leader>uu`.

### Packaged build starts without my settings

The shipped base config (or the embedded fallback if you did not ship
`conf/init.lua`) is loaded first. Put your overrides in
`%APPDATA%\hollow\init.lua` or pass `--config path` on the command
line.

### Missing glyphs

Set `fonts.family` to a font installed on the host. List the
inventory:

```bash
./hollow.exe --list-fonts
./hollow.exe --match-font mono
```

Or from Lua:

```lua
local preferred = hollow.fonts.pick({
  "Cascadia Mono", "Consolas", "DejaVu Sans Mono",
})
if preferred then
  hollow.config.set({ fonts = { family = preferred } })
end
```

Use `fonts.fallbacks` for symbols:

```lua
hollow.config.set({
  fonts = {
    family = "Cascadia Mono",
    fallbacks = { "Segoe UI Symbol", "Noto Sans Symbols 2" },
  },
})
```

### Hyperlinks do not open

`hollow.hyperlinks.shift_click_only` defaults to `true`; hold
`Shift` while clicking. To open on plain click, set it to `false`.

The prefixes and delimiters also matter; see
[`hollow.config` → hyperlinks](reference/lua/config.md#hyperlinks).

### Copy mode keybindings do not work

Copy-mode bindings are mode-scoped. A binding set without
`{ mode = "copy_mode" }` only applies in normal mode:

```lua
hollow.keymap.set("j", "copy_mode_move_down", { mode = "copy_mode" })
```

The shipped `conf/init.lua` ships the default vim-ish bindings; if
your override is missing them, you have to add them back.

## WSL

### `wsl.exe not found`

Install WSL with `wsl --install` from elevated PowerShell and restart.

### Bypass helper does not activate

The helper is now auto-deployed by Hollow on first use — no manual
install is needed.

Check that `hollow-wsl-bypass` exists alongside the Hollow exe:

```bash
ls -la "$(dirname "$(which hollow-native.exe)")/hollow-wsl-bypass"
```

During development, `zig build` produces it in `zig-out/bin/` alongside
the exe.

If the auto-deploy fails, look in `hollow.log` for
`wsl bootstrap failed` or
`wsl bypass unavailable, falling back to ConPTY`.

The old manual install still works as
a fallback (run `zig build install-wsl-bypass` from a source checkout).

### Wrong WSL distro launches

The default `wsl` domain follows `wsl.exe`'s default distro.
Use the `{distro}WSL` domains populated by
`hollow.config.populate_wsl_domains()` to address a specific one:

```lua
hollow.term.new_tab({ domain = "UbuntuWSL" })
```

Or set `wsl_distro` on the domain:

```lua
hollow.config.set({
  domains = {
    wsl = { shell = "wsl.exe -d Ubuntu" },
  },
})
```

### `cwd` shows a Windows path inside WSL

Use a workspace source with `cwd_resolver = "wsl_unc"`, or pass a
Linux `cwd` directly to `new_tab` / `split_pane`. See
[WSL → WSL workflow patterns](platforms/wsl.md#wsl-workflow-patterns).

## Plugins

### `hollow.plugins.setup(...)` is a no-op

The setup function clones git plugins into `hollow.fs.data_dir() .. "/plugins"`.
If the clone fails (network, auth, wrong URL), the plugin is skipped
and the loader continues. Check `hollow.log` for the git error.

Local plugins are read from the path you give them; check that path
exists and that `lua/` and `hollow_plugin/` are at the expected
locations.

### Plugin loads but `M.setup` does not run

`M.setup` runs only if `require("module-name")` returns a table with a
`setup` function. The module name is the last path component of the
plugin path. So a plugin at `~/code/hollow-hello` must provide
`lua/hollow-hello/init.lua` (note the directory name matches the
require name).

## Logs

- `hollow.log` — written next to the executable; every panic, every
  `std.log.*` line.
- `hollow.log` is truncated on each startup.
- For crash reports, send the log; symbolication requires a
  build with matching PDBs as described in
  [Packaging → Crash reports](packaging.md#crash-reports).

## See also

- [Platforms](platforms/README.md) — per-OS build notes
- [Development](development.md) — build flags
- [WSL](platforms/wsl.md#troubleshooting) — WSL-specific issues
- [Packaging](packaging.md#crash-reports) — crash reporting workflow
