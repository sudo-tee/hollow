# UI composition plan: declarative children

Goal: make writing a component's render read like a tree, not an imperative list
builder. Remove `nodes[#nodes + 1] = ...` and `if` gates from render code without
introducing a reactive runtime.

Non-goals: signals, hooks, a virtual DOM, keyed state, JSX-style call syntax.
`ui.row({ ... }, opts)` keeps its current shape.

---

## 1. Problems today

| Pattern | What happens now | Where |
| --- | --- | --- |
| `{ a, cond and b, c }` | `normalize_inline_nodes(false)` → span `"false"` | `ui.row`, `ui.group` (`primitives.lua`) |
| `{ a, cond and b or nil, c }` | `ipairs` stops at the hole, `c` silently dropped | every children loop |
| `{ a, list_of_nodes, c }` | flattened one level only; deeper lists become `tostring(table)` | `shared.normalize_inline_nodes` |
| `ui.column({ cond and row })` | hard error "children must be ui.row()" | `ui.column` |
| `ui.column({ header_rows, body_rows })` | error; callers splice by hand | `dialog.lua` `append_body_item` |
| separators between items | manual `if index > 1 then push(sep)` | `ui.tab_bar`, `dialog.lua` footer |
| conditional style fields | `x = active and a or nil` per field | `ui.tab`, `ui.action_button` |

Imperative push sites in `src/lua/hollow/ui`: `primitives.lua` (6),
`builder/components/dialog.lua` (7), `workspace/source.lua` (3),
`widgets/mux_navigator.lua` (3), `widgets/activity.lua` (2), `widgets/select.lua`,
`builder/behaviors/text_view.lua`, `builder/keys.lua`, `shared.lua` (1 each).

---

## 2. Children semantics (the core change)

One rule set, applied by every container (`ui.group`, `ui.row`, `ui.column`):

| Child value | Result |
| --- | --- |
| `nil`, `false`, `true` | skipped |
| string / number | `span` with `tostring(value)` (inline only) |
| span-like node (`span`, `icon`, `spacer`, `group`) | kept as is (inline only) |
| text shorthand `{ "txt", fg = ... }` | normalized span (inline only) |
| `row` node | kept (column only) |
| `column` node | its rows spliced in (column only) |
| plain array table (no `_type`) | **fragment**: recursively flattened in place |
| function | **not** called (keeps rendering predictable; use `ui.when` for laziness) → error |
| anything else | error naming the container and offending `_type` |

Details:

- **Holes**: iterate `for i = 1, table.maxn(list)` (LuaJIT / 5.1 has `table.maxn`),
  so `cond and x or nil` no longer truncates. `false` stays the recommended idiom.
- **Shorthand vs fragment ambiguity**: `{ "a" }` is shorthand and `{ "a", "b" }`
  is a fragment of two strings. Both render the same text, so the ambiguity is harmless.
  Shorthand detection stays `is_text_shorthand` (no `_type`, exactly one string).
- **Order** is depth-first, left to right, so it matches the old flattening exactly
  (the `tab_bar` test indexes `nodes[5]`, `nodes[6]`).
- **Inline container receiving a row** (or column receiving a span): error, e.g.
  `hollow.ui.group(): unexpected "row" node at child 3`. Today this silently
  renders `table: 0x...`, so it was never a working feature.

### Implementation (`shared.lua`)

```lua
local function collect(list, accept, label, out)
  for i = 1, table.maxn(list) do
    local child = list[i]
    local kind = type(child)
    if child == nil or kind == "boolean" then
      -- skip
    elseif kind == "table" and child._type == nil and not M.is_text_shorthand(child) then
      collect(child, accept, label, out)        -- fragment
    else
      accept(child, out, label, i)
    end
  end
  return out
end

function M.collect_inline(list, label)  -- -> HollowUiRenderableNode[]
function M.collect_rows(list, label)    -- -> HollowUiRowNode[]
```

`accept_inline`: string/number → span, shorthand → `normalize_text_shorthand`,
span-like → itself, else error. `accept_row`: row → push, column → push its
children, else error.

Use an explicit `out` parameter and no per-call closures, because bars re-render often.

### `normalize_inline_nodes` compatibility

It is also used by `bar_serialize`, `bar_events`, `select`, `nodes_plain_text`,
`highlight_inline_nodes` and `bar_value_to_segments`. Re-implement it as:

- string / number → `{ span }` (unchanged)
- `nil` / `false` → `{}` (was `{ span "" }` / `{ span "false" }`)
- span-like / shorthand → `{ node }` (unchanged)
- table → `collect_inline({ value })` but **non-erroring**: unknown nodes fall back
  to the old `tostring` span so bar/select callers with loose input don't break.

Make the error/lenient choice a flag on `collect_inline` (`strict` for primitives,
lenient for `normalize_inline_nodes`).

Check: `select` treats `detail_text == ""` as "no detail". An empty result `{}` still
gives `""` from `nodes_plain_text`, so nothing changes.

---

## 3. New helpers (`primitives.lua`)

All of them return plain values or fragments, so they work in any children list.

### `ui.when(cond, then_, else_?)`
```lua
function ui.when(cond, then_, else_)
  local v = cond and then_ or else_
  if type(v) == "function" then v = v() end
  return v or false
end
```
- A branch can be a node, a fragment, or a thunk. Use a thunk when the branch reads
  data that may be nil: `ui.when(badge, function() return badge.text end)`.
- Quirk: `cond and then_ or else_` picks `else_` when `then_` is falsy. That's fine
  here because a falsy `then_` renders nothing anyway.

### `ui.each(list, fn)`
```lua
function ui.each(list, fn)
  local out = {}
  if list == nil then return out end
  if type(list.get) == "function" then list = list:get() end  -- hollow.tbl wrapper
  for i, item in ipairs(list) do out[i] = fn(item, i) or false end
  return out
end
```
- Returns a fragment. `nil` or `false` results are skipped later by `collect`.
- The index is passed so the caller can build ids: `"tab:" .. i`.

### `ui.join(items, sep)`
- Drop falsy items **first**, then put `sep` between the rest, so gated items never
  produce doubled or leading separators.
- `sep` may be a string, a node, or `function(i) -> node` (when separators need
  ids or styles).
- Returns a fragment.

### `ui.style(...)`
> Full style design (theme tokens, box-aware merge, `ui.variants`, overlay
> hover, presets) is in `ui-styles-plan.md`. Only the basic merge lands here.

- Merges style tables left to right and skips `nil`/`false` arguments.
- Always returns a fresh table. Inputs are never mutated (themes are shared).
- Box keys (`padding`, `margin`) and `hover` are merged per key one level deep, so
  `ui.style(base, { padding = { right = 0 } })` keeps `left`, `top` and `bottom`.
- Reuse or extend `shared.merge_style_tables` instead of adding a second merger.
  Check its current semantics first.

Usage:
```lua
style = ui.style(
  { fg = theme.muted, radius = 4 },
  active and { fg = theme.selection_fg, bg = theme.selection_bg, bold = true },
  hovered and theme.hover_style
)
```

---

## 4. Container updates (`primitives.lua`)

- `ui.group(children, style)` → `children = shared.collect_inline(children or {}, "hollow.ui.group()")`.
- `ui.row(children, opts)` → same with `"hollow.ui.row()"`. Keep the guard that
  rejects a bare shorthand / span passed as `children`.
- `ui.column(children)` → `shared.collect_rows(children, "hollow.ui.column()")`.
  Nested columns and fragments of rows now splice.
- Widget `render()` normalizers (`shared.normalize_widget_rows`, both copies) stay
  strict on the *top-level* return value (`row` or `column`). Optionally also
  accept a plain list of rows by wrapping it in `collect_rows`. Decide while
  implementing.

---

## 5. Migrate internal call sites

Do one file per commit and keep the tests green. Target style:

```lua
function ui.tab(opts)
  local theme = opts.theme or require("hollow.theme").resolve_widget("select")
  local active, badge = opts.active == true, opts.badge
  return ui.group({
    ui.button({
      id = opts.id,
      text = badge and (opts.label .. " ") or opts.label,
      on_click = opts.on_click,
      style = ui.style(
        { fg = theme.muted, radius = 4,
          padding = { left = 8, right = badge and 0 or 8, top = 3, bottom = 3 } },
        active and { fg = theme.selection_fg, bg = theme.selection_bg, bold = true,
                     background_extend = badge and 2 or nil }
      ),
    }),
    ui.when(badge, function()
      return {
        ui.button({
          id = opts.id .. ":badge",
          text = tostring(badge.text),
          on_click = opts.on_click,
          style = { fg = theme.panel_bg, bg = badge.color, bold = true, radius = 4,
                    padding = { left = 5, right = 5, top = 1, bottom = 1 } },
        }),
        " ",
      }
    end),
  })
end

function ui.tab_bar(opts)
  return ui.group(ui.join(ui.each(opts.tabs, function(tab)
    local tab_opts = util.clone_value(tab)
    tab_opts.theme = tab_opts.theme or opts.theme
    return ui.tab(tab_opts)
  end), "  "))
end
```

Order:
1. `primitives.lua`: `ui.tab`, `ui.tab_bar`, `ui.action_button` (via `ui.style`).
2. `builder/components/dialog.lua`: `append_body_item` mostly collapses into
   `collect_rows`, and the footer uses `ui.join(ui.each(footer, ...), "  ")`.
   Keep the `click_registry.register` side effect inside the `each` callback.
3. `widgets/mux_navigator.lua`, `widgets/activity.lua`, `workspace/source.lua`.
4. `widgets/select.lua`, `builder/behaviors/text_view.lua`, `builder/keys.lua`.
   Only convert code that builds render trees. Leave data accumulators
   (key lists, entries) as they are.

Rule: convert only when the code reads better. Hot loops building thousands of
rows (scroll views, text view) can stay imperative.

---

## 6. Tests (`src/lua/tests/test_ui_composition.lua`)

Before any change: run `zig build test-lua` (or `scripts/test-lua.sh`) and record
the baseline.

New cases:
- `false` / `nil` / `true` children skipped in `group`, `row`, `column`.
- A hole (`a, nil, c`) keeps `c`.
- Nested fragments 3 levels deep flatten in order.
- Strings and numbers as direct children become spans.
- Shorthand `{ "x", fg = ... }` is still a leaf, not a fragment.
- `column` splices nested columns and row fragments, and errors on a span child
  with a message that includes the container name and index.
- `group` errors on a row child (strict). `normalize_inline_nodes` stays lenient.
- `normalize_inline_nodes(false)` → `{}`.
- `ui.when`: true/false, else branch, thunk only evaluated when its branch is taken.
- `ui.each`: index passed, falsy results dropped, works on a `hollow.tbl` wrapper.
- `ui.join`: no leading or trailing separator, falsy items dropped before joining,
  function separator gets its index.
- `ui.style`: skips falsy args, doesn't mutate inputs, merges `padding` per key.
- Existing `tab_bar` / badge test passes unchanged (proves ordering is preserved).
- Bars: existing `test_ui_bars.lua` passes, since `bar_events` and `bar_serialize`
  go through `normalize_inline_nodes`.

---

## 7. Types and docs

- `types/hollow.lua`:
  - Widen children params to a recursive `HollowUiChild` alias:
    `---@alias HollowUiChild HollowUiInlineNode|string|number|boolean|nil|HollowUiChild[]`
    and `HollowUiRowChild` for columns.
  - Add stubs for `ui.when`, `ui.each` (generic `fun(item: T, i: integer): HollowUiChild`),
    `ui.join`, `ui.style`, next to `ui.group` (~line 2146).
- `docs/reference/lua/ui.md`: add a "Conditional and list rendering" section with
  the children rules table from §2 and short examples of each helper.
- `docs/custom-ui.md`: update one example to use `ui.when` / `ui.each`.
- Note the behaviour change: `false` children used to render `"false"` and
  wrong-kind children now error.

---

## 8. Deferred (only if the above still feels procedural)

- `ui.component(defaults, fn)`: resolves `props.theme` and default props once per
  component. Small, and could follow right after this plan.
- `ui.match(value, { a = ..., b = ..., _ = ... })`: switch-style branching for
  multi-way variants.
- Per-component local state / hooks: needs stable ids and a render context. Out
  of scope until there's a concrete need.

---

## Checklist

- [ ] Baseline Lua tests
- [ ] `shared.collect_inline` / `collect_rows` + lenient `normalize_inline_nodes`
- [ ] `ui.group` / `ui.row` / `ui.column` use collectors
- [ ] `ui.when`, `ui.each`, `ui.join`, `ui.style`
- [ ] Tests for §6
- [ ] Migrate `primitives.lua`
- [ ] Migrate `dialog.lua`
- [ ] Migrate the remaining widgets (one commit each)
- [ ] Types + docs
