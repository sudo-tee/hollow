# Clay migration plan: remove the legacy UI backend and delegate more to Clay

Handoff document. Goal: one UI layout path (Clay) for overlays, bars and the
sidebar. That means deleting the legacy overlay renderer, the `backend` /
`layout` switch, and the hand-rolled layout, hit-test and scroll code that Clay
already provides.

Non-goals: moving the terminal grid, panes, split seams, bell flash or the pane
scrollbar into Clay. Keyboard focus, text editing and the caret stay in Lua.

---

## 0. Ground rules

- Tests: `make test` (Zig) and `make test-lua` (Busted) must pass after every
  phase. Run `stylua --check` on touched Lua and `zig fmt` on touched Zig.
- Each phase can be reviewed on its own. Don't commit unless the operator says
  so.
- Visual parity matters. Capture before/after screenshots of each migrated
  widget (see the `hollow-screenshots` skill). Accessibility labels must stay
  identical. `widgets/workspace.lua:72` already relies on this.
- Line numbers below were taken from the current tree and will drift. Re-grep
  before editing.
- If the plan turns out to be wrong, record it under "Findings", take the
  smallest safe adjustment and continue.

---

## 1. Current state

**Backend switch**

- `src/lua/hollow/ui/layout.lua:11-20`: `configure({ backend })` and
  `resolve_backend(override, default)`. The final fallback is `"legacy"`
  (line 19).

**Widget defaults**

| Widget                      | Default         | Legacy-only code                                                                                                        |
| --------------------------- | --------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `widgets/select.lua`        | legacy (222)    | `render` ~355-399, `render_entry_rows` ~163-182, `render_empty_row` ~152-154                                            |
| `widgets/input.lua`         | legacy (39)     | `render` ~47-54 (`ui.dialog`)                                                                                           |
| `widgets/confirm.lua`       | legacy (84)     | `render` ~95-104 (`ui.dialog`)                                                                                          |
| `widgets/palette.lua`       | clay (297)      | `render_content` ~356-417                                                                                               |
| `widgets/activity.lua`      | clay (177)      | `render` ~939-956, `render_rows`/`render_search`/`render_empty`/`render_footer` ~631-685, budget branches ~184 and ~375 |
| `widgets/mux_navigator.lua` | clay (188)      | `render_content` ~350-384                                                                                               |
| `widgets/workspace.lua`     | clay (401)      | `default_format_item` ~132-173, label branch ~465-466                                                                   |
| `widgets/notify.lua`        | **legacy only** | whole render (`ui.overlay.new` ~57-87, uses `overlay_stack`)                                                            |

**Not on Clay today**

- Top bar, bottom bar and tabs: `widgets/bars/*` → segment payload →
  `renderBarWidgetSurface` (`sokol_runtime.zig:2189`).
- Sidebar: segment rows → `sokol_runtime.zig` ~2480-2544.
- Notify toasts: see the table above.
- Debug overlay: `drawDebugOverlay` (`sokol_runtime.zig:5028`).

**Legacy pieces the Clay path reuses (keep until bars move)**

- `ui.row` / `ui.column` / `ui.divider` (`primitives.lua` ~144-193), consumed
  by `layout_select.lua` `from_row` (~271-316).
- `shared.lua`: `serialize_row_paint` (~1152-1198), `flatten_span_nodes`,
  `nodes_plain_text`, `highlight_inline_nodes`, `normalize_overlay_chrome`,
  `normalize_overlay_align`, `normalize_surface_style`, `style_to_segment`,
  `resolve_row_style`, `apply_hover`, `normalize_widget_rows`,
  `render_widget_rows`.
- `selectable_list.row()`, `core.lua` `trim_row_for_width`.
- `lua_bridge.zig` `parseSegmentArray` (~5333-5424) and `ui/bar.zig`.

**Clay 0.14 features**

- Used: FIT/GROW/FIXED sizing, padding, childGap, childAlignment, bg, uniform
  corner radius, border-all, clip and scroll, CUSTOM (progress bar), text wrap,
  `Clay_Hovered`, element data, the debug inspector.
- Unused: PERCENT and min/max sizing, textAlignment, floating with zIndex and
  attach points, `Clay_PointerOver`/`Clay_GetPointerOverIds`, per-side borders,
  betweenChildren borders, per-corner radius, `Clay_SetQueryScrollOffsetFunction`.

**Clay can't do these, so they stay custom**

- Text ellipsis/truncation.
- Scroll-to-element (the reveal pass in `clay_bridge.c`).
- A scrollbar widget.
- Rendering. Clay only emits commands; the rect and rounded-rect draw code stays.

---

## 2. Phase 1: delete dead code (zero risk)

The following in `src/render/sokol_runtime.zig` are defined but never called.
Re-confirm with grep, then delete:

- `computeCustomTabLayouts` (~2994-3038) and its struct (~941)
- `drawStatusSegments` (~3302)
- `drawSingleSegment` (~3321)
- `drawBarSegmentText` (~2026-2041)
- `updateTopBarHover` (~3133-3146). This is the runtime copy, not
  `App.updateTopBarHover` in `app.zig:2238`.

Also delete `shared.lua` `bar_value_to_segment` (~823), which has no callers.

Estimate: −150 to −250 LOC. Done when `make test` passes and the code builds
on all targets.

---

## 3. Phase 2: port the remaining legacy-only widgets to Clay

1. **Notify.** Add a Clay render for toasts, using a column of floating
   children with childGap instead of `overlay_stack` offsets. Keep the same
   `context`/stacking order, timeouts and click-to-dismiss.
2. **Select.** The Clay path already exists. Flip the default at
   `select.lua:222` to `"clay"`.
3. **Input and confirm.** The Clay paths already exist. Flip the defaults at
   `input.lua:39` and `confirm.lua:84`.
4. Update `types/hollow.lua` doc comments that say "legacy is default"
   (~1054, ~1090, ~1185).

Done when every overlay renders through `drawClaySurface` with no
`layout = "legacy"` overrides set. Run the test suite with
`ui.layout.configure({ backend = "clay" })` forced globally.

---

## 4. Phase 3: strip the legacy backend

**Lua (~700-900 LOC removed)**

- Remove the legacy branches listed in §1 from every widget.
- Delete `builder/components/dialog.lua`, `builder/components/button.lua`,
  `builder/internal/click_registry.lua` and `widgets/format.lua`. Remove the
  `ui.dialog` registration in `composition.lua:11`.
- `widgets/overlay.lua`: remove `serialize_overlay_row` (~18-40), the legacy
  half of `serialize_overlay_widget` (~57-73) and the click_registry dispatch
  (~103-106).
- `builder/modal.lua`: remove the `spec.render` overlay wiring (~71-76) and the
  click/button resets.
- `shared.lua`: remove `overlay_surface_style` (~1140). Check `node_state`
  callers and remove it if only the legacy branches used it.
- `layout.lua`: remove `configure({ backend })` and `resolve_backend`. Callers
  render Clay unconditionally.

**Zig (~400 LOC removed)**

- `sokol_runtime.zig` `renderLuaWidgets`: delete the legacy overlay branch
  (~2612-2922). That covers chrome parse, 9-way align, row measure, stack
  offsets, panel draw, auto `overlay:{d}:row:{d}` IDs, the hover fill and the
  row scrollbar.
- Delete `overlayRowSegmentsIndex` (~1571), `overlaySegmentsLabel` (~1611),
  `g_overlay_hovered_id` (584) and its buffer, and `OVERLAY_HOVER_BG` (~407).
- Delete `src/render/overlay_stack.zig` and the test import in `main.zig:629`.

**Types, docs, scripts and tests**

- `types/hollow.lua`: remove the `layout?` fields (~1054, 1090, 1185, 2075,
  2134, 2204), `HollowUiLayout.configure`/`resolve_backend` (~2302) and the
  overlay row payload types (`HollowUiOverlaySerializedRow` ~937,
  `HollowUiOverlaySerializedWidget` ~941).
- Docs: `docs/clay-layout.md` (22-26, 75-88, 151, 324), `docs/renderer-bench.md`
  backend comparisons, `docs/app-profiling.md` (18, 76),
  `docs/reference/lua/ui.md` (330-353).
- Scripts that take a backend argument: `scripts/app-profile-fixture.lua`,
  `bench-pickers.lua`, `bench-picker-memory.lua`,
  `diagnose-picker-lifecycle.lua`, `run-app-profile.ps1`.
- Examples: drop the explicit `layout = "clay"` from `examples/clay-*.lua` and
  consider renaming the files.
- Tests:
  - Delete the legacy-only suites and cases: `test_ui_workspace.lua`,
    `test_ui_palette.lua`, `test_ui_activity_composition.lua`,
    `test_activity.lua`, `test_ui_mux_navigator.lua`,
    `test_ui_widget_styles.lua`, `test_ui_widget_authoring.lua`,
    `test_ui_lifecycle_retention.lua`, `test_ui_builder_styles.lua` (dialog).
    First port any behaviour assertions in them that aren't layout-specific.
  - Rewrite the backend comparison tests as Clay-only:
    `test_ui_program_status.lua`, `test_ui_*_layout.lua`,
    `test_ui_production_layout.lua`.

Done when grep for `"legacy"`, `resolve_backend` and `layout_render` in
`src/`, `types/`, `docs/` and `scripts/` returns only the workspace source
compat code (`ui/workspace/compat.lua`), which is unrelated.

---

## 5. Phase 4: delegate hit-testing, hover and scrolling to Clay

1. **Hit-testing.** Replace `hollow_clay_hit` and the visible-bounds clip stack
   in `record_bounds` (`clay_bridge.c`) with `Clay_SetPointerState` +
   `Clay_GetPointerOverIds`, which already respect clipping and floating
   capture.
2. **Hover.** Use `Clay_Hovered` / `hover_bg` for the look. Today hover goes
   Zig → `overlay:hover` → Lua `state.hovered_id` → invalidate → full
   re-snapshot (`modal.lua` ~100-125, `layout_select.lua` ~102). Keep the Lua
   event only for semantic hover such as previews.
3. **Overlay hit and scroll caches.** Replace `cacheOverlayHitRegion*`,
   `hitTestOverlay*`, `updateOverlayHover` and the scrollbar caches
   (`sokol_runtime.zig` ~1622-1820, ~3148-3267) with pointer-over IDs plus
   floating zIndex. The cache rebuild in `drawClaySurface` (282-363) shrinks to
   the scrollbar draw only.
4. **Wheel scrolling.** `claySurfaceEvent` returns false for `owner_index > 0`,
   so the wheel goes to Lua as arrow keys. Feed it into
   `Clay_UpdateScrollContainers` instead.
5. **Node cap.** Raise `HOLLOW_CLAY_MAX_NODES` (512, `clay_bridge.h:5`) so
   short lists can use plain Clay clip scrolling. Keep virtual windowing
   (`scroll_view.lua`, `layout_select.lua` ~170-215) only for long lists.
   Measure memory and frame time with `bench.sh` / `docs/renderer-bench.md`.

Estimate: −300 to −400 LOC. Risk: medium, because mouse behaviour changes.
Test by hand: hover, click, wheel, scrollbar drag, nested scroll, overlays
stacked over each other.

---

## 6. Phase 5: move bars, sidebar and the debug overlay to Clay

1. **Bars.** Replace `renderBarWidgetSurface` and its helpers
   (`sokol_runtime.zig` ~2189-2359, ~1395-1552, ~2026-2165) with a Clay row.
   Use a GROW spacer for left/right groups, FIXED or GROW-with-max for tabs,
   and childAlignment center. Ellipsis stays manual (see §7.1).
2. **Bar hit caches.** Remove `sokol_runtime.zig` ~3040-3146 in favour of
   Phase 4 pointer-over IDs.
3. **Row paint.** Once bars are on Clay, `drawRowPaint` / `drawRowSegments`
   (~1824-1900) and `bar.rowPadding` can probably go.
4. **Sidebar.** Move `sokol_runtime.zig` ~2480-2544 to a Clay column with
   clipping and scrolling.
5. **Debug overlay.** Rebuild `drawDebugOverlay` (5028) as a Clay floating
   column.
6. **Inspector.** Drop the bar mirror from `ui/clay_grid_debug.zig` and from
   the bridge's `debug_layout`. Keep the pane mirror.

After this, revisit the row/segment pieces §1 marked "keep". `bar_serialize.lua`
(528 LOC), `style_to_segment`, `parseSegmentArray` and others may shrink a lot.

Risk: high, because bars are the most-used UI. Do it behind a temporary
internal toggle, compare screenshots, then delete the toggle in the same
phase.

---

## 7. Phase 6: cleanups and bug fixes

1. **One truncation implementation.** Ellipsis exists both in Lua
   (`bar_serialize.lua` ~135-248) and in Zig (`fitTabLabel` /
   `drawFittedTabSegments`). Keep one.
2. **Column layout in Lua.** `workspace.lua` ~73-245, `activity.lua`
   `measure_columns` ~535-625 and `format.lua` pad with spaces by character
   count. Replace with FIXED-width children and textAlignment.
3. **Divider and gutter.** In `layout_select.lua`, replace the `full_bleed_x`
   divider and the accent gutter with betweenChildren or per-side borders.
4. **Modal sizing.** In `modal.lua` ~139-170, replace the manual padding math
   and the `preferred_height` feedback with FIT height plus min/max.
5. **Bug: byte-length trim.** `widgets/core.lua:64-90` `trim_row_for_width`
   uses `#text` (bytes). Use UTF-8 or display width.
6. **Bug: wide characters.** Display width is computed as "1 codepoint = 1
   cell" in four places: the bridge `measure()`, Zig `countCodepoints` /
   `takeCodepoints` / `fitTabLabel` (~1484-1552), `FtRenderer.drawLabelFace`
   (`ft_renderer.zig:703`) and Lua `util.lua` ~364-415. Add one wcwidth-aware
   measure, used by Clay `measure()` and reused by the Zig and Lua truncation.

---

## 8. Estimated impact

| Phase                  | Zig/C        | Lua          |
| ---------------------- | ------------ | ------------ |
| 1 Dead code            | −150 to −250 | −10          |
| 2 Port widgets         | ~0           | +50 (notify) |
| 3 Strip legacy         | −400         | −700 to −900 |
| 4 Hit, hover, scroll   | −300 to −400 | −60          |
| 5 Bars, sidebar, debug | −700 to −900 | −200+        |
| 6 Cleanups             | −100         | −150         |

Tests and docs shrink on top of this.

---

## Status (2026-10-30)

| Item                       | State                                                                                                                      |
| -------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| Phase 1 dead code          | Done                                                                                                                       |
| Phase 2 port widgets       | Done (notify on Clay; select/input/confirm Clay-only)                                                                      |
| Phase 3 strip legacy       | Done. Plain `ui.overlay.new` chrome restored on Clay (see Findings)                                                        |
| 4.1 hit via pointer-over   | Done (`hollow_clay_hit` uses `Clay_GetPointerOverIds`)                                                                     |
| 4.2 hover                  | Done (Lua re-snapshot only with `semantic_hover`)                                                                          |
| 4.3 overlay caches         | Done: input queries retained overlay surfaces; hit, scroll and scrollbar caches removed (see Findings)                     |
| 4.4 wheel into Clay        | Closed, not done: lists stay virtual; text views would need caps and more Zig code (see Findings)                          |
| 4.5 node cap               | Kept at 512 (see Findings)                                                                                                 |
| Phase 5 bars/sidebar/debug | Done as Clay geometry (`ui/native_surface.zig`); painting stays native                                                     |
| 6.1 one truncation         | Done: `fitTabSegments` (Zig); Lua `clamp_tab_segment_width` removed                                                        |
| 6.2 columns                | Workspace already Clay FIXED columns; activity keeps padding, now display-width                                            |
| 6.3 divider/gutter         | Dividers are Clay `betweenChildren` borders (`layout_select.sections`); `full_bleed_x` removed; gutter kept (see Findings) |
| 6.4 modal sizing           | Kept `preferred_height` (see Findings)                                                                                     |
| 6.5 / 6.6                  | Done (`text_width.zig`/`.c`, Lua `util.display_width`)                                                                     |

Manual visual and mouse verification done by the operator (2026-10-30). Native
`make test` (Nix invocation below) and `make test-lua` pass.

## Findings

- Execution environment: the initial `make test` cannot link the GUI test
  executable because native X11, Xi, Xcursor, OpenGL and ALSA development
  libraries are missing. Nix-provided libraries also require their matching
  dynamic linker rather than the host glibc loader. Isolated Clay tests remain
  available without GUI libraries.
- Visual verification is blocked: `python3 scripts/hollow-cli --transport socket
get mux-tree --pretty` times out, and no `hollow-wsl-bypass` process is present
  to recover a live command address. Before/after screenshots and interactive
  mouse checks must not be claimed as verified.
- Phase 4 prerequisite found during execution: the original `clay_surface.zig`
  reused one native Clay context for every overlay. Pointer-over IDs describe only its latest layout,
  whereas the renderer's hit/scroll caches preserve geometry across the entire
  overlay stack and also feed accessibility. Removing those caches requires
  retaining each overlay's native layout (or declaring the whole stack in one
  Clay layout) first; switching the bridge's local hit query alone is not a
  complete replacement.
- Unicode finding: pinned Ghostty exposes `ghostty_unicode_codepoint_width`
  and `ghostty_unicode_grapheme_width` through `ghostty/vt/unicode.h`. A shared
  display-width implementation should use the grapheme API (including emoji
  variation selectors and ZWJ sequences), not introduce independent wcwidth
  tables or assume summing scalar widths handles clusters. UTF-8-safe slicing
  is a separate fix and does not by itself provide display-cell measurement.
- During migration, `zig build bench-clay` (Debug, 2,000 iterations, 166
  nodes) reports median 403.4 µs idle, 754.2 µs reveal and 458.9 µs resize;
  Clay minimum arena is 1,496,768 bytes. These are headless development
  measurements, not before/after GUI performance or a justification to raise
  the node cap.
- Native test environment workaround (no repository build changes needed):
  `nix-shell -p libx11 libxi libxcursor libGL alsa-lib --run 'make test
ARGS="-Ddynamic-linker=$(dirname "$(cc -print-file-name=libc.so.6)")/ld-linux-x86-64.so.2"'`.
  Setting `LD_LIBRARY_PATH` globally instead is unsafe here because it mixes
  host/Nix libc loaders in subprocesses.
- Validation checkpoint: the full native test graph passes with that Nix
  invocation, including bridge and snapshot parser contracts. The Windows GNU
  cross-build and `make test-launch` also pass. These checkpoints do not
  substitute for rerunning validation after the remaining integration edits.
- Phase 3's literal `legacy` grep criterion is too broad: unrelated CLI
  compatibility, host resolver migrations and theme aliases legitimately use
  that word outside workspace compatibility. Check removed UI backend symbols
  and UI backend documentation specifically; do not delete unrelated migration
  support just to satisfy a repository-wide word search.
- Phase 3 regression (fixed): removing `overlay_surface_style` dropped
  `style`/`chrome` on plain `ui.overlay.new` widgets. `overlay.push` now wraps
  the render result in a `:dialog` Clay column with the merged chrome
  (explicit chrome replaces whole boxes) plus the former native base insets
  (half a cell horizontally, one cell top, half a cell bottom). The root of a
  plain overlay's tree is therefore the `:dialog` chrome node.
- 4.3: done without pointer-over queries. Each overlay already keeps its
  own Clay context and the bridge records clipped visible bounds per node
  after every layout, so input reads those directly. `drawClaySurface`
  registers each painted surface (bottom to top); click, hover, wheel and
  scrollbar routing walk them from the top using `Surface.hitTest` and
  `visibleBounds`, and scrollbar geometry is derived from the node on demand.
  This removes the hit, scroll and scrollbar caches, their ID copies (about
  530 KB of static buffers) and their silent caps (128 clickables, 32 scroll
  regions, 16 scrollbars). Routing rules are unchanged: within an overlay a
  clickable row beats a viewport or the panel; a higher overlay's panel beats
  lower rows for the wheel; a higher overlay's clickable node hides a lower
  scrollbar. Clicks on a panel's empty area still fall through to whatever is
  below, as before. Accessibility nodes are emitted inline with the same
  labels and roles, now without the 128-node cap. `Clay_SetPointerState`
  isn't used, so input has no hover or inspector side effects.
- Sidebar segments with an `id` only ever produced accessibility nodes: their
  hit regions were written to the overlay cache and wiped before the overlays
  drew, and nothing handled sidebar clicks. Fixed: the sidebar paint keeps its
  own small hit list (ids copied, clipped to the panel) and emits
  `sidebar:hover`/`sidebar:leave`/`sidebar:click`, routed like the bars to the
  span's `on_click`/`on_mouse_enter`/`on_mouse_leave` and `hover` style
  (handler-only spans get `sidebar:auto:N` ids). Overlays' clickable nodes
  still win. Presses on the panel no longer reach the terminal beneath a
  non-reserving sidebar. Accessibility labels are unchanged; the nodes now use
  a new `sidebar` surface, so `hollow-cli ui click` routes to the sidebar.
- 4.4: every overlay wheel event is semantic. Virtualized lists turn it into
  selection movement, and the REPL handles it itself. The bridge's reveal pass
  re-pins scroll to the selection on every layout, so wheel deltas fed into
  `Clay_UpdateScrollContainers` would be undone, or would scroll past the
  24-row virtual window. Do this only for non-virtualized, reveal-free
  containers once one exists.
- Virtualization stays for lists (select, activity, mux navigator, palette).
  Clay lays out every frame (`drawClaySurface` → `surface.layout`, plus the
  reveal pass), not only when the tree changes, so per-frame cost grows with
  node count. A workspace row costs about 13 nodes (328 nodes for 24 rows),
  so the 512-node cap holds about 38 rows. `ui.select` takes any number of
  items, and a 1,000-item picker would be about 13,000 nodes (about 4 MB of
  node structs plus Clay's arena). A hybrid (full tree when small, virtual
  when large) would keep two code paths and two wheel behaviours for a small
  gain. Lists keep wheel-moves-selection.
- 4.4 for text views (activity details, REPL output): Clay scrolling needs the
  whole text in the tree, and that hits other fixed Clay capacities. Each
  context's measure cache holds 4,096 words (`elements * 2`) across all text,
  and wrapped lines are capped at `maxElementCount` (2,048). Going over either
  fails the layout. Activity messages and REPL output have no length limit.
  Native scrolling would therefore need a text cap ("truncated, copy for full
  text") plus new Zig plumbing: a `native_scroll` node flag, wheel routing to
  the owning overlay's context, one-shot `scroll_by` for keys, and native
  scrollbar thumb and drag. That is more code than the Lua `text_view` it
  replaces, so it isn't done. The real bug found here was that `text_view`
  wrapped by code points; it now wraps by display width and never splits a
  grapheme cluster (`util.text_graphemes`).
- 4.5: `HollowClayNode` is 304 bytes, about 155 KB per retained surface at 512
  nodes, before Clay's per-element arena. Select's `row_budget` (410) already
  keeps trees under the cap, and nothing would use a higher cap while 4.4 is
  open. The cap stays at 512.
- 6.3: Section dividers are now Clay `betweenChildren` borders.
  `layout_select.sections` stacks select, activity and mux navigator sections
  with `gap = cell_h` and a 1px rule, so preferred heights don't change. The
  dialog title uses the same idea with a half-row gap. Clay draws these rules
  inside the parent's box, so they stop at the panel padding instead of
  running to the frame edge. `full_bleed_x` and its paint path are gone. The
  accent gutter stays a node: a left border on a rounded row would follow the
  corner curve instead of staying a straight inset bar.
- 6.4: `preferred_height` reports the virtualized row budget, not the rendered
  content. Overscan renders up to 24 rows, so FIT would grow the panel, and
  pinning min and max to the budget is what the fixed `frame.height` already
  does. It stays.
- 6.2: activity rows pad inside segment rows, and their accessibility labels
  come from that same plain text. FIXED-width boxes would change the labels
  unless a separate label is built, as workspace does. Width math now uses
  `util.display_width` (it was codepoints), so CJK and emoji workspaces line
  up.
- 6.1: native fitting used to draw the whole truncated prefix in the first
  segment's style, and lost styles entirely when there was no clickable
  suffix. `fitTabSegments` keeps per-segment styles and the suffix. It runs on
  the laid-out width, which covers both `max_width` and shrinking grow tabs.
  Serialized Lua tab state now holds the full text.

