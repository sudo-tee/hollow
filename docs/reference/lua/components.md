# Layout components

`hollow.ui.components` builds trees for `hollow.ui.layout` surfaces. Render
functions run synchronously; components use the surface theme and cell metrics.
They do not own input, focus, or keyboard behavior.

```lua
local ui = hollow.ui
local c = ui.components

local surface = ui.layout.new({
  render = function()
    return c.panel({
      c.header({ title = "Tasks", meta = "2" }),
      c.hints({ { "Enter", "open" }, { "Esc", "close" } }),
    })
  end,
})
surface:show()
```

Named fields are props; numeric fields are children. Fragments, holes, and
`false` children are supported. Container props include `id`, `label`, `role`,
`width`, `height`, minimum and maximum sizes, `padding`, `gap`, `style`, and
`on_click`. Clickable nodes require an ID unique within their surface. Set
`disabled` on interactive components to suppress their callbacks.

Sizing, gap, and padding accept pixel numbers or cell units such as `"1ch"`
(cell width) and `"0.5lh"` (cell height). `width` and `height` also accept
`"fit"` and `"grow"`. Padding accepts a scalar, CSS-order array, axis fields
(`x`, `y`), or individual sides. Components with a `theme` prop accept an
explicit palette; otherwise they use the render scope.

Node costs below exclude user-supplied children. A surface supports at most 512
serialized nodes. Backgrounds and click targets on text need a container.

## Layout

- **`row` / `column`** — one node. Use `c.row({ width = "grow", child })` or
  the compatible `c.row({ child }, { width = "grow" })` form.
- **`text`** — one node. Accepts `(value, style, opts)` or
  `{ text = value, style = style, wrap = "none" }`.
- **`spacer()`** — one growing-width node.
- **`gap(n)`** — one fixed-width node; use `gap({ height = n })` vertically.
- **`stack`** — one node. `direction` is `"row"` or `"column"`; `divided`
  draws borders between children.
- **`scroll`** — one node. Requires `id`; accepts `axis`, `reveal`,
  `reveal_start`, `measure`, and `scrollbar = { id, ratio, size }`. Visible
  scrollbars reserve a right gutter. Scrollbar colors can be overridden with
  `track_color` and `thumb_color`.
- **`when`, `each`, `join`** — aliases of the inline helpers; no nodes.

## Text and painted atoms

- **`label`** — one text node. String or `{ text, tone, wrap, style, theme }`;
  tones are `default`, `muted`, `title`, `empty`, and `counter`.
- **`title`** — one text node; title tone and bold by default.
- **`empty`** — one text node; empty tone by default.
- **`icon`** — one text node. Pass an icon name or `{ name, tone, style }`.
- **`badge`** — two nodes. Accepts `text` and `color` background override.
- **`pill`** — two nodes. Accepts `text`, `fg`, and `bg`.
- **`kbd`** — two nodes. Accepts `key` and normalizes recognized chords.
- **`progress`** — one custom-paint node: `c.progress(value, opts)`.

Text atoms default to `wrap = "none"`. Style colors may be theme tokens or hex
colors. Recipe-backed atoms accept component theme overrides.

## Controls

- **`button`** — two nodes. Accepts `text`, `id`, `on_click`, `appearance`
  (`solid` or `quiet`), `variant`, `size`, `selected`, `hovered`, and
  `disabled`. Explicit `appearance = "solid"` applies the solid recipe;
  calls without appearance, variant, size, or state retain legacy raw paint.
- **`hints`** — one row plus two text nodes per `{ key, description }` pair.
  `separator` defaults to two spaces. A separately styled separator adds one
  node between pairs; `plain = true` uses one column and one text node.
- **`input`** — two containers plus two nodes per behavior run. Pass
  `{ behavior = ui.text_input(...), id = "filter", boxed = false }`.
  The existing positional form remains supported during migration.
- **`tabs`** — one row plus two nodes per tab and two per painted badge.
  Pass `{ tabs = { { id = "a", label = "A" } }, active = "a", on_select = fn }`.

## Containers and lists

- **`panel`** — one node. `chrome` overrides theme chrome; `inset` is
  `overlay`, `modal`, or `none`.
- **`header`** — one row, one title, and optional spacer/meta nodes. `title`,
  `meta`, and `prompt` compose a heading; `meta_align = "inline"` omits spacer.
- **`rich`** — one row plus inline runs. Painted or clickable runs add a
  container; a spacer adds two alignment rows. Pass inline `ui.text`,
  `ui.span`, or group nodes as children and `prefix` for generated click IDs.
- **`list_item`** — two shell nodes, plus one for a painted accent and user
  content. `detail` adds a column and a text node. Accepts `selected`, `hovered`,
  `accent`, and `on_activate`; supply `label` for accessibility.
- **`list`** — one scroll viewport plus item nodes. Requires `id`, `items`, and
  `render_item(item, index, view)`. `selected`, `viewport`, `window` (24),
  `budget` (410 item nodes), and `empty` configure windowing. Honor
  `view.plain` to reduce overscan cost. Visible and selected rows remain rich,
  so budget is soft if those rows alone exceed it.
- **`picker`** — divided stack of header, optional input, list, and optional
  hints. Requires `id` and `list` props; accepts `title`, `counter`, `filter`,
  and `hints`. Its node cost is the stack plus its child components.

## Composites

- **`dialog`** — stack with title, body, and optional quiet action buttons.
  Accepts `title`, `body`, `actions`, and `selected` (index or action ID).
  Each action accepts `id`, `text`, `kind`, `disabled`, and `on_click`.
- **`toast`** — two nodes. Accepts `level`, `text`, and optional
  `action = { label, on_click }`; the action shares the toast click target.
  Notification paint uses `styles.notify.message` for compatibility.

## Theme overrides

Recipe overrides live under `styles.<sheet>.<slot>` on the applicable widget
theme. Existing public `hollow.ui.styles` presets remain available. See
[theme](theme.md) and [UI](ui.md) for theme and surface configuration.
