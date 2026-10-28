# UI master plan: declarative composition + styles

Handoff document for the implementing agent. It sequences two detailed design
docs into one execution order:

- `ui-composition-plan.md` (**CP**): children semantics, `ui.when`, `ui.each`, `ui.join`
- `ui-styles-plan.md` (**SP**): theme tokens, `ui.style`, `ui.variants`, overlay hover, presets

**Read both plans before starting.** This file says *what to do and in which
order*. The design docs say *exactly how*, including the edge cases. If this
file and a design doc disagree, this file wins on ordering and the design doc
wins on semantics.

---

## 0. Context and ground rules

### Goal
Make Lua UI renders in `src/lua/hollow/ui` read like a tree:
- no `nodes[#nodes + 1] = ...`
- no `if` blocks gating children
- no large inline style tables mixing theme lookups and state ternaries

No reactive runtime, hooks or JSX-like syntax.

### Environment
- Runtime: **LuaJIT** (Lua 5.1 semantics; `table.maxn` is available, and there are
  no 5.3+ features such as integer division or `utf8`).
- Tests: Busted. Run with `scripts/test-lua.sh` (or `zig build test-lua`). Config
  is in `.busted`, and tests live in `src/lua/tests/test_*.lua`. Use `tests.harness`
  (`harness.boot()`) as in `test_ui_composition.lua`.
- Formatting: `stylua` with `stylua.toml` (100 cols, 2 spaces, double quotes,
  **`call_parentheses = "Always"`**, so write `ui.button({ ... })`, never `ui.button { ... }`).
- Types: LuaLS annotations in `types/hollow.lua` (`.luarc.json` at the root).

### Rules
- Keep the existing code style: `---@param` / `---@return` annotations on public
  functions and comment density matching the surrounding code (sparse).
- **Backward compatible.** Every existing public call shape keeps working.
  The only intended behaviour changes are listed in §6.
- Do not commit. Leave changes uncommitted for review unless the operator says
  otherwise. Keep each step self-contained so it can be reviewed and committed
  on its own.
- After every step, the full Lua test suite must pass and `stylua --check` must be clean
  on the touched files.
- Don't touch Zig or renderer code. Everything here is Lua plus types and docs.
- If a step reveals that the design doc is wrong (an API that doesn't exist, an
  assumption that doesn't hold), stop, write the finding under "Findings" at the
  bottom of this file, pick the smallest safe adjustment, and continue.

### Key files
| File | Role |
| --- | --- |
| `src/lua/hollow/ui/primitives.lua` | `ui.span/text/group/row/column/button/action_button/tab/tab_bar` |
| `src/lua/hollow/ui/shared.lua` | `normalize_inline_nodes`, `flatten_span_nodes`, `style_to_segment`, `merge_style_tables`, `normalize_box`, widget row normalizers |
| `src/lua/hollow/ui/composition.lua` | registers builder helpers on `ui` |
| `src/lua/hollow/ui/widgets/overlay.lua` | overlay serialization, `ui.overlay.new` hover state |
| `src/lua/hollow/ui/widgets/core.lua` | widget segment serialization |
| `src/lua/hollow/ui/widgets/bars/bar_serialize.lua`, `bar_events.lua` | bar serialization, bar hover (`resolve_style`), in-place `style.id` mutation |
| `src/lua/hollow/ui/builder/components/dialog.lua`, `button.lua` | dialog layout, `button_style` |
| `src/lua/hollow/theme.lua` | `resolve_widget(kind)`, `create_ui` (bar color sources) |
| `src/lua/hollow/util.lua` | `clone_value`, `merge_tables` (deep, mutating) |
| `types/hollow.lua` | public API types (~line 242 `HollowStyle`, ~2110 `ui.*` stubs) |
| `docs/reference/lua/ui.md`, `docs/custom-ui.md`, `docs/themes.md` | user docs |

---

## Step 1: Baseline

1. Run the full Lua suite and record the pass count under "Findings".
2. Read `src/lua/tests/test_ui_composition.lua`. Its tab/tab_bar test indexes
   flattened nodes by position (`nodes[1]`, `nodes[5]`, `nodes[6]`), which makes
   it the regression guard for child **ordering** in every later step.
3. Find and note in "Findings":
   - how and where the theme changes at runtime (needed for the palette cache
     invalidation in Step 4)
   - whether an `overlay:hover` event triggers a re-render or re-serialize (needed
     for Step 7)

**Done when:** the baseline is recorded and both questions are answered.

---

## Step 2: Children semantics (CP §2, §4)

Implement in `shared.lua`:
- `collect(list, accept, label, out)` with `for i = 1, table.maxn(list)`:
  - skip `nil` / booleans
  - recurse into plain array tables that are not text shorthand (fragments)
  - pass everything else to `accept`
- `M.collect_inline(list, label, strict)` and `M.collect_rows(list, label)`.
  - Strict mode errors with `"<label>: unexpected <type> node at child <i>"`.
- Re-implement `M.normalize_inline_nodes` on top of the lenient mode, keeping
  string, number and span behaviour, with `nil`/`false` → `{}`.

Update `primitives.lua`:
- `ui.group` / `ui.row` → `collect_inline(..., strict = true)`. Keep `row`'s guard
  against a bare span or shorthand passed as `children`.
- `ui.column` → `collect_rows`: splice nested columns and fragments, error on
  non-rows.
- Leave widget `render()` top-level normalization strict (CP §4). Don't add
  list acceptance there.

Tests: the full CP §6 list for children (falsy values, holes, deep fragments,
strings and numbers, shorthand stays a leaf, column splicing and errors, strict
group vs lenient `normalize_inline_nodes`).

**Done when:** the new tests pass, all existing tests pass (especially
`test_ui_composition.lua` and `test_ui_bars.lua`), and nothing outside these two
files changed.

---

## Step 3: Control-flow helpers (CP §3, without `ui.style`)

In `primitives.lua`, add `ui.when`, `ui.each` and `ui.join` exactly as specified
in CP §3. **Do not** add the CP version of `ui.style`, because Step 4 implements
the full version.

Tests: CP §6 cases for `when`, `each` and `join` (thunk laziness, falsy results
dropped, `hollow.tbl` wrapper, no leading or trailing separators, falsy items
dropped before joining, function separator gets its index).

**Done when:** the tests pass. Don't migrate any call sites yet.

---

## Step 4: Style merge + theme tokens (SP Phase A, SP §3, §4, §9)

`shared.lua`:
- `M.merge_styles(...)`:
  - skip falsy arguments, return a fresh table, never mutate inputs
  - normalize `padding` / `margin` per side before merging
  - merge `hover` recursively
  - Re-implement `merge_style_tables(a, b)` as a wrapper around it.
- `M.resolve_tokens(style, palette)`:
  - only color keys (`fg`, `bg`, `border`, plus the same keys inside `hover`)
  - `#…` stays a hex value, any other string is a token, dotted paths are allowed
  - unknown tokens **error** with a "did you mean" hint (SP §9.4)
  - returns a fresh table
- Palette cache: `M.palette(kind)` (wraps `theme.resolve_widget(kind)`) and
  `M.bar_palette()` (widget `"all"` plus the bar keys from the SP §3 table).
  Cache per theme generation and invalidate at the hook found in Step 1.
- `M.style_to_segment(text, style, palette?)`: for non-hex color strings,
  resolve via `palette` or, when it's absent, `M.palette("all")`.

Callers:
- `overlay.lua` passes the widget kind's palette through `serialize_overlay_row`.
- `bar_serialize.lua` passes `bar_palette()`.
- `core.lua` relies on the default (`"all"`).

`primitives.lua`: add `ui.style = shared.merge_styles` (public).

Tests: SP §11 merge, tokens, bar palette and lazy sections.

**Done when:** the tests pass. Existing output is byte-identical: no existing
style uses non-hex color strings. Verify this by grepping for `fg = "` /
`bg = "` with non-`#` values across `src/lua` and `conf/`, and note the result
under "Findings".

---

## Step 5: Variants (SP Phase B, SP §5)

Add `ui.variants(spec)` (in `primitives.lua`, or a new
`src/lua/hollow/ui/styles.lua` loaded from `composition.lua`; prefer the new
file):
- `base`, `when` (flags), `by` (enums), `compound`, `defaults`, `strict`.
- Layer order is fixed at definition time: base → `by` (sorted keys) → `when`
  (sorted keys) → `compound` (list order).
- Style values may be `function(theme) -> style`.
- Returns `fn(props, theme?)`: if `theme` is given, resolve tokens eagerly with
  `resolve_tokens`. Otherwise leave them for the lazy path.
- Cache per `(theme, props key)` with a weak-keyed outer table, and **return a clone
  every call** (`bar_events.register` mutates `style.id`).

Tests: SP §11 variants and cache-safety sections.

**Done when:** the tests pass.

---

## Step 6: Migrate primitives (CP §5 + SP §8, in one pass)

In `primitives.lua`:
- Add the local `select_theme(opts)` helper (SP §8, Decision 3: default
  `"select"` palette).
- Rewrite `ui.tab` as in SP §8: `tab_style` and `badge_style` variants, plus
  `ui.when` for the badge.
- Rewrite `ui.tab_bar` with `ui.join(ui.each(...), "  ")`.
- Rewrite `ui.action_button` with a variant. **Keep** its current hover behaviour
  through `opts.state` / `opts.hover_style` for now. Step 7 moves it to native
  hover.

Tests: the existing tab/tab_bar test passes **unchanged**. Add the SP §11
"primitives default" case (no `opts.theme` gives the same hex values as before).
Capture the before/after flattened output in a test if useful.

**Done when:** output is identical and there are no `#nodes + 1` lines left in
these functions.

---

## Step 7: Native hover in overlays (SP Phase C, SP §6)

- Extract `shared.apply_hover(style, hovered_id)` from `bar_events.resolve_style`
  and make the bars use it (no behaviour change).
- `ui.overlay.new`: record the hovered id where `serialize_overlay_widget` can
  read it (for example `widget._hovered_id`). Keep `hover_state` for row-level
  hover.
- `serialize_overlay_row`: apply `apply_hover` to span styles whose `id` matches.
- If Step 1 found that hover doesn't trigger a redraw, mark the widget dirty in
  the `on_event` wrapper.
- `ui.action_button`: move hover into `style.hover`, and map the legacy
  `opts.hover_style` onto it. `opts.state` becomes optional.

Tests: SP §11 overlay hover. `test_ui_bars.lua` stays green.

**Done when:** the tests pass and `action_button` no longer reads `state.hovered_id`.

---

## Step 8: Migrate builder components

- `builder/components/button.lua` `button_style` becomes a variant with
  `by = { kind = ... }`, `when = { emphasized = ... }` (selected or hovered) and
  a function escape hatch for the `brighten_hex_color` case. Keep the function
  signature, and have it call the variant.
- `builder/components/dialog.lua`:
  - `append_body_item` mostly collapses into `collect_rows`
  - the footer becomes `ui.join(ui.each(footer, ...), "  ")`
  - keep the `click_registry.register` side effect inside the `each` callback

Tests: the existing dialog / modal tests stay green. Add one dialog test with a
gated body item (`cond and row`) and one with a nested column body.

**Done when:** the tests pass.

---

## Step 9: Migrate widgets (one file per sub-step)

In this order, each reviewable on its own:
1. `widgets/mux_navigator.lua`
2. `widgets/activity.lua`
3. `workspace/source.lua`
4. `widgets/select.lua`, `widgets/palette.lua`
5. `builder/behaviors/text_view.lua`, `builder/keys.lua`

For each file:
- Convert only code that builds **render trees**. Leave data accumulators and
  hot loops building many rows (scroll and text views) imperative when that's
  clearer or faster.
- Replace `x = cond and theme.a or theme.b` style fields with variants and tokens
  where the component has 2 or more states. Leave single static styles as
  plain token tables.
- Row-level hover (`state.hovered_id == row_id`) is **out of scope**. Keep it.

**Done when:** each file's tests (and the full suite) pass after its sub-step.

---

## Step 10: Presets, types, docs (SP Phase D/E, CP §7)

- Presets: add `ui.styles` (`muted`, `title`, `pill`, `badge`, `kbd`) in the
  styles module. Use them in already-migrated code where they fit exactly.
  Don't change visuals to make them fit.
- `types/hollow.lua`:
  - `HollowUiChild` / `HollowUiRowChild` recursive aliases, and widen
    `ui.group/row/column` params
  - stubs for `ui.when`, `ui.each`, `ui.join`, `ui.style`, `ui.variants`, `ui.styles`
  - `HollowStyleToken`, widen `HollowStyle.fg/bg/border`, add `HollowStyle.hover`
  - `HollowUiVariantsSpec`
- `docs/reference/lua/ui.md`:
  - "Conditional and list rendering": the children rules table plus helpers
  - "Styles": tokens (list them, including the bar keys), merge rules, variants,
    hover and presets
- `docs/custom-ui.md`: convert one example to the new style.
- `docs/themes.md`: link the token list.
- Changelog / notes: if the repo keeps one, add an entry listing the behaviour
  changes from §6.

**Done when:** LuaLS shows no new diagnostics in the touched files (if available),
and the docs examples match the real API.

---

## 6. Intended behaviour changes (complete list)

1. A `false`/`nil`/`true` child is skipped. Previously `false` rendered `"false"`
   and a `nil` gap truncated the rest of the list.
2. Nested array children are flattened at any depth (previously one level, or a
   `tostring(table)` span).
3. A wrong-kind child in `ui.group`/`ui.row`/`ui.column` is an error. Previously
   it was a `table: 0x…` span, or an error for columns only.
4. `ui.column` accepts nested columns and fragments of rows.
5. Non-hex color strings in styles are theme tokens. Unknown tokens error
   (previously they were ignored silently).
6. `normalize_inline_nodes(nil | false)` returns `{}`.
7. Overlay spans honour `style.hover`.

Anything else that changes output is a bug.

---

## 7. Final acceptance

- [ ] Full Lua suite green; pass count ≥ the Step 1 baseline plus the new tests
- [ ] `stylua --check` clean on all touched files
- [ ] `grep -rn '#nodes + 1\]' src/lua/hollow/ui/primitives.lua` returns nothing
- [ ] `ui.tab` and `ui.tab_bar` match SP §8 / CP §5 in shape
- [ ] The tab/tab_bar regression test is unchanged and passing
- [ ] Types and docs updated
- [ ] "Findings" below filled in

---

## Findings

- Step 1 baseline: `scripts/test-lua.sh` — **510 successes, 0 failures, 0 errors,
  0 pending**. Existing tab/tab_bar positional regression test read; keep unchanged.
- Runtime theme changes go through `hollow.config.set` in
  `src/lua/hollow/config.lua`; `hollow.term.set_theme` calls it. Cache invalidation
  belongs beside the existing `THEME_KEYS` / `invalidate_bars()` hook, not in
  `theme.lua` as the styles plan initially assumes.
- Overlay hover from mouse movement already reaches a fresh render/serialize:
  `handleMouseMove` calls `updateBarHover` (which enqueues hover input and wakes
  rendering through `App.enqueueMouse`), then `updateOverlayHover`.
  `frameCb` calls `renderLuaWidgets`, which calls `ui._overlay_state()`; that
  serializes and renders every overlay without a Lua widget cache. No explicit
  widget dirty mark is needed for Step 7's normal mouse-hover path. The event
  wrapper alone does not request redraw; programmatic dispatch only changes state.
- Preliminary Step 4 grep: no non-hex literal `fg` / `bg` strings found in
  `src/lua` or `conf`; repeat when implementing tokens.
- Step 2 clarification: shorthand detection must inspect the maximum numeric
  index, not stop at a hole; otherwise `{ "a", nil, "c" }` loses `"c"` before
  fragment collection.
- Step 2 implementation scope remains `shared.lua` and `primitives.lua`, with
  required regression tests in `test_ui_children.lua` and findings recorded here.
- Step 2 complete: full suite **519 successes**, no failures/errors/pending;
  StyLua clean on both implementation files and new tests. Existing
  `test_ui_composition.lua` unchanged. StyLua also normalized existing formatting
  in `shared.lua` to satisfy whole-file checks.
- Step 3 implemented: `ui.when`, `ui.each`, `ui.join`; tests in
  `test_ui_helpers.lua`. Function separators receive their 1-based separator
  number after falsy items are removed. No call-site migrations yet. Full suite:
  **524 successes, 0 failures, 0 errors, 0 pending**; StyLua clean on all four
  touched Lua files; `git diff --check` clean.
- Next: Step 4 (style merging, tokens, palette cache and serialization plumbing).
