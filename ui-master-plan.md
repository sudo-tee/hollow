# UI master plan: declarative composition + styles

Handoff document for the implementing agent. It sequences two design docs:

- `ui-composition-plan.md` (**CP**): children semantics, `ui.when`, `ui.each`, `ui.join`
- `ui-styles-plan.md` (**SP**): theme tokens, `ui.style`, conditional layers, overlay hover, presets

This file says *what to do and in which order*. The design docs say *how*. On
conflict: this file wins on ordering, the design doc wins on semantics.

---

## 0. Context and ground rules

### Goal
Lua UI renders in `src/lua/hollow/ui` read like a tree:
- no `nodes[#nodes + 1] = ...`
- no `if` blocks gating children
- no inline style tables mixing theme lookups and state ternaries

No reactive runtime, hooks, JSX-like syntax or style DSL. The whole style
toolkit is: **tokens, `ui.style` / `ui.themed_style`, `style.hover`, presets**. State-based styles
are module-level constants combined with `and` (SP §5).

### Environment
- **LuaJIT** (Lua 5.1 semantics; `table.maxn` available; no 5.3+ features).
- Tests: Busted via `scripts/test-lua.sh` (or `zig build test-lua`). Tests in
  `src/lua/tests/test_*.lua`, booted with `tests.harness` (`harness.boot()`).
- Formatting: `stylua` (`stylua.toml`: 100 cols, 2 spaces, double quotes,
  `call_parentheses = "Always"`).
- Types: LuaLS annotations in `types/hollow.lua`.

### Rules
- Match existing style: `---@param` / `---@return` on public functions, sparse comments.
- **Backward compatible.** Only the changes in §6 are intended.
- Don't commit unless the operator says so. Keep each step reviewable alone.
- After every step: full suite green, `stylua --check` clean on touched files.
- No Zig or renderer changes. That rules out new Lua modules: packaged startup
  checks an explicit module registry in `src/lua_bridge.zig`. Put new code in
  existing files.
- If a design doc turns out wrong, record it under "Findings", take the smallest
  safe adjustment, continue.

### Key files
| File | Role |
| --- | --- |
| `src/lua/hollow/ui/primitives.lua` | `ui.span/text/group/row/column/button/action_button/tab/tab_bar`, helpers, `ui.style` |
| `src/lua/hollow/ui/shared.lua` | child collection, `merge_styles`, `resolve_tokens`, `palette`, `apply_hover`, `style_to_segment` |
| `src/lua/hollow/ui/widgets/overlay.lua` | overlay serialization, hover tracking |
| `src/lua/hollow/ui/widgets/bars/bar_serialize.lua`, `bar_events.lua` | bar serialization and hover |
| `src/lua/hollow/ui/builder/components/dialog.lua`, `button.lua` | dialog layout, `button_style` |
| `src/lua/hollow/config.lua` | theme changes, palette cache invalidation |
| `types/hollow.lua` | public API types |
| `docs/reference/lua/ui.md`, `docs/custom-ui.md`, `docs/themes.md` | user docs |

---

## 1. Status

| Step | What | State |
| --- | --- | --- |
| 1 | Baseline (510 tests) | done |
| 2 | Children semantics: `collect_inline` / `collect_rows`, strict containers | done, committed `a3ae1f9` |
| 3 | `ui.when`, `ui.each`, `ui.join` | done, committed `a3ae1f9` |
| 4 | `ui.style` (box-aware merge), tokens, palettes + cache | committed `5c6aaf9` |
| 5 | `ui.variants` | removed in Step A |
| 6 | Migrate `tab` / `tab_bar` / `action_button` | committed `5c6aaf9` |
| 7 | Native overlay hover, `shared.apply_hover` | committed `5c6aaf9` |
| 8 | Builder `button_style` + dialog | committed `5c6aaf9` |
| A | Replace `ui.variants` with conditional layers; public `ui.themed_style` | committed `5c6aaf9` (558 tests including cleanup) |
| B | Widget render-tree migrations | done, uncommitted (562 tests) |
| C | Presets, public types and docs | done, uncommitted (564 tests) |

Remaining: **review and commit**. LuaLS diagnostics require an environment with LuaLS installed.

---

## Step A: Replace `ui.variants` with conditional layers

Why: `ui.variants` (~140 lines + 155 lines of tests) brings `base`/`when`/`by`/
`compound`/`defaults`/`strict`, function layers, sorted layer order, weak theme
caches and clone-on-return. Its four call sites need none of it: two are
base-only, one is two flags, one is an enum. Plain constants + `ui.style` cover
all of them, and since `ui.style` returns a fresh table every time, the cache
and the clone (needed because `bar_events.register` writes `style.id` in place)
go away. See SP §5 for the mapping table.

1. `primitives.lua`: delete `ui.variants` and its helpers (`NIL_PROP`,
   `sorted_keys`, `compile_variants`, `variant_props`, `matches_compound`,
   `add_variant_layer`, `variant_layers`, `variant_palette`, `cache_child`,
   `variant_cache_entry`, `merge_variant_layers`).
2. `ui.tab`: constants `TAB`, `TAB_ACTIVE`, `TAB_BADGED`, `TAB_ACTIVE_BADGED`,
   `BADGE`; render as in SP §8 with public `ui.themed_style(theme, ...)`
   (merge + resolve in one call; `nil` theme leaves tokens lazy).
3. `ui.action_button`: `ACTION` constant (SP §6). Keep the current legacy
   layering of `opts.style` / `opts.hover_style` exactly as it is (see Findings:
   `padding` replaces the whole box).
4. `builder/components/button.lua`: `KINDS` lookup table as in SP §5. Same
   function signature; unknown `kind` falls back to `default`. Uses direct
   theme lookups, not tokens: dialog themes can be partial and
   `resolve_tokens` errors on missing keys.
5. Delete `src/lua/tests/test_ui_variants.lua`. Add the "layers" case from SP §11
   to `test_ui_styles.lua`.

Guards (must pass **unchanged**): `test_ui_composition.lua` tab/tab_bar test,
`test_ui_primitive_styles.lua` and `test_ui_builder_styles.lua` snapshots.

**Done when:** no `ui.variants` / `HollowUiVariants` API references under
`src/lua`, `types`, or `docs`; guards green and output identical.

---

## Step B: Migrate widgets (one file per sub-step)

1. `widgets/mux_navigator.lua`
2. `widgets/activity.lua`
3. `workspace/source.lua`
4. `widgets/select.lua`, `widgets/palette.lua`
5. `builder/behaviors/text_view.lua`, `builder/keys.lua`

Per file:
- Convert only code that builds **render trees**. Hot loops building many rows
  (scroll/text views) may stay imperative if clearer or faster.
- `x = cond and theme.a or theme.b` fields → module-level token constants +
  `ui.style(BASE, cond and STATE)`, or `ui.themed_style(theme, BASE, cond and STATE)`
  when the widget holds a theme. Static styles → plain token tables.
- Row-level hover (`state.hovered_id == row_id`) stays as is (out of scope).

**Done when:** each file's tests and the full suite pass after its sub-step.

---

## Step C: Presets, types, docs

- Presets: `ui.styles = { muted, title, pill, badge, kbd }` (SP §7) in
  `primitives.lua`. Use them in migrated code only where they match exactly
  (`BADGE` → `ui.styles.badge`). Don't change visuals to fit.
- `types/hollow.lua`:
  - `HollowUiChild` / `HollowUiRowChild` recursive aliases; widen `ui.group/row/column`
  - stubs for `ui.when`, `ui.each`, `ui.join`, `ui.style`, `ui.themed_style`, `ui.styles`
  - `HollowStyleToken`; widen `HollowStyle.fg/bg/border`; add `HollowStyle.hover`
- `docs/reference/lua/ui.md`:
  - "Conditional and list rendering": children rules table + helpers
  - "Styles": tokens (full list incl. bar keys), merge rules, conditional
    layers, `ui.themed_style`, hover, presets
- `docs/custom-ui.md`: convert one example. `docs/themes.md`: link the token list.
- Changelog (if the repo keeps one): list §6.

**Done when:** no new LuaLS diagnostics in touched files (if available); doc
examples match the real API.

---

## 6. Intended behaviour changes (complete list)

1. `false`/`nil`/`true` children are skipped. Previously `false` rendered
   `"false"` and a `nil` gap truncated the list.
2. Nested array children flatten at any depth.
3. A wrong-kind child in `ui.group`/`ui.row`/`ui.column` is an error.
4. `ui.column` accepts nested columns and fragments of rows.
5. Non-hex color strings in styles are theme tokens; unknown tokens error.
6. `normalize_inline_nodes(nil | false)` returns `{}`.
7. Overlay spans honour `style.hover`.

Anything else that changes output is a bug.

---

## 7. Final acceptance

- [x] Full suite green; count ≥ 510 + new tests
- [ ] `stylua --check` clean on touched files
- [x] No `#nodes + 1]` in `primitives.lua`; no removed variants API references
- [x] `ui.tab` / `ui.tab_bar` match SP §8 / CP §5 in shape
- [x] Tab/tab_bar regression test unchanged and passing
- [x] Types and docs updated

---

## Findings

Kept by topic; these are facts the remaining steps rely on.

**Theme / palette**
- Runtime theme changes go through `hollow.config.set` (`config.lua`);
  `hollow.term.set_theme` calls it. Palette cache invalidation lives next to the
  existing `THEME_KEYS` / `invalidate_bars()` hook, not in `theme.lua`.
- No production style in `src/lua` / `conf` used non-hex `fg`/`bg` strings
  before tokens landed, so token resolution changed no existing output.
- Bars catch serialization errors per item; unknown-token errors are rethrown
  so typos still fail loudly.

**Hover**
- Mouse hover already causes a fresh overlay serialize (`handleMouseMove` →
  `updateBarHover` wakes rendering → `frameCb` → `renderLuaWidgets` →
  `ui._overlay_state()`). No dirty flag needed. Programmatic event dispatch
  changes state only, without requesting a redraw.
- `action_button` legacy layering: `opts.style.padding` and
  `opts.hover_style.padding` **replace** the whole box (e.g. `{ left = 9 }` stays
  exactly that), unlike `ui.style`'s per-side merge. The hover padding is
  materialized to all four sides before native hover merges it. Existing tests
  pin this; keep it.
- The action-button hover test now checks hover through `apply_hover` at
  serialization instead of eager `opts.state`. Tab regression body preserved
  byte-for-byte (StyLua ignore markers around its old formatting).

**Children**
- Text-shorthand detection inspects `table.maxn`, not `#`, so `{ "a", nil, "c" }`
  keeps `"c"`.
- Dialog bodies: scalar/span/shorthand/inline-array items still become one row
  each; only row-bearing fragments recurse. Plain strict `collect_rows` would
  break the loose dialog body API.

**Module layout**
- New `hollow.ui.*` modules fail the packaged module registry check in
  `src/lua_bridge.zig`. Everything goes into existing files.

**Pre-migration cleanup**
- `ui.button` now clones or creates its style once, then assigns event fields
  through one path. Segment serialization and legacy action hover share
  `shared.normalize_segment_padding`; sparse style-merge boxes remain separate.
  Style merging reuses already-normalized accumulated boxes.
- Full suite: **558 successes, 0 failures, 0 errors, 0 pending**. StyLua clean
  on all four touched Lua files; `git diff --check` clean. Committed `5c6aaf9`.

**Widget migration scope**
- `workspace/source.lua` and `builder/keys.lua` build data, not render trees;
  leave their accumulators unchanged. `text_view.lua` is a hot viewport loop;
  retain its imperative rendering. `source.lua` has pre-existing formatting
  failures and stays untouched rather than introducing unrelated formatting churn.
- Independent pre/post serialized overlay snapshots cover 29 states across mux,
  select, palette, workspace and activity, including navigation, empty results,
  row hover, activity details and distinct-color custom themes. Final render-tree
  and style migration is byte-identical. Four new tests pin custom theme recipes.
- Every migration sub-step passed the full Lua suite. Step B final validation:
  **562 successes, 0 failures, 0 errors, 0 pending**; StyLua clean on all five
  touched Lua files. Row-level hover remains unchanged.

**Final validation**
- Step C adds five presets, reuses exact matching title/muted/badge recipes,
  updates public types, and documents child semantics, tokens, conditional layers,
  native hover and presets. Preset tests cover cloning and bar auto-id isolation.
- Full Lua suite: **564 successes, 0 failures, 0 errors, 0 pending**. StyLua
  clean on all eight touched Lua files; `git diff --check` clean. All 29 overlay
  snapshots still match after preset reuse. Five new documentation examples
  executed successfully, including the mounted sidebar example.
- LuaLS is not installed, so LuaLS diagnostics could not be checked. No root
  changelog exists; compatibility notes live in the UI reference instead.
- Literal `variants` grep also matches four unrelated benchmark descriptions in
  `docs/agent-mux-development.md`. Those historical descriptions remain untouched;
  the removed API/type names have no matches in `src/lua`, `types` or `docs`.
- Final read-only review found no actionable issues. Changes remain uncommitted
  on `feat/declarative-ui`; existing third-party submodule changes are untouched.

**Activity follow-up and short-function experiment**
- Activity now composes visible rows with `ui.each`, optional fragments with
  `ui.when`, and state-based span styles with `ui.styled` layers. Data filtering,
  width calculations and row-hover precedence remain unchanged. Three regression
  tests pin read/selected/stale styles, placeholder alignment and search styling.
- At operator request, activity's expression callbacks use bundled LuaJIT short
  functions: `|| -> expression`, `hint -> expression`, and one `|| -> do ... end`
  block for lazy workspace-color calculation. No other production file adopts
  the experimental syntax. Tests now use the selected `ui.styled` name.
- Verified bundled LuaJIT **2.1.1792588164**, including `zig build test-luajit`.
  Full Lua suite with a CLI linked against the bundled library:
  `LUA=/tmp/opencode/hollow-luajit scripts/test-lua.sh` — **567 successes,
  0 failures, 0 errors, 0 pending**. All 23 detailed activity snapshots match
  pre-refactor output, including the short-function version.
- Tooling limitation: system LuaJIT **2.1.1774638290** and StyLua **2.6.0** do not
  parse the short functions. The default system-interpreter test command must
  use the newer runtime via `LUA`; activity formatting was maintained manually.
  Other touched tests pass StyLua; `git diff --check` remains clean. No Zig,
  renderer, global formatter configuration or submodule changes made here.

**Short-function experiment deferred**
- At operator request, activity callbacks use standard `function(...) ... end`
  syntax again. The composition and style changes remain intact.
- StyLua remains the formatter; no editor or CI migration to `luafmt` is retained.
  Trial runs of EmmyLua Formatter 0.25.1 produced invalid LuaJIT output for some
  call chains and non-idempotent formatting. Revisit after tooling improves.
- Verified `scripts/test-lua.sh` with system LuaJIT: **567 successes, 0 failures,
  0 errors**. Activity passes `stylua --check`; `git diff --check` is clean.
