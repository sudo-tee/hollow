# Lua pane plan: panes whose content is a Lua UI tree

Handoff document. Goal: a split or floating pane whose content comes from a Lua
`render(ctx)` function using the declarative `hollow.ui` API, laid out, focused
and closed like a terminal pane.

Two pane-model options are described (§4 Option A, §5 Option B). Both share the
same foundation (§3) and the same Lua API (§6). The recommended path is A first,
with B as a planned follow-up once its triggers are met (§7).

Non-goals (v1): 2D box layout, scrolling viewports, text selection or copy mode
in Lua panes, running Lua panes inside the agent process, or reactive state/hooks.

---

## 0. Ground rules

- This plan **does** change Zig and the renderer, unlike `ui-master-plan.md`.
  New Lua modules are allowed; files under `src/lua/hollow` are embedded
  automatically.
- Terminal panes must behave exactly as before. Any change in terminal
  rendering, input, or lifecycle output is a bug.
- Tests: `make test` (Zig), `make test-lua` (Busted). After every step both are
  green, `stylua --check` is clean on touched Lua, `zig fmt` on touched Zig.
- Don't commit unless the operator says so. Keep each step reviewable alone.
- If the plan is wrong, record it under "Findings", take the smallest safe
  adjustment, continue.

---

## 1. Current state (facts the plan relies on)

**The pane model is terminal-only**
- `SplitNode.pane: ?*Pane` (`src/mux/types.zig:41`). `Pane` (`src/pane.zig:123`)
  is a terminal: PTY, Ghostty handles, encoders, HTP buffers, about 150 fields.
- `*Pane` is used about 182 times. Heaviest: `pane.zig` (42), `mux/mux.zig`
  (22), `mux/tab.zig` (21), `app.zig` (17), `app/htp.zig` (12), `mux/layout.zig`
  (11), `app/selection.zig` (10), `app/input.zig` (9), `app/scroll.zig` (8),
  `render/sokol_runtime.zig` (7), `app/hyperlinks.zig` (7).
- Pane IDs are pointer addresses: `@intFromPtr(pane)` in `app.zig`,
  `app/htp.zig`, `app/session_controller.zig`, `app/pane_lifecycle.zig`,
  `mux/mux.zig`, `render/sokol_runtime.zig` and others. Lookup is
  `App.findPaneById` (`app.zig:1645`).

**Already independent of the content type**
- `mux/layout.zig`, `mux/tab.zig`, `mux/types.zig` and `mux/workspace.zig` only
  touch geometry and floating/restore fields (`x_px`, `y_px`, `width_px`,
  `height_px`, `is_floating`, `floating_*`, `restore_*`) and `deinit`.
- `title`, `cwd`, `program_status` and the bell fields are plain data that tab
  titles and the Activity Center read.

**Hazards for a pane without a PTY**
- With `pty == null`, `hasLiveChild()` returns `false` (`pane.zig:1171`, `:1182`).
  `cleanupDeadPanes` (`app/session_controller.zig:711`) and the reaper in
  `mux/mux.zig:730` then close the pane unless `retain_on_exit` is set, and
  `app/pane_lifecycle.zig:21` emits an exit event.
- The renderer skips panes without render helpers (`sokol_runtime.zig:3689`,
  `paneRenderHelpersReady`) and then calls `renderPane` (`:3695`).
- The per-frame loop in `app.zig` calls `pollPty` (`:2400`) and `refreshTitle`
  (`:2451`). Resize calls `pane.resize` (`:2787`, `:2841`). Theme changes call
  `applyTerminalTheme` (`app.zig:1967`, `app/lua_callbacks.zig:419`).

**Lua UI surfaces today: three separate paths**
- `renderLuaWidgets` (`sokol_runtime.zig:1869` to `:2349`, about 480 lines)
  reads Lua tables directly from the stack every frame:
  - top/bottom bars: `_topbar_state` / `_bottombar_state`, with a dirty flag and
    expiry cache (`pushBarCachedTable`, `:1831`);
  - sidebar: `_sidebar_state.rows` → `parseSegmentArray` (32 segments max) →
    `drawRowSegments`, hardcoded chrome colors (`:1926` to `:1975`), no row
    decorations, no hover;
  - overlays: `_overlay_state` rows with `fill_bg`, `accent_bar`, `divider`,
    scrollbars and hover (`:1981` onward).
- Lua serializers: `widgets/overlay.lua` (`serialize_overlay_row`) and
  `widgets/bars/bar_serialize.lua`.
- The serialized UI is **1D**: a list of rows, each a list of inline segments
  plus row decorations.
- `click_registry` (`builder/internal/click_registry.lua`) is one global
  `id → callback` table shared by every surface.
- `ui/semantics.zig` has `Surface = { topbar, bottombar, overlay }` for
  automation and hit testing.

---

## 2. Target behaviour (v1)

- `hollow.ui.pane.split(opts)` / `hollow.ui.pane.float(opts)` create a Lua pane
  next to the active pane. It takes part in splits, focus movement, zoom,
  floating, close and tab moves like a terminal pane.
- Its content is `opts.render(ctx)`, which returns `ui.column` / rows (same
  children rules as overlays). It renders inside the pane's area with the
  pane's theme.
- It renders again only when invalidated: `pane:invalidate()`, resize, focus
  change, theme change, or hover change. No per-frame Lua call when idle.
- When focused, keys go to `opts.on_key(key, mods, ctx)`. Unhandled keys fall
  through to global keybindings.
- Mouse: clicks dispatch `on_click` for segment IDs; `style.hover` and row
  hover work as in overlays.
- Snapshots, `hollow-cli` listing and the Activity Center show
  `kind = "lua"`. Terminal-only CLI verbs (send-text and similar) return
  `error.NotATerminal` for Lua panes.

---

## 3. Shared foundation (needed by both options)

### 3.1 One surface format

The overlay row format becomes the canonical "surface rows" format, unchanged:

```
rows[i] = {
  segments = { { text, fg, bg, bold, ..., id, hover... } | { spacer = true } },
  id, hoverable,
  fill_bg, fill_radius, accent_bar, divider,
  scrollbar_track, scrollbar_thumb, scrollbar_id, scrollbar_thumb_ratio, ...
}
```

- Lua: move `serialize_overlay_row` from `widgets/overlay.lua` into
  `shared.lua` as `shared.serialize_surface_row(row, palette, hovered_id, ns)`.
  `ns` is an optional click-ID namespace (§3.3). The overlay keeps calling it
  and its output must stay byte-identical.
- Zig: extract the overlay row loop from `renderLuaWidgets` into
  `drawSurfaceRows(renderer, rect, rows_idx, hover_id, hit_cache)`. It takes a
  pixel rect and draws rows clipped to it.

### 3.2 Migrate the sidebar to it (proves the drawer)

- The sidebar serializes through `serialize_surface_row` and draws with
  `drawSurfaceRows`. Keep its current chrome colors as defaults.
- Output must be visually identical for rows that use only segments. Sidebar
  rows gain hover and decorations (an intended change, listed in Findings).
- The 32-segment limit (`seg_buf_32`) is either lifted to the overlay limit or
  documented.

### 3.3 Hit testing and click namespaces

- Make `g_overlay_hit_cache` per surface: `{ surface, owner_id, rect, entries }`.
  Mouse hit testing looks up the topmost surface under the cursor first.
- Add `.pane` to `ui/semantics.zig` `Surface`, with an owner pane ID.
- Click IDs: Lua panes register with the prefix `"pane:<id>:"`, so two
  instances of the same pane module don't overwrite each other's callbacks.
  When a pane closes, its prefix is removed from `click_registry`.

### 3.4 Render cache and dirty flag

- Lua side: each pane instance keeps `{ dirty, rows_cache, cols, rows, focused,
  hovered_id }`. `hollow.ui._pane_rows(id)` returns the cached rows and runs
  `render` only when dirty.
- Zig side: the pane holds a `dirty` flag that Lua sets through
  `invalidate()`, or that Zig sets on resize, focus, theme, or hover change.
  The renderer calls into Lua only when it's set; otherwise it reuses the
  `PaneCacheEntry` texture (`sokol_runtime.zig:448`), which is already keyed
  per pane.

**Done when (§3):** overlay and sidebar draw through `drawSurfaceRows`; all
overlay snapshots and Lua tests unchanged; sidebar visually unchanged in a
screenshot check (`hollow-screenshots` skill); no new per-frame cost measured
by `make bench` on the overlay benchmark.

---

## 4. Option A: add a kind to the existing `Pane`

Smallest change. `Pane` keeps all its terminal fields; a Lua pane leaves them
null or unused.

### 4.1 Model

```zig
// pane.zig
pub const Kind = enum { terminal, lua };

kind: Kind = .terminal,
lua_surface: ?*LuaSurface = null,

pub fn isTerminal(self: *const Pane) bool { return self.kind == .terminal; }
```

```zig
// new: src/ui/lua_surface.zig
pub const LuaSurface = struct {
    ref: c_int,          // Lua registry ref to the pane instance table
    dirty: bool = true,
    hovered_id: ?[]u8 = null,
    // hit cache entries for this pane (§3.3)
};
```

Every terminal-only call site checks `pane.isTerminal()` (or `lua_surface`).
**All guards go through `isTerminal()`** so a grep finds every site. This list
is also the migration list for Option B.

### 4.2 Guard list

| # | Site | Change |
| --- | --- | --- |
| 1 | `mux/mux.zig:730` reaper | skip non-terminal panes |
| 2 | `app/pane_lifecycle.zig:21` exit event | skip non-terminal panes |
| 3 | `app/session_controller.zig:711` `cleanupDeadPanes` | skip non-terminal panes |
| 4 | `app.zig:2400` `pollPty` loop | skip non-terminal panes |
| 5 | `app.zig:2451`, `:1968` `refreshTitle` | skip; Lua sets `title` directly |
| 6 | `app.zig:1967`, `lua_callbacks.zig:419` `applyTerminalTheme` | Lua pane: mark dirty |
| 7 | `app.zig:2787`, `:2841` `resize` | Lua pane: store cols/rows, mark dirty |
| 8 | `app.zig:1690`, `:2780`, `:2834` `recreateRenderHelpers` | skip |
| 9 | `sokol_runtime.zig:3689` to `:3695` render | Lua branch → `drawSurfaceRows` into pane rect |
| 10 | `sokol_runtime.zig` kitty textures (`:3259`), sync output (`:3273`, `:3312`), viewport scroll (`:3289`) | skip non-terminal panes |
| 11 | `app/input.zig` keys (`key_encoder`, `sendUserText`) | Lua pane: dispatch `on_key` |
| 12 | `app/input.zig` mouse (`mouse_encoder`, tracking) | Lua pane: surface hit test (§3.3) |
| 13 | `app/selection.zig`, `copy_mode.zig`, `quick_select.zig`, `hyperlinks.zig` | no-op for Lua panes |
| 14 | `app/scroll.zig`, scrollbar drag/hover globals (`sokol_runtime.zig:317`, `:320`) | no-op for Lua panes |
| 15 | `app/htp.zig`, `app/background_jobs.zig` | ignore Lua panes |
| 16 | `session_controller.zig` send-text / `queueStartupInput` / paste | `error.NotATerminal` |
| 17 | `lua_bridge.zig` `send_text_to_pane` (`:6938`) | return `false` for Lua panes |
| 18 | `app.zig:785` snapshots (`snapshotPane`) | add `kind`, Lua pane `module` |
| 19 | `Pane.deinit` (`pane.zig:294`) | Lua pane: `on_unmount`, unref, clear click prefix |

### 4.3 Creation

- `Mux.createLuaPane(allocator, ref) !*Pane`: `Pane.init`, set `kind = .lua`,
  `lua_surface`, title from opts. No `bootstrap`, no PTY, no domain.
- `Mux.splitActivePaneWith(new_pane, direction, ratio, floating)`: the
  insertion half of `splitActivePane` (`mux/mux.zig:512`), so terminal and Lua
  panes share the split/float logic. `splitActivePane` keeps its signature and
  calls it.
- `notifyCreated` fires as for terminals, so Lua `pane:created` events work.

### 4.4 Cost / risk

- About 19 guard sites plus one render branch and the foundation.
- `Pane` stays large; Lua panes carry unused terminal fields (memory is not a
  concern at these counts).
- Risk: a missed guard reaches a null terminal handle. Mitigation: debug
  asserts in terminal-only `Pane` methods (`assert(self.isTerminal())`) and a
  Zig test that runs one frame of the app loop with a Lua pane in every layout
  (split, float, zoom, tab move).

---

## 5. Option B: split `Pane` into a generic node plus content

Cleaner long-term model. The node owns identity, geometry and shared status;
content is a tagged union.

### 5.1 Model

```zig
// pane.zig (or mux/pane_node.zig)
pub const Pane = struct {               // generic node, keeps the name
    id: usize,                          // explicit, no longer @intFromPtr
    x_px: u32, y_px: u32, width_px: u32, height_px: u32,
    cols: u16, rows: u16,
    is_floating: bool, floating_x: f32, floating_y: f32,
    floating_width: f32, floating_height: f32,
    restore_anchor_id: usize, restore_ratio: f32,
    restore_split_horizontal: bool, restore_place_first: bool,
    title: []u8, cwd: []u8, program_status: ProgramStatus.State,
    bell_*: ...,
    content: Content,

    pub const Content = union(enum) {
        terminal: *TerminalPane,
        lua: *LuaSurface,
    };

    pub fn terminal(self: *Pane) ?*TerminalPane { ... }
};

// term/terminal_pane.zig: today's Pane minus the fields above
pub const TerminalPane = struct { pty, terminal, render_state, encoders, htp_*, ... };
```

Terminal-only code takes `*TerminalPane`. Code that handles any pane switches on
`content`. The compiler finds every site that needs a decision; nothing relies
on a remembered guard.

### 5.2 Migration steps (each step compiles and passes tests)

1. **Explicit IDs.** Add `Pane.id` (monotonic counter in `Mux`). Replace every
   `@intFromPtr(pane)` used as an ID and `restore_anchor_id`. `findPaneById`
   compares `id`. This is worth doing first even under Option A: after the
   split, the node pointer and the terminal pointer differ, and mixing them up
   would be a silent bug.
2. **Introduce `TerminalPane`** as a new struct holding the terminal fields and
   methods (`bootstrap`, `pollPty`, `resize`, encoders, HTP, `scrollbar`, ...).
   `Pane` temporarily embeds it: `term: TerminalPane`.
3. **Move consumers file by file** to `pane.term` / `*TerminalPane`:
   `app/htp.zig`, `selection.zig`, `copy_mode.zig`, `quick_select.zig`,
   `hyperlinks.zig`, `scroll.zig`, `input.zig`, `session_controller.zig`,
   `background_jobs.zig`, `pane_lifecycle.zig`, then `app.zig` and
   `render/sokol_runtime.zig`. `mux/layout.zig` and `mux/tab.zig` should need
   no changes.
4. **Make the content a union**: replace `term: TerminalPane` with
   `content: Content`. Each `pane.term` becomes `pane.terminal() orelse ...`
   or a `switch`. The compiler lists every remaining site.
5. **Add `.lua`** with `LuaSurface` (§3.4) and the Lua-specific branches from
   the Option A guard list (rows 6, 7, 9, 11, 12, 18, 19).
6. **Renderer cache and globals**: `PaneCacheEntry.pane`, `g_selection_pointer_pane`,
   `g_scrollbar_drag_pane`, `g_scrollbar_hover_pane` stay `*Pane` (node);
   terminal-only globals switch to `*TerminalPane` where they dereference
   terminal fields.

### 5.3 Cost / risk

- Touches most of the 182 `*Pane` references, about 15 files, mostly
  mechanical. `app.zig`, `sokol_runtime.zig` and `htp.zig` carry most of the
  churn.
- Large diffs in hot paths (render loop, PTY poll). Needs benchmark runs
  (`make bench`) before and after steps 3 and 4.
- Conflicts with any in-flight terminal work; schedule it on a quiet branch.
- Upside: a third content kind (image viewer, web view, log tail, agent
  transcript) costs one union arm, and terminal code no longer has to think
  about non-terminal panes.

---

## 6. Lua API (same for both options)

```lua
local pane = hollow.ui.pane.split({
  direction = "vertical",      -- or "horizontal"
  ratio = 0.4,
  title = "Tasks",
  module = "tasks",            -- optional; required for restore (§8)
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

- New module `hollow.ui.widgets.pane` (embedded automatically).
- `render` output goes through the same children rules as overlays
  (`collect_rows`) and `shared.serialize_surface_row` with namespace
  `"pane:<id>:"`.
- Errors in `render` show an error row in the pane (like bars) instead of
  crashing; unknown-token errors still propagate in tests.
- Types in `types/hollow.lua` (`HollowUiPaneOpts`, `HollowUiPaneCtx`,
  `HollowUiPane`), docs in `docs/reference/lua/ui.md` and `docs/custom-ui.md`.

---

## 7. Choosing between A and B

| | Option A | Option B |
| --- | --- | --- |
| Size | ~19 guard sites + render branch | most of 182 `*Pane` refs, ~15 files |
| Time to first Lua pane | short | long (steps 1 to 4 before any Lua pane) |
| Safety | relies on guards + debug asserts | compiler finds every site |
| Hot-path churn | low | high; needs benchmarks |
| Third pane kind | another round of guards | one union arm |
| Reversibility | easy to remove | hard to back out |

**Recommendation:** do §3, then Option A, ship the Lua pane, then plan Option B.
Do Option B step 1 (explicit IDs) early either way, since it's useful on its
own and removes the riskiest part of B.

Switch to Option B when any of these is true:
- a third content kind is planned;
- the `isTerminal()` guard count goes past about 30, or terminal code paths
  need Lua-pane awareness beyond a single early return;
- a missed-guard bug ships (a crash or null handle reached from a Lua pane).

Option A prepares for B by design: every guard goes through `isTerminal()`, and
all Lua-pane state lives in `LuaSurface`, which moves unchanged into
`Content.lua`.

---

## 8. Persistence and process model

- Lua panes live in the GUI process only. The agent (`src/agent`) never sees
  them. On reattach, terminal panes come back from the agent; Lua panes must be
  rebuilt by the GUI.
- Functions can't be serialized, so restore goes through named factories:
  snapshots store `{ kind = "lua", module = "tasks", args = {...} }` and the
  layout loader calls `hollow.ui.pane.register("tasks", factory)`'s factory. A
  Lua pane without `module` is not restored (documented).
- Workspace layouts (`ui/workspace/source.lua` and the host layout loader) gain
  a `lua` leaf: `{ lua = "tasks", args = {...} }`.
- `hollow-cli`: listing shows `kind`; a `split --lua <module>` verb is
  optional.

---

## 9. Steps

| Step | What | Depends on |
| --- | --- | --- |
| 1 | Explicit `Pane.id` (Option B step 1) | none |
| 2 | Surface format + `drawSurfaceRows`; overlays migrated (§3.1) | none |
| 3 | Sidebar migrated; per-surface hit cache; click namespaces (§3.2, §3.3) | 2 |
| 4 | Pane model: Option A `kind` + guards 1 to 8, 10, 13 to 17 (§4.2) | 1 |
| 5 | Render branch + dirty cache (§3.4, guard 9) | 3, 4 |
| 6 | Lua API: `split`/`float`/`invalidate`/`close`, `on_mount`/`on_unmount` (§6) | 5 |
| 7 | Keys and focus (guard 11), `on_focus` | 6 |
| 8 | Mouse: click and hover (guard 12) | 3, 7 |
| 9 | Snapshots, factories, workspace `lua` leaf, CLI `kind` (§8, guard 18) | 6 |
| 10 | Types and docs | 6 to 9 |
| 11 | Option B steps 2 to 6, when §7 triggers are met | 10 |
| later | 2D boxes in the surface format; scroll viewports for Lua panes | 5 |

**Done when (v1, steps 1 to 10):**
- A Lua pane can be split, floated, zoomed, focused, moved to another tab and
  closed; it is never reaped automatically.
- It renders only when dirty (verified by a counter in tests).
- Keys reach `on_key` when focused; global keybindings still work.
- Clicks and hover work with two instances of the same module open.
- Snapshot shows `kind = "lua"`; a factory-backed pane comes back after a
  workspace reload.
- Terminal behaviour unchanged: full Zig and Lua suites green, benchmarks within
  noise, overlay snapshots byte-identical.

---

## 10. Tests

- Zig (`mux/tests.zig`, new `lua_pane_test.zig`): reaper keeps Lua panes; split,
  float, unfloat, close, tab move with mixed panes; resize marks dirty; one
  full app frame with a Lua pane and no terminal handle reached (debug asserts
  on).
- Renderer: `drawSurfaceRows` output through the debug/null backend matches the
  old overlay and sidebar output.
- Lua (`src/lua/tests/test_ui_pane*.lua`): render caching and invalidate; ctx
  fields; click namespace isolation; error row on render failure; factory
  restore.
- Screenshots with the `hollow-screenshots` skill for the sidebar migration and
  a sample pane.

---

## 11. Open questions

- Pane-local keymaps: should `on_key` run before or after global keybindings?
  (Proposed: global bindings with explicit mods first, then `on_key`.)
- Should a Lua pane be able to embed a terminal later (a "terminal widget")?
  This would favour Option B.
- Theme: should Lua panes use the terminal theme, the widget theme, or a
  per-pane `theme` override like overlays? (Proposed: widget theme plus
  `opts.theme`.)
- Sidebar: once panes exist, should the sidebar become a reserved Lua pane?

---

## Findings

(Record deviations and facts discovered during implementation here.)
