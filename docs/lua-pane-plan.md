# Lua pane plan: panes whose content is a Lua UI tree

Handoff document. Goal: a split or floating pane whose content comes from a Lua
`render(ctx)` function using the declarative `hollow.ui` API, laid out, focused
and closed like a terminal pane.

Non-goals (v1): scrolling viewports, text selection or copy mode in Lua panes,
running Lua panes inside the agent process, reactive state/hooks.

---

## 0. Ground rules

- Terminal panes must behave exactly as before. Any change in terminal
  rendering, input, or lifecycle output is a bug.
- Every checkpoint compiles and passes the full suite on its own (see §8).
  `zig fmt` on touched Zig, `stylua --check` on touched Lua.
- Don't commit unless the operator says so. Keep each step reviewable alone.
- If the plan is wrong, record it under "Findings", take the smallest safe
  adjustment, continue.

---

## 1. Decisions

- **Pane model: Option B** (generic node + typed terminal content). An interim
  Option A (`Pane.kind` + `isTerminal()` guards) shipped first as a tested
  safety net. Its audit found 55 guard branches instead of the ~19 estimated,
  which met the switch trigger, and the operator chose B. Guards stay until
  the tagged union replaces them.
- **Pane IDs** are explicit (`Pane.id`, allocated monotonically by `Mux`, 0
  means unpublished), not pointer addresses.
- **Rendering: reuse Clay surfaces.** The original plan to extract an overlay
  row drawer (`drawSurfaceRows`, `serialize_surface_row`) is obsolete:
  overlays already build `ui.layout` surfaces and publish Clay snapshots.
  `hollow.ui.layout` owns dirty snapshots, render revisions, per-surface
  callback tables, namespaced IDs, keyboard focus and destruction. Its native
  adapter is `src/ui/clay_surface.zig`. Lua panes reuse these with pane
  ownership, clipping to the pane rect, and pane-local input routing. Overlay
  and sidebar rendering stay unchanged.

---

## 2. Target model

```zig
// src/pane.zig: generic node, keeps the name
pub const Pane = struct {
    id: usize,                       // explicit, 0 = unpublished
    allocator, host_context,
    // geometry: x_px, y_px, width_px, height_px, cols, rows
    // floating/restore: is_floating, floating_*, restore_*
    // shared status: title, cwd, foreground_process, program_status, bell_*
    // retained-texture damage: render_dirty, title_dirty, cwd_dirty
    content: Content,

    pub const Content = union(enum) {
        terminal: TerminalPane,      // src/term/terminal_pane.zig
        lua: *LuaSurface,            // src/ui/lua_surface.zig
    };
    pub fn asTerminal(self: *Pane) ?*TerminalPane;
};
```

Terminal-only code takes `*TerminalPane`. Generic code narrows once at its
entry point (`pane.asTerminal() orelse ...`) or switches on `content`. Native
Ghostty callbacks and HTP keep the stable node as userdata and reject
non-terminal nodes.

---

## 3. Status

### Done (committed)

| Commit | Checkpoint |
| --- | --- |
| `1605305` | Explicit `Pane.id`; lookup, events, HTP, snapshots, `HOLLOW_PANE_ID`, restore anchors |
| `0677d49` | Option A safety net: `Pane.Kind`, owned `LuaSurface`, shared split/float insertion (`splitActivePaneWith`), terminal guards; `TerminalPane` started (PTY + encoders) |
| `552ea60` | Ghostty handles, render-helper lifecycle, and readiness flags move to `TerminalPane` |
| `5940ff6` | Protocol buffers, notification assembly, and startup-input queue move to `TerminalPane` |
| `5c06949` | Runtime state (spawn/domain, HTP, PTY timing, sync output, mouse, images, jobs, scrollbar) moves to `TerminalPane` |
| `0ea9eed` | Bootstrap, PTY poll, parsing, title/cwd refresh, and resize move to `src/term/pane_runtime.zig`; PTY limits in `src/term/pty_policy.zig` |
| `06263fb` | Selection, scrolling, hyperlinks narrowed to `*TerminalPane` |
| `5024e8d` | Copy mode, quick select, screen/text queries narrowed; `TerminalPane.beginRead` borrows render helpers |
| `3d65006` | B1: input, paste, HTP, jobs, native callbacks, app frame loop, resize, renderer, mux and Lua callbacks narrowed. Only tests read `pane.term` outside `src/term/` and `src/pane.zig`. Adds `Pane.domainName()`; fixes the missed HTP guard |
| (next) | B2: terminal pass-through methods removed from `Pane`. Callers use `TerminalPane` methods after narrowing; `pollPty`, `bootstrap` and `nudgeTerminal` take the node explicitly. `Pane` keeps only content-dispatching operations: `deinit`, `invalidate`, `resize`, `applyTerminalTheme`, `refreshTitle`, `refreshCwd`, `setCwd`, `setManualTitle`, `domainName` |

### Remaining

| Step | What |
| --- | --- |
| B3 | Replace `kind`/`term`/`lua_surface` with `content: Content`; drop the `isTerminal()` guards the compiler makes redundant |
| B4 | GUI benchmarks for B1 to B3 (none measured yet) |
| P1 | Clay surface ownership by a pane: draw into the pane rect, reuse `PaneCacheEntry` texture, render only when dirty |
| P2 | Lua API (§4): `split`/`float`/`invalidate`/`close`/`set_title`, `on_mount`/`on_unmount`, error row on render failure |
| P3 | Keys and focus: `on_key`, `on_focus`; unhandled keys fall through to global bindings |
| P4 | Mouse: click and hover through the pane's surface callback namespace |
| P5 | Snapshots/CLI `kind`, `module` + factories, workspace `lua` leaf (§5) |
| P6 | Types (`types/hollow.lua`) and docs (`docs/reference/lua/ui.md`, `docs/custom-ui.md`) |
| later | Scroll viewports for Lua panes; more content kinds (one union arm each) |

**Done when (v1):**
- A Lua pane can be split, floated, zoomed, focused, moved to another tab and
  closed. It is never reaped automatically.
- It renders only when dirty (verified by a counter in tests).
- Keys reach `on_key` when focused; global keybindings still work.
- Clicks and hover work with two instances of the same module open.
- Snapshot shows `kind = "lua"`; a factory-backed pane comes back after a
  workspace reload.
- Terminal behaviour unchanged: full Zig and Lua suites green, benchmarks within
  noise.

---

## 4. Lua API

```lua
local pane = hollow.ui.pane.split({
  direction = "vertical",      -- or "horizontal"
  ratio = 0.4,
  title = "Tasks",
  module = "tasks",            -- optional; required for restore (§5)
  render = function(ctx)
    -- ctx.cols, ctx.rows, ctx.focused, ctx.pane_id, ctx.theme, ctx.state
    return ui.column({ ... })
  end,
  on_key = function(key, mods, ctx) return true end,   -- true = handled
  on_mount = function(ctx) end,
  on_unmount = function(ctx) end,
  on_resize = function(ctx) end,
  on_focus = function(ctx, focused) end,
  state = {},
})

hollow.ui.pane.float(opts)      -- same options, floating
pane.id                          -- matches hollow.term pane IDs
pane:invalidate()
pane:set_title(title)
pane:close()
hollow.ui.pane.get(id)           -- instance or nil
hollow.ui.pane.register(name, factory)   -- factory(args) -> opts, used by restore
```

- New module `hollow.ui.widgets.pane` (files under `src/lua/hollow` are
  embedded automatically). `render` output becomes a `ui.layout` surface owned
  by the pane; callback IDs are namespaced per pane instance and released on
  close.
- Re-render triggers: `invalidate()`, resize, focus change, theme change,
  hover change. No per-frame Lua call when idle.
- Errors in `render` show an error row in the pane instead of crashing;
  unknown-token errors still propagate in tests.
- Terminal-only CLI verbs (send-text and similar) return `error.NotATerminal`
  for Lua panes; Lua send helpers return `false`. Already implemented.

---

## 5. Persistence and process model

- Lua panes live in the GUI process only. The agent (`src/agent`) never sees
  them. On reattach, terminal panes come back from the agent; the GUI rebuilds
  Lua panes.
- Functions can't be serialized, so restore goes through named factories:
  snapshots store `{ kind = "lua", module = "tasks", args = {...} }` and the
  layout loader calls the factory registered with `hollow.ui.pane.register`.
  A Lua pane without `module` is not restored (documented).
- Workspace layouts (`ui/workspace/source.lua` and the host layout loader) gain
  a `lua` leaf: `{ lua = "tasks", args = {...} }`.
- `hollow-cli`: listing shows `kind`; a `split --lua <module>` verb is optional.

---

## 6. Tests

- Zig: mixed terminal/Lua split, float, unfloat, zoom, close, tab and workspace
  moves; full app ticks with Lua-only layouts (exist). Add: render-only-when-dirty
  counter, Clay pane hit testing, snapshot `kind`.
- Lua (`src/lua/tests/test_ui_pane*.lua`): render caching and invalidate; ctx
  fields; callback namespace isolation; error row on render failure; factory
  restore.
- Screenshots of a sample pane with the `hollow-screenshots` skill.

---

## 7. Open questions

- Pane-local keymaps: should `on_key` run before or after global keybindings?
  (Proposed: global bindings with explicit mods first, then `on_key`.)
- Should a Lua pane embed a terminal later (a "terminal widget")?
- Theme: terminal theme, widget theme, or a per-pane `theme` override?
  (Proposed: widget theme plus `opts.theme`.)
- Should the sidebar become a reserved Lua pane once panes exist?

---

## 8. Validation environment

- Plain `make test` cannot link here (no X11, Xi, Xcursor, GL, ALSA). Use Nix:
  `nix-shell --run 'make build ARGS="-Ddynamic-linker=$HOLLOW_DYNAMIC_LINKER"'`
  and the same with `make test`. Run `make build` as well as `make test`: Zig's
  lazy analysis otherwise misses renderer-only consumers such as the debug
  overlay.
- `make test-lua` baseline: 785 successes. Unchanged at every checkpoint so far
  (no Lua changes yet).
- The headless renderer benchmark owns a separate `Session`, so it can't
  measure the pane-ownership refactor. GUI benchmarks are still pending.
- Leave the modified submodules (`third_party/*`) alone.
- `make test` failed once in 9 runs during B1, with no assertion output; the
  log just before it showed agent-PTY/`signal=9` warnings. It looks like an
  existing timing-sensitive PTY test, but this isn't confirmed. If it comes
  back, capture the full log to get the test name.

---

## Findings

- **Guard count.** The Option A table grouped several entry points per row
  and missed focus-callback rebinding, native word/line selection, and
  terminal screen/text queries. That gave 55 branches instead of ~19, which
  triggered the switch to B.
- **Leak in `recreateRenderHelpers`.** It used `errdefer` in a void function
  whose allocation catches returned normally, so partial failures leaked
  handles. It is now a fallible transaction, with failure-injection tests.
- **Bootstrap ownership.** Bootstrap installs userdata/callbacks before
  parsing and moves locals into `TerminalPane` only after the PTY is created.
  It moves input handles one at a time so rollback never frees protocol
  buffers that are already owned.
- **Missed HTP guard.** External shell command observations could assign
  terminal automation state to a Lua node. Fixed, with a regression test.
- **Sidebar/overlay row drawer.** Obsolete (see §1). The UI moved to Clay
  (`b487744`, `002392a`) after this plan was written.
