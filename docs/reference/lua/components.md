# Layout components

`hollow.ui.components` builds trees for `hollow.ui.layout` surfaces. Render
functions run synchronously; components use the surface theme and cell metrics.
They do not own keyboard behavior beyond overlay focus (see
[Keyboard focus](#keyboard-focus)).

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
  (`solid`, the default, or `quiet`), `variant` (`default`, `primary`,
  `destructive`), `size` (`sm`, `md`), `selected`, `hovered`, and `disabled`.
  Solid buttons use `styles.button.root`; quiet buttons stay text-colored until
  hovered or selected and use `styles.button.dialog`.
- **`hints`** — one row plus two text nodes per `{ key, description }` pair.
  `separator` defaults to two spaces. A separately styled separator adds one
  node between pairs; `plain = true` uses one column and one text node.
- **`input`** — two containers plus two nodes per behavior run, and one extra
  run while an optional `placeholder` is visible. Pass
  `{ behavior = ui.text_input(...), id = "filter", boxed = false }`.
  The placeholder is display-only and appears only while the behavior's value
  is empty. Its first grapheme occupies the caret cell; the remainder is dimmed
  by blending input foreground toward input background.
  Focusable (Tab or click) unless `focusable = false`; the root takes `id`
  (default `"input"`). A picker's filter is focusable only with
  `filter_focusable = true`, since picker widgets route keys to it themselves.
  A focusable field draws a hollow (outlined) caret until it has keyboard
  focus in a focused pane, so it does not look ready for typing; pass
  `focused = true` when your widget routes keys to the field itself.
- **`tabs`** — one row plus two nodes per tab and two per painted badge.
  Pass `{ tabs = { { id = "a", label = "A" } }, active = "a", on_select = fn }`.

## Containers and lists

- **`panel`** — one node. `chrome` overrides theme chrome; `inset` is
  `overlay`, `modal`, `modal_centered` (balanced vertical padding), or `none`.
- **`header`** — one row, one title, and optional spacer/meta nodes. `title`,
  `meta`, and `prompt` compose a heading; `meta_align = "inline"` omits spacer.
- **`rich`** — one row plus inline runs. Painted or clickable runs add a
  container; a spacer adds two alignment rows. Pass inline `ui.text`,
  `ui.span`, or group nodes as children and `prefix` for generated click IDs.
  Layout nodes such as `c.button` pass through unchanged. `style` is inherited
  by the runs; `plain = true` (or more than 32 runs) collapses them into one
  text node. Without an explicit `height`, padded runs grow the row to the cell
  height plus their largest vertical padding; `c.rich.height(children)`
  returns that height for sizing viewports.
- **`list_item`** — two shell nodes, plus one for a painted accent and user
  content. `detail` adds a column and a text node. Accepts `selected`, `hovered`,
  `accent` (`true`, `false`, or a color), and `on_activate`. `label` defaults
  to child text plus string detail; set it explicitly when content needs a
  different accessibility label. `c.list_item.line_height(theme)` returns the
  height of one line.
- **`list`** — one scroll viewport plus item nodes. Requires `id`, `items`, and
  `render_item(item, index, view)`. `selected`, `viewport`, `window` (24),
  `budget` (410 item nodes), and `empty` configure windowing. The window is
  centred on the visible range and always includes the selected item. Over
  budget, the off-screen rows farthest from the selection re-render with
  `view.plain = true`; honor it to reduce overscan cost. Visible and selected
  rows remain rich, so budget is soft if those rows alone exceed it.
- **`picker`** — divided stack of header, optional input, list, and optional
  hints. Requires `id` and `list` props; accepts `title`, `counter`, `prompt`,
  `filter` (a `ui.text_input` behavior), and `hints` (hint props). `header`,
  `filter`, and `hints` also accept prebuilt layout nodes. Its node cost is the
  stack plus its child components.

## Composites

- **`dialog`** — stack with title, body, and optional quiet action buttons.
  Accepts `title`, `body`, `actions`, and `selected` (index or action ID).
  Each action accepts `id`, `text`, `kind`, `disabled`, and `on_click`.
  Optional `action_padding` sets padding for all action buttons (for example,
  `{ x = 8, y = 4 }` in pixels); `false` removes padding. Defaults remain one
  cell horizontally and zero vertically.
- **`toast`** — two nodes. Accepts `level`, `text`, and optional
  `action = { label, on_click }`; the action shares the toast click target.
  Notification paint uses `styles.notify.message` for compatibility.

## Gallery

`c.demo()` opens a scrollable gallery of every component, variant, size, and
state as an overlay above any open overlay (including the Lua REPL). It fills the window
height; the mouse wheel, arrows, `j`/`k`, Page Up/Down, and Home/End scroll by
section. Tab and Shift-Tab move focus between buttons and inputs. Esc or q
closes it. It is also rendered against every bundled theme in the test suite.

## Keyboard focus

In overlays, clickable nodes (`on_click`, so enabled buttons, list items and
tabs) and nodes with `focusable = true` (inputs) form a focus order in tree
order. Tab and Shift-Tab move focus when the overlay's own `on_key` does not
consume them. The focused node paints its hover layer plus a ring
(`focus_ring|primary_bg` token) and is revealed in its nearest scroll viewport.

A focused node sees keys before the overlay: its `on_key(key, mods)` first
(inputs route to their behavior), then Enter or Space activate `on_click`.
Unconsumed keys continue to the overlay. Clicking a button moves focus without
the ring; clicking an input focuses it for typing and shows the text cursor. Surfaces expose `focus(id)`, `blur()`, `focus_move(delta)` and
`focused_id()`.

## Migrating from inline helpers

Overlay `render` functions return a component tree. Inline helpers still work
inside `c.rich`, but the components are focusable and themed consistently:

| Inline helper                      | Component                         |
| ---------------------------------- | --------------------------------- |
| `ui.row` / `ui.column` as a root   | `c.row` / `c.column` / `c.panel`  |
| `ui.button`, `ui.action_button`    | `c.button`                        |
| `ui.tab`, `ui.tab_bar`             | `c.tabs`                          |
| `ui.text_input(...).render(theme)` | `c.input({ behavior = input })`   |
| hand-rolled scrolled rows          | `c.list` / `c.picker`             |
| `ui.span` runs with click handlers | `c.rich({ prefix = "id", ... })`  |

`hollow.ui.modal` and `hollow.ui.overlay.new` are the overlay hosts: they wrap
your tree in `c.panel` chrome, so return content, not another panel.

## Theme overrides

Recipe overrides live under `styles.<sheet>.<slot>` on the applicable widget
theme. Existing public `hollow.ui.styles` presets remain available. See
[theme](theme.md) and [UI](ui.md) for theme and surface configuration.
