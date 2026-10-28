# UI styles plan: static styles, theme tokens, conditional layers

Companion to `ui-composition-plan.md`. That plan fixes _structure_ (children,
gating, lists). This one fixes _styles_: large inline style tables that mix
layout constants, theme lookups and state logic inside the render.

Goal: a component render should only say **which** style applies
(`tab_style({ active = active })`), not **how** it is built.

Non-goals: CSS, selectors, cascading beyond what group inheritance already does,
or a class-name system.

---

## 1. Problems today

`ui.tab` shows all of them in about 20 lines:

```lua
style = {
  fg = active and theme.selection_fg or theme.muted,    -- state + theme mixed
  bg = active and theme.selection_bg or nil,
  bold = active,
  radius = 4,                                            -- constant, repeated in 23 places
  background_extend = active and badge and 2 or nil,     -- compound state
  padding = { left = 8, right = badge and 0 or 8, top = 3, bottom = 3 },  -- verbose box
},
```

| Problem                                                                                                                  | Cause                                                                     |
| ------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------- |
| Styles can't live outside render                                                                                         | they need `theme`, which only exists at render time                       |
| `x = cond and a or b` on every field                                                                                     | no way to layer "base + active overrides"                                 |
| Compound conditions (`active and badge`)                                                                                 | no notion of variant combinations                                         |
| Verbose `padding = { left, right, top, bottom }`                                                                         | box shorthands exist (`x`/`y`, numbers, CSS arrays) but nothing uses them |
| Manual hover in overlays (`state.hovered_id == id` in `action_button`, `select`, `palette`, `activity`, `mux_navigator`) | `style.hover` only works in bars (`bar_events.resolve_style`)             |
| Same recipes everywhere (pill: `radius = 4` + small padding; muted text; title)                                          | no shared presets                                                         |

What already exists and should be reused:

- `style_to_segment` already accepts `padding = 4`, `{ x = 8, y = 3 }` and
  `{ 3, 8 }` (CSS order).
- `flatten_node` already merges a `group`'s style into its children
  (inheritance), so you can set `fg` once on a parent.
- Bars already apply `style.hover` when the span's `id` is hovered.
- `theme.resolve_widget(kind)` gives a flat token table: `fg`, `muted`,
  `selection_bg`, `hover_bg`, `primary_bg`, `notify_levels.warn`, ...

---

## 2. Design overview (three small pieces)

1. **Theme tokens**: a style color can be a token name (`fg = "muted"`) instead
   of a hex value. Styles then no longer need `theme` and can become module-level
   constants.
2. **`ui.style(...)`**: layered, box-aware merge that skips falsy arguments.
   State-based styles are just conditional layers: `ui.style(BASE, active and ACTIVE)`.
   No separate variants DSL (see §5).
3. **Native `hover` in overlays**: `style.hover = { ... }` works the same way it
   does in bars, so components stop checking `hovered_id` themselves.

Optional fifth piece: **`hollow.ui.styles` presets** (`pill`, `badge`, `muted`,
`title`, `kbd`).

---

## 3. Theme tokens

### Rule

For color keys (`fg`, `bg`, `border`, and the same keys inside `hover`):

- a value starting with `#` is a hex color (unchanged)
- any other string is a **token**, looked up in the resolved widget theme
- dotted paths are allowed: `"notify_levels.warn"`
- an unknown token raises an error with the token name and the style key. Typos
  should fail loudly, not silently render the default color. (Decision 4: there
  is no dev/release flag in `src/lua/hollow` today, so it is always an error.
  If a dev flag is added later, release builds switch to warn-once.)

Non-color keys (`radius`, `padding`, `bold`, ...) are never treated as tokens.

### Two resolution points

**Eager**: `shared.resolve_tokens(style, theme)` returns a fresh table with tokens
replaced. Use it when a component takes `opts.theme` (as `ui.tab` and `tab_bar`
do in tests), so the custom theme wins. Internal for now; expose it publicly only
if user code turns out to need it.

**Lazy (fallback)**: in `shared.style_to_segment`, if `fg`/`bg`/`border` is a
non-hex string, resolve it against the current theme. The palette comes from
`theme.resolve_widget(kind)`, where `kind` is the overlay widget kind when known
and otherwise `"all"`. This is what makes plain constants work anywhere:

```lua
ui.text(cwd, { fg = "muted" })
ui.group(children, { fg = "detail" })   -- inherited by children via flatten
```

- Cache the resolved palette per (theme generation, kind). `resolve_widget`
  clones and merges tables, so it's too expensive to run per segment. Invalidate
  it in the theme-change path in `theme.lua` (find the existing hook).
- Lazy resolution changes nothing for existing code: today non-hex strings are
  dropped (`is_hex_color` check), so no current style depends on them.
- `flatten_span_nodes` output keeps tokens unresolved. Tests that inspect
  flattened nodes and want hex values must use the eager path. The existing tab
  test passes `opts.theme`, so it does.

### Where `kind` comes from in the lazy path

- `widgets/overlay.lua` `serialize_overlay_widget`: the widget kind is known.
  Pass it down to `serialize_overlay_row` → `style_to_segment(text, style, palette)`.
- `widgets/core.lua`: use `"all"`.
- `bars/bar_serialize.lua`: use the **bar palette** (Decision 2): the widget
  palette for `"all"` plus bar keys, so there is one namespace. Build it in
  `shared.bar_palette()` from `theme.ui` (see `create_ui` in `theme.lua`):

  | Token | Source |
  | --- | --- |
  | `bar_bg` | `ui.top_bar.background` |
  | `bar_fg` | `ui.status.fg` |
  | `status_bg` / `status_fg` | `ui.status.bg` / `ui.status.fg` |
  | `tab_bar_bg` | `ui.tab_bar.background` |
  | `tab_active_fg` / `tab_active_bg` | `ui.tab_bar.active_tab.fg` / `.bg` |
  | `tab_inactive_fg` / `tab_inactive_bg` | `ui.tab_bar.inactive_tab.*` |
  | `tab_hover_fg` / `tab_hover_bg` | `ui.tab_bar.hover_tab.*` |
  | `accent` / `warm` | `ui.accent` / `ui.warm` |

  Bar keys win on a name clash, which can't happen today because none of these
  names exist in `resolve_widget`. The same cache and invalidation apply.
- Add an optional third param `palette` to `style_to_segment` rather than looking
  it up inside. That keeps the function pure and easy to test.

---

## 4. `ui.style(...)`: merge semantics

The composition plan already introduces this. Its semantics:

- Arguments are merged left to right. `nil`/`false` arguments are skipped, so
  `cond and { ... }` works.
- Always returns a fresh table. Never mutates its inputs (constants and themes
  are shared).
- `padding` / `margin`: normalize each side to `{ top, right, bottom, left }`
  **before** merging, so these all combine correctly:
  `padding = 4` + `{ right = 0 }`, `{ x = 8 }` + `{ right = 0 }`, `{ 3, 8 }` + `{ top = 0 }`.
  Without this, `util.merge_tables` would replace a number with a table and lose
  the other sides. Reuse `shared.normalize_box`, but only fill in the sides that were given.
- `hover`: merged one level deep (same rules, recursively).
- Event fields (`id`, `on_click`, ...) can be merged but shouldn't live in style
  constants. `ui.button` keeps injecting them.
- Tokens pass through untouched (resolved later, eagerly or lazily).

Implement it as a dedicated `shared.merge_styles(...)`. Keep
`merge_style_tables(a, b)` as a thin wrapper so existing callers don't change.

---

## 5. State-based styles: conditional layers (no `ui.variants`)

An earlier draft added a `cva`-like `ui.variants` (`base`/`when`/`by`/`compound`/
`defaults`/`strict`, function layers, weak caches, clone-on-return). It was
dropped: across all call sites it was used for two base-only styles, one
two-flag style and one enum, and every one reads more simply as plain tables
plus `ui.style`. Lua has no type inference or autocomplete for a spec DSL, so
the DSL hid the logic it was supposed to clarify.

### Pattern

Styles are module-level constants. The render picks layers with `and`.
`ui.style` skips falsy arguments, merges left to right (later wins) and returns
a fresh table.

```lua
local TAB = { fg = "muted", bold = false, radius = 4, padding = { x = 8, y = 3 } }
local TAB_ACTIVE = { fg = "selection_fg", bg = "selection_bg", bold = true }
local TAB_BADGED = { padding = { right = 0 } }
local TAB_ACTIVE_BADGED = { background_extend = 2 }

style = ui.style(
  TAB,
  active and TAB_ACTIVE,
  badged and TAB_BADGED,
  active and badged and TAB_ACTIVE_BADGED
)
```

What each `ui.variants` feature becomes:

| Variants feature | Plain Lua |
| --- | --- |
| `base` | first argument |
| `when = { flag = S }` | `flag and S` |
| `by = { kind = { a = S } }` | `KINDS[kind] or KINDS.default` |
| `compound` | `a and b and S` |
| `defaults` | `opts.x or "default"` (at the call site) |
| `strict` | `assert(KINDS[kind], ...)` if wanted |
| layer order | argument order (explicit, no sorting rules) |
| function layer `(theme) -> style` | the caller already has `theme`; call a local function |
| cache + clone-on-return | not needed: every `ui.style` call returns a fresh table, so `bar_events.register` writing `style.id` can't leak |

Eager resolution when a theme is in hand:
`ui.themed_style(theme, ...)` (public): merges the layers like `ui.style` and
resolves tokens in one call. With `theme = nil` it behaves exactly like
`ui.style(...)`, so tokens stay for the lazy path (which picks the right widget
palette at serialization time).

```lua
style = ui.themed_style(opts.theme, BASE, active and ACTIVE)
```

### Enum example: `button_component.button_style`

Dialog themes can be partial (tests pass `{ fg = ... }` only), and
`resolve_tokens` errors on missing keys. So the table holds theme key names and
looks them up directly instead of going through tokens:

```lua
-- Theme keys per kind. Default emphasis has no bg key: it brightens `selected_bg`.
local KINDS = {
  default = { fg = "fg", emphasized_fg = "selected_fg" },
  primary = { fg = "primary_bg", emphasized_fg = "primary_fg", emphasized_bg = "primary_bg" },
  destructive = {
    fg = "destructive_bg",
    emphasized_fg = "destructive_fg",
    emphasized_bg = "destructive_bg",
  },
}

function M.button_style(theme, btn, selected, hovered)
  local kind = KINDS[btn.kind] or KINDS.default
  local radius = theme.radius or 4
  if not (selected or hovered) then
    return { fg = theme[kind.fg], radius = radius }
  end
  local bg
  if kind.emphasized_bg then
    bg = theme[kind.emphasized_bg]
  else
    bg = color.brighten_hex_color(theme.selected_bg, 0.25, theme.panel_bg)
  end
  return { fg = theme[kind.emphasized_fg], bg = bg, bold = true, radius = radius }
end
```

The whole state table is visible at once; there is no ordering rule to learn.

---

## 6. Native `hover` in overlays

Today overlays pass `hover_state` into `render`, and each component compares
`state.hovered_id == id`. Instead:

- `ui.overlay.new` stores the hovered id on the widget (for example
  `widget._hovered_id`) alongside the existing `hover_state`. Keep that state,
  because rows still use it for row-level hover.
- `serialize_overlay_row` → for spans whose `style.id` equals the hovered id,
  merge `style.hover` over the style (same logic as `bar_events.resolve_style`).
  Extract the shared part into `shared.apply_hover(style, hovered_id)`.
- Result: `ui.action_button` no longer needs `opts.state`:

```lua
local ACTION = {
  fg = "fg",
  radius = 4,
  padding = { x = 4 },
  hover = { fg = "hover_fg", bg = "hover_bg" },
}
```

- Keep accepting `opts.state` / `opts.hover_style` on `action_button` for
  compatibility, mapping `hover_style` to `style.hover`.
- Row-level hover (`select`, `palette`, `mux_navigator` comparing `row_id`) is out of
  scope. Those rows switch their whole row fill, not span styles. Revisit later.

Hover redraw: check that an `overlay:hover` event already triggers a re-render
or re-serialize. If not, mark the widget dirty in the `on_event` wrapper.

---

## 7. Presets (`hollow.ui.styles`, optional)

Small module of plain constants built from tokens. These are the recipes that
repeat across widgets today:

```lua
local styles = {
  muted = { fg = "muted" },
  title = { fg = "title", bold = true },
  pill  = { radius = 4, padding = { x = 4 } },
  badge = { fg = "panel_bg", bold = true, radius = 4, padding = { x = 5, y = 1 } },
  kbd   = { fg = "fg", bg = "input_bg", radius = 3, padding = { x = 4 } },
}
ui.styles = styles
```

Usage: `ui.text(label, ui.styles.muted)` or
`ui.style(ui.styles.badge, { bg = color })`. Since everything is plain tables,
users can define their own the same way. Freezing isn't needed because
`ui.style` never mutates inputs. Pass presets through `ui.style` before handing
them to a span (spans may get `style.id` written in place). Document "don't
mutate presets".

---

## 8. Before / after: `ui.tab`

Before: ~45 lines with an inline style per button, `theme.` in every field and
nested ternaries.

After:

```lua
local TAB = { fg = "muted", bold = false, radius = 4, padding = { x = 8, y = 3 } }
local TAB_ACTIVE = { fg = "selection_fg", bg = "selection_bg", bold = true }
local TAB_BADGED = { padding = { right = 0 } }
local TAB_ACTIVE_BADGED = { background_extend = 2 }
local BADGE = { fg = "panel_bg", bold = true, radius = 4, padding = { x = 5, y = 1 } }

function ui.tab(opts)
  local theme = select_theme(opts)
  local active = opts.active == true
  local badge = opts.badge
  return ui.group({
    ui.button({
      id = opts.id,
      on_click = opts.on_click,
      text = badge and (opts.label .. " ") or opts.label,
      style = ui.themed_style(
        theme,
        TAB,
        active and TAB_ACTIVE,
        badge and TAB_BADGED,
        active and badge and TAB_ACTIVE_BADGED
      ),
    }),
    ui.when(badge, function()
      return {
        ui.button({
          id = opts.id .. ":badge",
          on_click = opts.on_click,
          text = tostring(badge.text),
          style = ui.themed_style(theme, BADGE, { bg = badge.color }),
        }),
        " ",
      }
    end),
  })
end
```

The render contains structure and state flags. Every visual value sits in the
constants above it.

Note on behaviour (Decision 3): built-in primitives (`ui.tab`, `ui.tab_bar`,
`ui.action_button`) keep `"select"` as their default palette, so their output
doesn't change. Each one resolves its theme once:

```lua
local function select_theme(opts)
  return opts.theme or require("hollow.theme").resolve_widget("select")
end
-- in ui.tab: local theme = select_theme(opts), then resolve tokens against `theme`
```

Tokens are therefore resolved eagerly in primitives. The lazy path is for user
code that writes `{ fg = "muted" }` without a theme in hand.

---

## 9. Decisions

1. **Token syntax: bare names** (`"muted"`). Any string starting with `#` is a
   hex color and any other string is a token. If named CSS colors are ever
   wanted, they would need a prefix of their own.
2. **Bars: widget palette plus bar keys** in one namespace. See the token table
   in §3.
3. **Primitives keep `"select"`** as their default palette and resolve tokens
   eagerly (§8). Output stays identical.
4. **Unknown token: always an error**, since no dev/release flag exists in
   `src/lua/hollow`. The message names the token, the style key and the closest
   match, for example:
   `hollow.ui: unknown style token "mutd" for fg (did you mean "muted"?)`.
   The hint is cheap (edit distance over about 30 keys). If a dev flag lands
   later, release builds switch to warn-once.

---

## 10. Phases

**Phase A: merge + tokens (foundation)**

- `shared.merge_styles` (box-aware), `ui.style` built on it.
- `shared.resolve_tokens(style, palette)` with dotted paths and strict errors.
- `style_to_segment(text, style, palette?)` with the lazy fallback, plus a palette
  cache and invalidation on theme change.
- `shared.bar_palette()`: widget `"all"` plus the bar keys from §3.
- Pass the overlay kind's palette from `overlay.lua`, the bar palette from
  `bar_serialize.lua`, and `"all"` from `core.lua`.
- Unknown-token error with a "did you mean" hint.

**Phase B: dropped** (`ui.variants` replaced by conditional `ui.style` layers, §5).

**Phase C: overlay hover**

- `shared.apply_hover`, used by both bars and overlays.
- `ui.overlay.new` records the hovered id; `serialize_overlay_row` applies hover.
- Simplify `ui.action_button` while keeping its compat options.

**Phase D: presets + migration**

- `hollow.ui.styles`.
- Migrate `ui.tab`, `ui.action_button`, `button_component.button_style`
  (`KINDS` lookup table, §5), `dialog.lua`, then widgets one commit at a time.

**Phase E: types + docs**

- `types/hollow.lua`: `HollowStyleToken` alias (`string`), widen
  `HollowStyle.fg/bg/border` to `HollowColor|HollowStyleToken`, add a `hover?:
HollowStyle` field, plus stubs for `ui.style`, `ui.themed_style` and `ui.styles`.
- `docs/reference/lua/ui.md`: a "Styles" section covering tokens (list the token
  names from `resolve_widget`), merge rules, conditional layers, hover and presets.
- `docs/themes.md`: link the token list.

---

## 11. Tests

`src/lua/tests/test_ui_composition.lua` (or a new `test_ui_styles.lua`):

- **merge**: falsy args skipped, inputs not mutated, `padding = 4` +
  `{ right = 0 }` → `{ 4, 0, 4, 4 }`, `{ x = 8 }` + `{ right = 0 }`,
  `hover` merged deeply.
- **tokens**: hex passes through, bare token resolved, dotted path resolved,
  unknown token errors with its name and a hint, non-color keys untouched.
- **bar palette**: `{ fg = "tab_active_fg" }` in a bar span resolves to
  `ui.tab_bar.active_tab.fg`, and widget tokens (`"muted"`) also resolve in bars.
- **primitives default**: `ui.tab` without `opts.theme` gives the same hex values
  as before (the `"select"` palette).
- **lazy**: `style_to_segment("x", { fg = "muted" }, palette)` gives the hex.
  Without a palette it uses the cached current theme. The cache is invalidated
  after a theme change.
- **layers**: `ui.style(A, false, B)` = `ui.style(A, B)`; later layer wins;
  result is a fresh table (mutating it leaves `A` and `B` untouched).
- **themed_style**: resolves tokens against the given theme; `nil` theme leaves
  tokens; inputs untouched.
- **overlay hover**: a span with `id` and `hover` gets hover colors only when
  that id is hovered. Bars behave as before (existing `test_ui_bars.lua`).
- **regression**: the existing tab / tab_bar test passes after migration.

---

## Checklist

- [x] Decide open questions §9
- [ ] Phase A: `merge_styles`, `ui.style`, `resolve_tokens`, lazy palette in `style_to_segment`
- [x] Phase B: dropped (conditional layers instead)
- [ ] Phase C: overlay `hover`, `apply_hover`, `action_button` cleanup
- [ ] Phase D: `ui.styles` presets, migrate `tab`, `action_button`, `button_style`, `dialog`, widgets
- [ ] Phase E: types + docs
- [ ] Tests §11
