# `hollow.ui`

The widget runtime.
The same widget model powers the top bar, the bottom bar, sidebars,
and overlays (modals, prompts, pickers, notifications).

The [Activity Center](activity.md) combines an inbox, session history, and running
programs. `hollow.ui.activity.open({ view = "inbox" | "history" })` opens it.

For the conceptual model see [Custom UI](../../custom-ui.md).
For recipes see [UI recipes](../../examples/ui-recipes.md).
For the LuaLS schema see
[`types/hollow.lua`](../../../types/hollow.lua) (`HollowWidget`,
`HollowUiSpanNode`, `HollowUiGroupNode`, ...).

## Node primitives

```lua
hollow.ui.span(text, style?)       -- styled run of text
hollow.ui.spacer()                 -- flex spacer
hollow.ui.icon(name, style?)       -- font icon by name
hollow.ui.group(children, style?)  -- nested children

hollow.ui.text(value, style?)      -- inline shorthand
hollow.ui.row(children, opts?)     -- explicit row node
hollow.ui.column(rows)             -- explicit vertical layout
hollow.ui.divider(color?)          -- divider row
hollow.ui.button(opts)             -- clickable span
hollow.ui.action_button(opts)      -- padded action with hover styling
hollow.ui.tab(opts)                -- selectable tab with optional badge
hollow.ui.tab_bar(opts)            -- spaced group of tabs
hollow.ui.is_focused()             -- whether Hollow's window has OS focus
hollow.ui.when(cond, then_, else_)  -- choose/evaluate one child branch
hollow.ui.each(list, fn)            -- map dense list to child fragment
hollow.ui.join(items, sep)          -- join truthy children
hollow.ui.style(...)                -- merge style layers
hollow.ui.styled(theme, ...)  -- merge and resolve tokens now
```

Widget `render` functions return exactly one `row` or `column`. Rows
contain inline children and own row-level presentation and interaction:

```lua
return hollow.ui.column({
  hollow.ui.row({
    hollow.ui.text("Status", { bold = true }),
    hollow.ui.spacer(),
    hollow.ui.text("ready", { fg = "#98bb6c" }),
  }, { id = "status", fill_bg = "#1f1f28" }),
  hollow.ui.divider("#3a3a52"),
})
```

Containers are strict: `ui.row` takes inline children; `ui.column` takes rows.
Nested columns and fragments of rows are flattened by `ui.column`; nested arrays
flatten at any depth. Wrong-kind nodes error instead of being coerced. Bare
strings and numbers are inline text, but a bare string is not a row. Widget
`render` must return exactly one explicit `ui.row(...)` or `ui.column(...)`.

`nil`, booleans (`false` and `true`), and `false` branches are skipped. Lua
array literals containing `nil` have holes, but collection scans through the
highest indexed child, so later children survive. A text shorthand table such
as `{ "text", fg = "muted" }` is one inline leaf, not a child list.

### Conditional and list rendering

| Child | Inline containers (`group`, `row`) | `column` |
| --- | --- | --- |
| `nil`, `false`, `true` | Skip | Skip |
| String or number | Convert to text | Error |
| Span, icon, spacer, group | Keep | Error |
| Text shorthand | Convert to styled span | Error |
| Row | Error | Keep |
| Column | Error | Splice its rows |
| Array fragment | Flatten recursively | Flatten recursively |
| Function or other value | Error | Error |

Pass a list to `ui.row`, not a bare span or shorthand. For one string, use
`ui.row({ ui.text("text") })`; `ui.row({ "text" })` is ambiguous shorthand
and is rejected. Widget `render` does not accept anonymous lists of rows.

`ui.when` evaluates only the selected function branch; non-functions are used
as-is. Use it for optional child fragments:

```lua
ui.when(show_status, function()
  return ui.row({ ui.text("ready", ui.style(ui.styles.muted)) })
end)
```

Use `condition and node` for simple gating; use `ui.when` with a function when
constructing a branch must be lazy. Like Lua's `and/or` idiom, a false/nil
`then_` value falls through to `else_`; a selected function returning nil/false
renders nothing.

`ui.each` maps a dense `ipairs` list, returning a fragment and preserving
indices for skipped results. It accepts ordinary lists or a `hollow.tbl`
wrapper (unwrapped with `:get()`). Pass wrappers to `ui.each`, not directly to
containers.
`ui.join` drops falsy items before inserting separators. A separator function
receives the 1-based separator number:

```lua
ui.each(items, function(item, i)
  return ui.row({ ui.text(item.name), ui.when(item.active, "  active") })
end)

ui.join({ "one", false, "three" }, function(i)
  return ui.text(i == 1 and " · " or " / ", ui.style(ui.styles.muted))
end)
```

`ui.action_button` is an opt-in overlay button with horizontal padding, rounded
corners, and select-theme colors. Pass the modal render `theme` to match the
surrounding widget; hover needs no render state. `style` overrides normal defaults;
`hover_style` overrides hover defaults. Like `ui.button`, a clickable action needs
a stable `id`.

`state` remains accepted for compatibility; native overlay hover now applies
the style's `hover` layer. Legacy `style.padding` and `hover_style.padding`
replace the whole padding box rather than merging sparse edges.

```lua
render = function(theme)
  return hollow.ui.row({ hollow.ui.action_button({
    id = "example:copy", text = "Copy", theme = theme,
    on_click = copy,
  }) })
end
```

`ui.tab_bar` composes tabs into an inline group for use in a row. Each tab has a
stable `id`, `label`, `active` state, and optional `on_click` and `badge`. Active
tabs include the badge text inside their highlight; inactive tabs display a
separate badge. Pass `theme` to match the surrounding modal.

```lua
ui.tab_bar({ theme = theme, tabs = {
  { id = "inbox", label = "Inbox", active = true,
    badge = { text = 3, color = theme.title }, on_click = open_inbox },
  { id = "history", label = "History", on_click = open_history },
} })
```

### Read-only text view

`ui.text_view` is a composable behavior, not another modal. It wraps plain text,
preserves paragraph breaks, and supports arrows, `j`/`k`, Home/End, page keys,
mouse-wheel scrolling, and a draggable scrollbar.

```lua
local view = hollow.ui.text_view({
  text = "Long message...", width = 80, row_budget = 16, id = "message",
})
-- In an existing modal:
-- render: compose view.render(theme), a list of row nodes, into your column
-- keys: view.keys(key, mods)
-- on_event: view.on_event(name, payload)
view.set("Replacement text") -- resets scrolling
```

Width is measured in terminal display cells, so wide characters such as CJK
and emoji count as two; grapheme clusters are never split. Whitespace within each paragraph is normalized.

### Span style

A span style is a table with any of:

```lua
{ fg = "#dcd7ba", bg = "#1f1f28", bold = true, italic = true,
  underline = true, strikethrough = true, dim = true,
  id = "my-id",                          -- click target
  on_click = function(e) ... end,
  on_mouse_enter = function(e) ... end,
  on_mouse_leave = function(e) ... end,
  hover = { fg = "#a0bfee" } }
```

A bare color string is accepted in shorthand: `hollow.ui.span("x", "#7e9cd8")`.

Overlay spans also support pixel padding, e.g.
`{ bg = "#1f1f28", radius = 4, padding = { x = 8, y = 3 } }`.
Numeric padding applies to all edges; tables accept `top`, `right`, `bottom`,
`left`, or `x`/`y` shorthands. Padding contributes to row size, right alignment,
and click targets, so padded pills do not overlap adjacent rows.

## Bar items

```lua
hollow.ui.bar.tabs(opts?)
hollow.ui.bar.workspace(opts?)
hollow.ui.bar.time(fmt, opts?)
hollow.ui.bar.key_legend(opts?)
hollow.ui.bar.custom({ id?, render, on_click?, on_mouse_enter?, on_mouse_leave? })
```

Bar items are reusable by all bar surfaces. See
[Top bar](#top-bar) and [Bottom bar](#bottom-bar).

## Styles

Style color fields `fg`, `bg`, and `border` accept hex colors or theme tokens.
The same applies recursively to those fields inside `hover`; non-color fields are
never interpreted as tokens. Dotted paths work, for example
`notify_levels.warn`. Unknown tokens error and include a closest-token hint.
Lazy token lookup uses the widget kind's palette, or `"all"` when no specific kind
is available. Overrides from `theme.ui.widgets.all` and that widget kind apply;
bar items additionally receive bar tokens. Bar tab part fields `close_fg`,
`close_bg`, `close_hover_fg`, and `close_hover_bg` also accept those tokens. If a render holds a custom theme,
use `ui.styled(theme, ...)` so it takes precedence over lazy lookup.

Default widget tokens available from `theme.resolve_widget(...)`:

`panel_bg`, `panel_border`, `divider`, `title`, `fg`, `muted`, `input_bg`,
`input_fg`, `cursor_bg`, `cursor_fg`, `selected_bg`, `selected_detail_bg`,
`selected_fg`, `selection_bg`, `selection_fg`, `button_emphasis_bg`, `hover_bg`, `hover_fg`, `primary_bg`, `primary_fg`,
`destructive_bg`, `destructive_fg`, `selected_muted`, `detail`, `notify_fg`,
`counter`, `empty`, `scrollbar_track`, `scrollbar_thumb`, and
`notify_levels.info`, `notify_levels.warn`, `notify_levels.error`,
`notify_levels.success`. `backdrop` is a structured backdrop value, not a color
token. `subtle` is not a default widget token; it exists only in the custom
mux-navigator palette.

Bar palette adds `bar_bg` from `theme.ui.top_bar.background`, `bar_fg` from
`theme.ui.status.fg`, `status_bg`/`status_fg` from `theme.ui.status`,
`tab_bar_bg` from `theme.ui.tab_bar.background`, `tab_active_fg`/`tab_active_bg`
from `active_tab`, `tab_inactive_fg`/`tab_inactive_bg` from `inactive_tab`,
`tab_hover_fg`/`tab_hover_bg` from `hover_tab`, and `accent`/`warm` from
`theme.ui`.

`ui.style(...)` merges left to right into a fresh table; `nil` and `false`
layers are skipped. `padding` and `margin` merge by normalized edge, including
sparse overrides; nested `hover` styles merge recursively. Keep shared styles
as constants and combine conditional layers with `and`:

```lua
local BASE = { fg = "muted", padding = { x = 8, y = 3 } }
local ACTIVE = { fg = "selected_fg", bg = "selected_bg" }
local style = ui.style(BASE, active and ACTIVE)
```

`ui.styled(theme, ...)` applies the same merge and eagerly resolves
tokens against supplied theme. With `theme == nil`, it behaves like `ui.style`
and leaves tokens for normal rendering-time resolution. `style.hover` is
applied by overlay rendering when an identified node is hovered. Give overlay
spans a non-empty `style.id`, or use `ui.button({ id = ..., ... })`. Bars may
assign automatic ids. Row-level hover remains controlled separately through
row options/state.

```lua
ui.button({
  id = "example:run",
  text = "Run",
  style = ui.style({ fg = "fg", hover = { fg = "hover_fg", bg = "hover_bg" } }),
  on_click = run,
})
```

### Component styling

`ui.styled(theme, ...)` remains the public style helper. Recipes are internal;
plugins customize instances with normal style tables. These helpers, button
variants/sizes, row selection and documented palette parts are the customization
surface; `hollow.ui.shared` and computed-style/host records are private.
See the [runnable example](../../../examples/ui-styling.lua) for a complete
modal using buttons, tabs, selectable rows and theme-owned panel chrome.

```lua
ui.button({
  id = "build", text = "Build", variant = "primary", size = "sm",
  disabled = building, on_click = build,
  style = { padding = { right = 10 } },
})

ui.row({ ui.text("Build results") }, {
  id = "result-row", variant = "selectable", selected = selected,
  style = { radius = 6, hover = { bg = "hover_bg" } },
})
```

Button variants are `default`, `primary`, `destructive`, and `ghost`. Sizes
are `sm` (6×2 pixel padding) and `md` (8×3). Specifying a variant or size opts a
raw `ui.button` into the select-palette recipe; otherwise its original raw style
behavior is preserved. `opts.theme` can supply a partial palette.
`ui.action_button` accepts the same variant, size and disabled options while
retaining its original padding defaults and override rules. Disabled buttons
suppress click/hover callbacks and hover paint. They do not introduce a new
keyboard-navigation model.

Selectable overlay row recipes resolve model selection above pointer hover;
explicit instance styles remain final overrides. Row
styles accept `fg`, `bg`, `bold`, `radius`, and `hover`. Only `fg`/`bold` inherit
into text. Legacy `fill_bg` and `fill_radius` take precedence over `style`;
`accent_bar` stays a separate part; explicit `false` suppresses it. Unsupported row geometry fields error;
continue using segment padding for row content spacing. Sidebar rows share these text rules and the same background/radius/accent/divider
paint. Their original positioning and segment-array representation are retained.

Overlay widget `style` can supply surface paint and spacing. Explicit `chrome`
fields win; their boxes replace the entire corresponding style box. Both accept
color tokens using the widget palette. Bar pixel boxes share the same
normalization rules; span padding continues to support fractional pixels.

The internal state resolver orders hover, selection, pressed, focus-visible,
disabled, then explicit instance overrides. Pressed and focus-visible remain
internal until actual event owners supply those states. No public selector,
recipe-registration or general variants API is introduced.

### Surface and native part paint

Bars and overlay chrome share surface color and integer-pixel normalization.
Sidebar surfaces accept `fg`, `bg`, `border` and background `alpha` through
`sidebar.new({ style = ... })`; sidebar width, reserve and side are independent.
Unsupported sidebar surface geometry fields error.

`theme.ui.widgets.all.parts` and per-widget `parts` overrides own default paint
for sidebar surfaces, raw tab active/inactive colors and their selection stripe,
scrollbars and selected-row accents. Defaults preserve previous colors. For
example, bind sidebar colors to the current widget palette:

```lua
hollow.config.set({ theme = { ui = { widgets = { all = { parts = {
  sidebar = { bg = "panel_bg", fg = "fg", border = "panel_border" },
} } } } } })
```

Tab part `active`/`inactive` support `fg` and `bg`, plus a top-level
`selection_accent` color. Bar `style.selection_accent` overrides the unrounded
active-tab stripe when that stripe would already be drawn. Fallback colors never
supply layout or suppress explicit instance paint. Scrollbar `track`/`thumb`
parts remain separate from text; explicit scrollbar color options win.
Built-in Clay lists keep their semantic scrollbar tokens. Row-paint metadata
continues to serve sidebar rows, not overlay geometry.
`parts.list_row.accent` supplies selectable-row accents and built-in selection
indicator colors; it accepts a literal color, token, or `false`. Per-row
`accent_bar` wins, including `false` to suppress the accent.
See [the internal presentation contract](../../ui-computed-style.md) for
compatibility record mappings and remaining native safety fallbacks.

### Compatibility precedence

These are the existing rules preserved during styling unification:

- `ui.style` uses the last supplied value for ordinary fields, merges box
  edges and nested `hover`, skips `nil`/`false` layers, and preserves explicit
  `false` field values. A `nil` field is absent, not a request to clear an
  earlier layer.
- `ui.action_button` starts with the select palette (or the supplied
  `opts.theme`). `opts.style` replaces ordinary fields and whole padding boxes;
  its `hover` table merges over the default hover. Legacy `opts.hover_style`
  wins over that hover table, and its padding replaces the whole hover box.
  Tokens in these overrides resolve against the same palette.
- Hover on an identified span overrides its base style only while that span
  is hovered in bar/sidebar adapters. Clay overlays publish native `hover_bg`
  paint instead of reserializing spans on hover. List rows use a separate state policy: selected paint
  wins over hovered paint, followed by the default row background.
- `ui.button` copies styles before assigning `opts.id` and event callbacks;
  those explicit options win over event fields in the supplied style.

These rules describe today's API, not a new recipe or state API. The baseline
fixtures in `src/lua/tests/test_ui_style_baseline.lua` lock row paint and action
segment geometry/paint across normal, hovered and selected states. They run
through Clay snapshots and bar serialization; native drawing still needs visual QA.

Built-in presets are plain style tables: `ui.styles.muted`, `.title`, `.pill`,
`.badge`, `.kbd`. Treat them as constants; derive modified styles with
`ui.style(ui.styles.badge, { bg = color })` or `ui.styled(...)` rather
than mutating a preset. Pass a fresh copy to spans, for example
`ui.text("ready", ui.style(ui.styles.muted))`: bar registration may write ids
into private node styles. Automatic IDs no longer mutate the source style table.

| Preset | Recipe |
| --- | --- |
| `muted` | `fg = "muted"` |
| `title` | `fg = "title"`, bold |
| `pill` | Radius 4, horizontal padding 4 |
| `badge` | `fg = "panel_bg"`, bold, radius 4, padding x=5/y=1 |
| `kbd` | `fg = "fg"`, `bg = "input_bg"`, radius 3, horizontal padding 4 |

### Compatibility notes

- `nil`/boolean children are skipped; nested arrays flatten; wrong-kind
  children in strict containers now error.
- `ui.column` accepts nested columns and row fragments; inline anonymous
  arrays are not themselves rendered as a row.
- Non-hex strings in `fg`/`bg`/`border` now mean tokens; unknown names error.
- Internal `normalize_inline_nodes(nil | false)` now returns an empty list.
- Overlay span `style.hover` is now honored.

## Top bar

```lua
hollow.ui.topbar.configure(opts?)  -- tweak the shipped bar
hollow.ui.topbar.new(opts)          -- build a fresh widget
hollow.ui.topbar.mount(widget)      -- take over the surface
hollow.ui.topbar.unmount()          -- restore defaults
hollow.ui.topbar.invalidate()       -- redraw
```

`configure` is for partial tweaks; the shipped top bar stays put.
`mount` is for a complete replacement.

## Bottom bar

```lua
hollow.ui.bottombar.new(opts)
hollow.ui.bottombar.mount(widget)
hollow.ui.bottombar.unmount()
hollow.ui.bottombar.invalidate()
```

## Sidebar

```lua
hollow.ui.sidebar.new(opts)
hollow.ui.sidebar.mount(widget)
hollow.ui.sidebar.unmount()
hollow.ui.sidebar.toggle()
hollow.ui.sidebar.invalidate()
```

Sidebar options:

```lua
{
  side = "left" | "right",
  width = 32,           -- in terminal columns
  reserve = false,      -- if true, shrinks the tiled layout
  hidden = false,
  render = function(ctx) ... end,
}
```

Sidebar spans take the same `id`, `on_click`, `on_mouse_enter`,
`on_mouse_leave` and `hover` fields as bar spans. They emit `sidebar:hover`,
`sidebar:leave` and `sidebar:click`.

## Overlays

```lua
hollow.ui.overlay.new(opts)
hollow.ui.overlay.push(widget)
hollow.ui.overlay.pop()
hollow.ui.overlay.clear()
hollow.ui.overlay.depth()    -- integer
```

Overlay options:

```lua
{
  render = function(ctx) ... end,
  on_key = function(key, mods) return true end, -- return true to swallow
  on_mount = function() end,
  on_unmount = function() end,
  align = "center",       -- or any HollowOverlayAlign
  backdrop = true | "#000000" | { color = "#000000", alpha = 72 },
  width = 60,           -- terminal columns
  height = 20,          -- terminal rows
  max_height = 30,
  chrome = { bg = "#1f1f28", border = "#3a3a52", radius = 6 },
  theme = { ... },        -- widget theme overrides
}
```

Overlays stack. The topmost overlay receives `on_key` first and can
return `true` to swallow the key. The notify, input, and select
helpers are all overlays internally.

Notifications, modals, and direct overlays use independent positioning stacks:
showing or dismissing a notification does not move a picker or dialog.

## Composition helpers

Stateful composition helpers live beside the render primitives on
`hollow.ui`. Built-in dialogs use the same API.

### `hollow.ui.modal(spec)`

Creates and pushes an overlay, returns a handle with `.close()` and
`.invalidate()`. Handles hover/click dispatch automatically. Only one modal is
mounted at a time: while one is open, new modal requests are ignored and return
`nil`. The current modal keeps its input and selection. This also applies to
built-in pickers and dialogs; notifications and direct overlays remain independent.

```lua
local m = hollow.ui.modal({
  theme  = theme,              -- resolved theme table or widget name
  render = function(theme, state, ctx)
    return hollow.ui.layout.column({
      hollow.ui.layout.text("Custom dialog", { fg = theme.fg }),
      hollow.ui.layout.button({ id = "save", text = "Save", on_click = save }),
    }, { width = "grow", gap = 8 })
  end,
  width   = 50,
  height  = nil,
  chrome  = ...,
  align   = "center",
  backdrop = true,
  keys    = hollow.ui.keys(...), -- optional key handler
  on_event = function(name, payload) end,  -- optional raw events
})
if m then m.close() end
```

`state` tracks hover state: `state.hovered_id` is the id of the
currently hovered node or `nil`.
Set `semantic_hover = true` when render output depends on this state. Native
background hover needs no Lua snapshot rebuild. `render` returns a Clay tree;
optional second result is preferred content height in pixels. Existing width,
height and max-height options use cells/rows. No backend or layout selector exists.

### Behaviors

Behaviors encapsulate state and key handlers.  Each exposes a
`.handlers` table consumed by `hollow.ui.keys(...)`.

**`hollow.ui.list_nav(n)`** — Cyclical list navigation.

```lua
local nav = hollow.ui.list_nav(3)
nav.index                    -- current selection (1-based)
nav.next()                   -- wraps at end
nav.prev()                   -- wraps at start
nav.move(2)                  -- relative jump
nav.first() / nav.last()
nav.resize(5)                -- change item count
nav.handlers                 -- { ["tab|arrow_right"] = fn, ["shift_tab|arrow_left"] = fn }
```

**`hollow.ui.scroll_nav(n, opts?)`** — Scrolled list navigation with
page-up/down, home, end, and visible-range calculation.

```lua
local nav = hollow.ui.scroll_nav(0, { row_budget = 16 })
nav.index
local s, e, show_bar, thumb = nav:visible_range(items, budget)
nav.page_up() / nav.page_down()
nav.handlers  -- page_down, page_up, home, ["end"]
```

**`hollow.ui.text_input(opts?)`** — Single-line text input with cursor.

```lua
local input = hollow.ui.text_input({ initial = "", on_change = function(val) end })
input.value            -- current text
input.cursor           -- 0-based byte offset
input.render(theme)    -- returns { before, cursor, after } nodes
input.set("text", #"text")
input.handlers         -- arrow_left, arrow_right, backspace, _else
```

### Components

Compose custom overlays with `hollow.ui.layout.column`, `row`, `text` and
`button`. Inline `ui.row`/`ui.column` payloads remain for bars, sidebars and rich
list labels, not direct overlay render roots. See [Clay layout](../../clay-layout.md).

### Key composition

**`hollow.ui.keys(...)`** merges behaviors and raw handler tables into a
single `function(key, mods)` suitable for overlay `on_key`.

```lua
hollow.ui.keys(nav, input, {
  enter = function()
    m.close()
    hollow.ui.fire(opts.on_confirm, input.value)
  end,
  escape = function()
    m.close()
    hollow.ui.fire(opts.on_cancel)
  end,
})
```

Each arg is either a behavior (its `.handlers` are extracted) or a raw
`{ key = fn }` table.  Later entries win on conflict.
Supports pipe-separated aliases (`"tab|arrow_right"`),
`<C-r>` / `<C-S-enter>` syntax, and `_else` catch-all.

### `hollow.ui.fire(fn, value)`

Calls `fn(value)` if `fn` is a function, otherwise no-ops.

## Built-in overlay helpers

### `hollow.ui.notify`

```lua
hollow.ui.notify.show(message, opts?)
hollow.ui.notify.info(message, opts?)
hollow.ui.notify.warn(message, opts?)
hollow.ui.notify.error(message, opts?)
hollow.ui.notify.clear(notification_id?)
```

Options:

```lua
{
  level = "info" | "warn" | "error" | "success",
  title = "Saved",
  ttl = 1500,                            -- ms; auto-dismiss
  id = "build",                         -- replace or clear matching toast
  action = { label = "Undo", fn = function() end },
  align = "top_right",
  backdrop = true | "#000000" | { color = "#000000", alpha = 72 },
  chrome = { ... },
  theme = { ... },
}
```

Calling `hollow.ui.notify.clear()` clears all toasts.
Pass an ID to clear only toast with matching `id`.

### `hollow.ui.input`

```lua
hollow.ui.input.open({
  prompt = "Rename",
  default = "value",
  width = 48, height = 8,
  backdrop = ...,
  chrome = ...,
  theme = ...,
  align = "center",
  on_confirm = function(value) end,
  on_cancel = function() end,
})
hollow.ui.input.close()
```

`Enter` confirms, `Escape` cancels, `Backspace` deletes, printable
keys append. A visible caret is rendered.

### `hollow.ui.confirm`

```lua
hollow.ui.confirm.open({
  prompt = "Are you sure?",
  title = "Delete file",
  buttons = {
    { text = "Save", style = "primary", value = "save", on_confirm = function(value) end },
    { text = "Cancel", value = "cancel", on_confirm = function() end },
  },
  on_confirm = function(value) end,
  on_cancel = function() end,
  width = 50,
  backdrop = ...,
  chrome = ...,
  theme = ...,
  align = "center",
})
hollow.ui.confirm.close()
```

A modal confirmation dialog with configurable buttons.  `Tab`/arrow
keys cycle focus, `Enter` confirms the focused button, `Escape`
triggers the cancel handler.

Options:

```lua
{
  prompt  = "Are you sure?",                 -- required
  title   = "Delete file",                   -- optional header
  buttons = {                                -- default: Yes (primary), No
    { text = "Yes", style = "primary", value = true },
    { text = "No",  value = false },
  },
  on_confirm = function(value) end,          -- global, always called first
  on_cancel   = function() end,
  width      = 50,
  height     = nil,
  backdrop   = ...,
  chrome     = ...,
  theme      = ...,
  align      = "center",
}
```

The global `on_confirm` fires before the button-local `on_confirm`.
Default buttons have no per-button handler; only the global callback
runs.  Each button's `style` can be `"default"`, `"primary"`, or
`"destructive"`.

### `hollow.ui.select`

```lua
hollow.ui.select.open({
  items = { ... },
  label = function(item) return item.name end,
  search_text = function(item) return item.name end,
  detail = function(item) return item.desc end,
  prompt = "Workspaces",
  query = "",
  fuzzy = true,
  width = 60, height = 20, max_height = 30,
  backdrop = ...,
  chrome = ...,
  theme = ...,
  actions = {
    { name = "open",  desc = "open",  fn = function(item) end, key = "<Enter>" },
    { name = "rename", desc = "rename", fn = function(item) end, key = "<C-r>" },
  },
  on_cancel = function() end,
})
hollow.ui.select.close()
```

Labels and details can be plain strings, span nodes, or shorthand
`{ "text", fg = "...", bold = true }` tables. `search_text` controls
which string the filter matches against; if omitted, the rendered
`label` is used.

`items` may also be a function returning a list. Live providers and their labels
are refreshed on each render, preserving the filter and selected row index.
Keep providers nonblocking and return a stable order; do not scan files or run
processes from them.

The first action is the primary action bound to `Enter` (or whatever
key you put in `actions[1].key`).

## Workspace switcher

See [`hollow.ui.workspace`](workspace.md).

## Widget context

`render(ctx)` receives:

```lua
ctx = {
  term = {
    tab        = HollowTab | nil,
    pane       = HollowPane | nil,
    tabs       = HollowTab[],
    workspace  = HollowWorkspace | nil,
    workspaces = HollowWorkspace[],
  },
  size = { rows = integer, cols = integer, width = integer, height = integer },
  time = { epoch_ms = integer, iso = string },
}
```

## Widget lifecycle

```lua
widget = {
  render    = function(ctx) ... end,        -- required
  on_event  = function(name, e) ... end,    -- clicks, lifecycle
  on_key    = function(key, mods) ... end,  -- overlays only
  on_mount  = function() end,
  on_unmount = function() end,
}
```

`on_event` is called for click events on nodes with `id` set, and for
lifecycle events (`mount`, `unmount`).

## See also

- [Custom UI](../../custom-ui.md) — widget patterns
- [UI recipes](../../examples/ui-recipes.md)
- [Themes](../../themes.md) — widget theme tokens
