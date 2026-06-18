# `hollow.ui`

The widget runtime.
The same widget model powers the top bar, the bottom bar, sidebars,
and overlays (modals, prompts, pickers, notifications).

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
hollow.ui.row(...)                 -- row of inline nodes
hollow.ui.rows(...)                -- list of rows
hollow.ui.fragment(...)            -- nested row group
hollow.ui.button(opts)             -- clickable span

hollow.ui.tags.span(...)
hollow.ui.tags.text(...)
hollow.ui.tags.row(...)
hollow.ui.tags.rows(...)
hollow.ui.tags.group(...)
hollow.ui.tags.icon(...)
hollow.ui.tags.spacer(...)
hollow.ui.tags.button(...)
hollow.ui.tags.overlay_row(...)
hollow.ui.tags.divider(...)
```

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
  width = 600,
  height = 400,
  max_height = 600,
  chrome = { bg = "#1f1f28", border = "#3a3a52", radius = 6 },
  theme = { ... },        -- widget theme overrides
}
```

Overlays stack. The topmost overlay receives `on_key` first and can
return `true` to swallow the key. The notify, input, and select
helpers are all overlays internally.

## Built-in overlay helpers

### `hollow.ui.notify`

```lua
hollow.ui.notify.show(message, opts?)
hollow.ui.notify.info(message, opts?)
hollow.ui.notify.warn(message, opts?)
hollow.ui.notify.error(message, opts?)
hollow.ui.notify.clear()
```

Options:

```lua
{
  level = "info" | "warn" | "error" | "success",
  title = "Saved",
  ttl = 1500,                            -- ms; auto-dismiss
  action = { label = "Undo", fn = function() end },
  align = "top_right",
  backdrop = true | "#000000" | { color = "#000000", alpha = 72 },
  chrome = { ... },
  theme = { ... },
}
```

### `hollow.ui.input`

```lua
hollow.ui.input.open({
  prompt = "Rename",
  default = "value",
  width = 480, height = 80,
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
  width = 600, height = 360, max_height = 480,
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
