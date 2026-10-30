# UI components plan: a mini design system on `hollow.ui.components`

Handoff document. Goal: one small, themeable set of reusable components that
every built-in overlay is composed from, and that user configs can use to build
their own overlays with the same look. Follow-up to the layout/components split
(`90b0bd7`).

Non-goals: bars and the sidebar (they keep the inline `ui.span`/`ui.row`
language in `ui/inline.lua`), a retained widget tree, Lua drawing callbacks,
new native node kinds. Keyboard focus, text editing and the caret stay in the
existing behaviors (`ui/behaviors/*`).

---

## 0. Ground rules

- `make test-lua` must pass after every phase; `make test` before merge (see
  the Nix invocation in [clay-migration-plan.md](clay-migration-plan.md#findings)).
  Run `stylua --check` on touched Lua.
- Each phase is reviewable on its own. Don't commit unless the operator says so.
- Migrations are refactors first. Before porting a widget, capture its
  serialized snapshot (`surface:snapshot(ctx)`) in a test and assert the ported
  version produces the same nodes. Intended visual changes are listed per phase
  and get their own commit, with before/after screenshots (`hollow-screenshots`
  skill).
- Accessibility labels and roles must stay identical (`widgets/workspace.lua`
  relies on padded labels).
- The native arena holds 512 nodes per surface (`layout/serialize.lua`). Every
  component documents its node cost and must not add wrapper nodes a hand-written
  tree wouldn't need.
- Line numbers drift. Re-grep before editing. Record plan mistakes under
  "Findings" and take the smallest safe adjustment.

---

## 1. Current state

**Public today** (`ui/components.lua`): `row`, `column`, `text`, `button`,
`progress`, `demo`, plus lazily loaded composites `dialog`, `input`, `select`
with positional `(opts, theme, ctx)` signatures.

**Problems the plan removes**

| Problem                                                         | Where                                                                                     |
| --------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `theme` and `ctx` threaded through every render function        | all widgets; 27× `ctx.cell_w or 8` / `ctx.cell_h or 19`                                    |
| Spacer/gap as empty containers                                  | `c.column({}, { width = "grow" })`, `c.column({}, { width = gap })` in workspace, repl, dialog |
| Scroll viewport + scrollbar wiring copied                       | `components/select.lua` render, `mux_navigator.lua` ~534, `activity.lua` ~661 and ~785    |
| Panel chrome + base insets copied                               | `widgets/overlay.lua` ~95-110, `modal.lua` ~160-180, `notify.lua` ~145-160                |
| Key hints rendered four ways                                    | select `render_hint_rows`, palette ~415, activity `hint_row`, repl `key_hints`            |
| Two button looks, three construction paths, `c.button` unused   | `recipes/button.lua` `root`/`dialog`; `ui.button`, `ui.action_button`, `components/dialog.lua` |
| Headers (title + counter/meta) hand-built                       | select header, mux search row, activity header                                            |
| Empty states hand-built                                         | select, mux, activity (×3 texts)                                                          |
| List rows built inline then adapted (`select.inline`/`from_row`) | mux, activity, palette                                                                   |
| Variants/sizes (`primary`, `ghost`, `sm`, `md`) unused by widgets | `recipes/button.lua`                                                                     |

**Engine facts the design relies on**

- `layout/serialize.lua` resolves color tokens for containers and text against
  the surface palette, so a component can emit `fg = "muted"` without a theme.
- Text nodes paint only `fg` and `bold`. Background, radius, padding or a click
  target on text needs a wrapping container (+1 node).
- Recipe sheets (`style/sheet.lua`) do need a palette: themes override sheets
  through `styles.<sheet>`. Resolution is memoized per palette.
- Hover paint is native (`style.hover`); Lua-side `hovered` state only exists
  for `semantic_hover` modals and costs a re-snapshot.

---

## 2. Design

### 2.1 Call syntax: one props table, children in the array part

```lua
local c = hollow.ui.components

c.panel { padding = "1ch",
  c.header { title = "Workspaces", meta = "3/12" },
  c.scroll { id = "list", c.each(items, render_item) },
  c.hints { { "<CR>", "open" }, { "<C-r>", "rename" } },
}
```

- Named keys are props, `1..table.maxn(t)` are children. Holes, `false` and
  nested fragments are allowed (serialize already flattens them).
- Primitives keep the current `(children, opts)` form: `c.row(t, opts)` with a
  non-nil `opts` is the old form; otherwise the table's hash part is props.
  `c.row({ a, b })` means the same thing in both forms, so no call site breaks.
- Text-like components take their content as the first positional value or a
  `text` prop: `c.label "Filter"`, `c.label { "Filter", tone = "muted" }`.
- Function names and props are snake_case, matching the rest of the Lua API.

### 2.2 Shared props

Every component accepts these and forwards layout props to its root container:

| Prop                                       | Meaning                                                    |
| ------------------------------------------ | ---------------------------------------------------------- |
| `id`                                       | Local ID; required when the component is interactive. Children derive `id .. ":part"`. |
| `label`, `role`                            | Accessibility, defaulted per component.                    |
| `width`, `height`, `min_*`, `max_*`        | Pass-through sizing.                                       |
| `padding`, `gap`                           | Pass-through spacing, accept units (2.4).                  |
| `variant`, `size`                          | Recipe variant/size layer.                                 |
| `selected`, `hovered`, `disabled`          | Recipe state layers.                                       |
| `style`                                    | Override layer merged last (tokens or hex).                |
| `on_click`                                 | Requires `id`; ignored when `disabled`.                    |

### 2.3 Theme comes from the render scope, not parameters

`Surface:snapshot` already knows the palette and context. It sets a render scope
for the duration of `render(ctx)`:

```lua
-- inside layout.lua Surface:snapshot
components._scope = { theme = palette, ctx = render_ctx }
local ok, tree = pcall(self.render, render_ctx)
components._scope = nil
```

Components call `scope().theme` to resolve recipes, falling back to
`shared.palette("select")` outside a surface (tests, ad-hoc trees). Rendering is
synchronous and never yields, so a module-level scope is safe; restore the
previous scope so nested surfaces snapshotting (if ever) stay correct.

Explicit `theme` stays accepted as a prop for callers that render with a
different palette (e.g. modal `render(theme, ...)` passing its own theme).

### 2.4 Cell units

Sizes, gaps and padding accept `"<n>ch"` (cell widths) and `"<n>lh"` (cell
heights) besides pixels: `padding = { x = "1ch", y = "0.5lh" }`, `gap = "1lh"`.
Resolution happens in `layout/serialize.lua`, which receives `ctx` as a new
fourth argument from `Surface:snapshot` (default 8×19 when absent, as today).
Pixel numbers keep working unchanged.

### 2.5 Recipes

- One sheet per component in `ui/recipes/<component>.lua`, named after the
  component, so themes override any component through `styles.<name>`.
- A component is recipe + structure: `recipes.badge(theme, props).root` gives
  paint, the component decides nodes.
- `sheet:check(palette)` runs against every bundled theme in tests
  (`test_ui_stylesheet.lua`); add each new sheet there.

### 2.6 File layout

```
ui/components.lua             registry: primitives + lazy map of composites
ui/components/props.lua       split props/children, units passthrough, scope()
ui/components/<name>.lua      one component per file, returns a function
ui/components/demo.lua        gallery of every component (replaces the Clay demo)
ui/recipes/<name>.lua         one sheet per component
```

Types: one `HollowUi<Name>Props` class per component in `types/hollow.lua`,
and `HollowUiComponents` lists them.

---

## 3. Catalog

Node cost is per instance, excluding user children.

### Layout

| Component            | Props (beyond shared)                                    | Nodes | Replaces |
| -------------------- | -------------------------------------------------------- | ----- | -------- |
| `row`, `column`      | existing options                                         | 1     | — |
| `text`               | `wrap`, `text_align`                                     | 1     | — |
| `spacer()`           | —                                                        | 1     | `column({}, { width = "grow" })` |
| `gap(n)`             | `n` in px or units; axis from parent is not known, so `gap { width = .. }` / `gap { height = .. }` | 1 | `column({}, { width = gap })` |
| `stack`              | `divided` (border between children), `direction`         | 1     | `components.select.sections`, dialog title rule |
| `scroll`             | `id` (required), `reveal`, `reveal_start`, `scrollbar` = `{ id, ratio, size }`, `axis` = `"y"\|"x"\|"both"`, `measure` | 1 | viewport blocks in select, mux, activity ×2 |
| `when`, `each`, `join` | re-exports of `ui.when` / `ui.each` / `ui.join`        | 0     | — |

`scroll` owns the right gutter (`max(8, 1ch)` when the scrollbar shows) and the
track/thumb colors from `recipes/list_row` `paint`, so callers pass only the
logical thumb ratio/size from `selectable_list.visible_range()`.

### Atoms

| Component  | Props                                            | Nodes | Replaces |
| ---------- | ------------------------------------------------ | ----- | -------- |
| `label`    | `tone` = `"default"\|"muted"\|"title"\|"empty"\|"counter"`, `wrap` (default `"none"`) | 1 | `c.text(x, s.muted, { wrap = "none" })` |
| `title`    | as `label`, bold `title` tone                    | 1     | dialog/select/repl titles |
| `badge`    | `text`, `color` (bg override)                    | 2     | `styles.badge`, workspace program-status badge |
| `pill`     | `text`, `fg`, `bg`                               | 2     | workspace domain pill |
| `kbd`      | `key` (normalized like `normalize_hint_chord`)   | 2     | `styles.kbd`, hint keys |
| `icon`     | `name` (from `ui/icons.lua`), `tone`             | 1     | `icons.*` strings in text |
| `progress` | existing                                         | 1     | — |

`kbd` and `badge` cost 2 nodes because text can't carry a background. Inside
dense lists prefer `label` with a tone.

### Controls

| Component | Props                                                        | Nodes | Replaces |
| --------- | ------------------------------------------------------------ | ----- | -------- |
| `button`  | `text`, `appearance` = `"solid"\|"quiet"`, `variant` = `"default"\|"primary"\|"destructive"`, `size` = `"sm"\|"md"` | 2 | `layout.button`, dialog buttons, `ui.action_button` in overlays |
| `hints`   | list of `{ key, desc }`; `separator`                          | 1 + 2/hint (key as `label` tone, not `kbd`, to stay cheap) | four hint renderers |
| `input`   | `behavior` (a `ui.text_input`), `boxed` (default true)       | 2 + runs | `components/input.lua` positional signature |
| `tabs`    | `tabs` = `{ { id, label, badge? } }`, `active`, `on_select`   | 2/tab | inline `ui.tab` / `ui.tab_bar` in overlays |

`button` merges `recipes/button.lua` `root` and `dialog` into one sheet:
`appearance = "quiet"` is today's dialog look (text-colored until hovered or
selected), `"solid"` the current root. `ghost` is removed (it was `default`).
Hover paint uses native `style.hover`; `selected` stays a prop for keyboard focus.

### Containers

| Component | Props                                               | Nodes | Replaces |
| --------- | --------------------------------------------------- | ----- | -------- |
| `panel`   | `chrome` (theme chrome or override), `inset` = `"overlay"\|"modal"\|"none"` | 1 | root columns in overlay, modal, notify toast |
| `header`  | `title`, `meta` (right-aligned text or nodes), `prompt` suffix `":"` | 2–4 | select header, mux search row, activity header |
| `empty`   | `text`                                               | 1     | "No matches", "No matching panes", activity empties |

`panel` owns the base insets (`0.5ch`/`1lh`/`0.5lh` for overlays, `1.5ch` for
modals) so overlay.lua and modal.lua stop computing them.

### Lists

| Component   | Props                                                                          | Nodes | Replaces |
| ----------- | ------------------------------------------------------------------------------ | ----- | -------- |
| `list_item` | `id`, `selected`, `hovered`, `accent` (bool/color), `detail`, `on_activate`, children = label content | 3 + content | `select.item`, `select.from_row` row shell |
| `list`      | `id`, `items`, `render_item(item, index, view)`, `selected`, `viewport` (from `selectable_list`), `window` (default 24), `budget` (default 410), `empty` | 1 + scroll + items | windowing/budget logic in `select.render`, mux ~477-512 |
| `rich`      | inline nodes (`ui.text`/`ui.span` output), `prefix`                           | 1 + runs | `components/select.lua` `inline` (kept for user `format_item` output) |
| `picker`    | `title`, `counter`, `filter` (text_input), `list` props, `hints`              | composite | select, palette, workspace, mux, activity shells |

`list` keeps the existing guarantee: visible and selected rows render rich, the
farthest overscan rows degrade to `plain` first when the tree would exceed the
budget. `render_item` receives `view.plain` to honor that.

### Composites

| Component | Props                                            | Replaces |
| --------- | ------------------------------------------------ | -------- |
| `dialog`  | `title`, `body` (string or nodes), `actions` = `{ { id, text, kind, on_click } }`, `selected` | `components/dialog.lua` (built on `stack` + `button`) |
| `toast`   | `level`, `text`, `action`                        | notify toast column |

---

## 4. Phases

### Phase 1: foundations (no widget changes)

1. `ui/components/props.lua`: `split(t, opts)` → `props, children`; `scope()`.
2. Render scope in `layout.lua` `Surface:snapshot` (restore previous on error).
3. Units: `serialize(root, palette, namespace, ctx)`; resolve `ch`/`lh` in
   `size()`, `gap`, padding normalization. Reject unknown unit strings with the
   field name in the error.
4. Props-table form for `row`/`column`/`text`; add `spacer`, `gap`, `when`,
   `each`, `join`.

Done when: new unit tests for split/units/scope pass; all existing tests pass
unchanged.

### Phase 2: atoms and controls

1. `label`, `title`, `badge`, `pill`, `kbd`, `icon` with recipes
   (`recipes/badge.lua`, `kbd.lua`, `label.lua`; fold `recipes/common.lua`
   presets into them, keep `hollow.ui.styles` as aliases).
2. `button` with the merged recipe. Port `components/dialog.lua` to it.
   **Visual change:** none intended; verify dialog snapshot equality.
3. `hints`; port select, palette, activity, repl. **Visual change:** repl hints
   gain key/desc coloring; activity loses its parsed-string hint format.
4. `input` props form; old positional call kept as a thin wrapper until Phase 4.

### Phase 3: containers

1. `panel`; overlay.lua, modal.lua and notify use it.
2. `stack`, `scroll`, `header`, `empty`; port the select shell, mux, activity
   (list and details views).

Done when: no widget computes scrollbar gutters or base insets, and
`ctx.cell_w or 8` appears only in `props.lua`/serialize.

### Phase 4: lists and picker

1. `list_item`, `list`, `rich` extracted from `components/select.lua`.
2. `picker`; select and palette first (closest to it), then workspace, mux,
   activity. Each port is its own commit with snapshot-equality tests.
3. Delete `components/select.lua` once nothing requires it (`from_row` and
   `row_height` go with it; `inline` lives on as `rich`).

### Phase 5: composites, cleanup, docs

1. `dialog` props form on `stack` + `button`; `toast` for notify.
2. Remove positional wrappers, `ui.action_button` uses in overlays (bars keep
   `ui.button`), the theme threading left in widgets.
3. Replace `components/demo.lua` with a gallery: every component, every variant,
   size and state, on one scrollable surface. Use it for screenshots and as a
   theme-check fixture.
4. New `docs/reference/lua/components.md` (one section per component: props,
   node cost, example). Shorten the components part of `clay-layout.md` to point
   there. Update `types/hollow.lua`.

---

## 5. Testing

- **Unit:** each component in isolation via `serialize` with a fixed palette and
  ctx: node count, IDs, roles, labels, resolved colors per state.
- **Snapshot equality:** for each widget port, a test renders the widget before
  and after against the same model and compares serialized nodes. Capture the
  "before" fixture in the commit preceding the port.
- **Recipes:** every new sheet runs through `sheet:check` against bundled themes.
- **Budget:** a test fills `list` past the 410-node budget and asserts the
  selected row stays rich and total nodes stay under 512.
- **Gallery:** the gallery surface snapshots without errors on every bundled
  theme.

---

## 6. Risks

- **Node cap.** Atoms with backgrounds cost 2 nodes. Lists must keep using tone
  labels inside rows; `list` budget tests guard this.
- **Render scope leaks.** An error inside `render` must restore the scope;
  covered by a test that throws from render and then renders another surface.
- **Theme overrides.** Renaming sheets (`dialog` slot into `button` appearance,
  `common` presets into atoms) breaks user themes that override
  `styles.button.dialog`. Keep the old slot names as aliases for one release and
  log a deprecation once.
- **Snapshot equality may be too strict** where porting fixes a real
  inconsistency. Record those under Findings and accept a reviewed diff instead.

---

## 7. Open questions

1. `appearance` vs `variant` naming for solid/quiet buttons?
2. Should `hints` use `kbd` chips (nicer, +1 node per hint) or tone labels?
3. Expose `picker` publicly in Phase 4, or keep it internal until its props
   settle?
4. Keep `c.row(children, opts)` forever, or deprecate it once the props form
   is everywhere?

---

## Status

| Phase                     | State       |
| ------------------------- | ----------- |
| 1 Foundations             | Implemented |
| 2 Atoms and controls      | In progress |
| 3 Containers              | Not started |
| 4 Lists and picker        | Not started |
| 5 Composites, cleanup     | Not started |

## Findings

- `box.normalize` silently ignores string values, including scalar padding;
  resolve units before normalization rather than modifying shared box behavior.
- A scalar `gap(n)` has no parent-axis information. It defaults to width;
  use `gap { height = n }` for vertical gaps.
- Existing input rendering costs two nodes per run (a container plus text),
  not one; its total cost is `2 + 2/runs`. Keep this structure for parity.
- Select hints use a separately colored separator node. `hints` accepts a
  separator style to preserve those nodes during the refactor; compact hints
  retain the planned two-nodes-per-hint cost.
