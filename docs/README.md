# Documentation

This directory is the documentation hub for Hollow.

These pages are written to work both as repo docs and as the foundation for a
future docs site. The structure is intentionally simple: overview, guides,
reference, and examples.

## At A Glance

- Overview: [../README.md](../README.md)
- Guides: [configuration.md](configuration.md), [windows-wsl.md](windows-wsl.md)
- Reference: [hollow-lua-api.md](hollow-lua-api.md), [hollow-cli.md](hollow-cli.md)
- Examples: [htp-shell-examples.md](htp-shell-examples.md)

## Use This Directory To

- understand how the product is described at a high level
- find the right guide or reference page quickly
- preserve a docs structure that can be published later with minimal reshaping

## Start Here

| File                                           | Category  | What it covers                                                          |
| ---------------------------------------------- | --------- | ----------------------------------------------------------------------- |
| [../README.md](../README.md)                   | Overview  | Product summary, current status, and quick start                        |
| [configuration.md](configuration.md)           | Guide     | How config loading works, what ships by default, and how to override it |
| [windows-wsl.md](windows-wsl.md)               | Guide     | The primary validated platform workflow, packaging, and troubleshooting |
| [hollow-lua-api.md](hollow-lua-api.md)         | Reference | The current Lua runtime API                                             |
| [hollow-cli.md](hollow-cli.md)                 | Reference | The simplified HTP client                                               |
| [htp-shell-examples.md](htp-shell-examples.md) | Examples  | Shell-side HTP helpers and practical examples                           |

## Source Of Truth

These files are the most important companions to the docs:

- `conf/init.lua`: the shipped default config and the clearest picture of the default UX
- `types/hollow.lua`: LuaLS typings for the public Lua surface
- `src/main.zig`: native CLI flags and startup flow
- `src/app.zig`: config resolution, runtime wiring, and host behavior
- `src/pty/pty_windows.zig`: Windows PTY behavior, including WSL bypass fallback logic

## Suggested Site Structure

If you turn this into a documentation site, the current layout already maps well
to a simple navigation tree:

- Overview
- Guides
- Reference
- Examples

In practice that means:

- [`README.md`](../README.md) as the landing page
- [`configuration.md`](configuration.md) and [`windows-wsl.md`](windows-wsl.md) as guides
- [`hollow-lua-api.md`](hollow-lua-api.md) and [`hollow-cli-plan.md`](hollow-cli-plan.md) as reference material
- [`htp-shell-examples.md`](htp-shell-examples.md) as examples and integration recipes
