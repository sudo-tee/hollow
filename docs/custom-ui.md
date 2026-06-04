# Custom UI

Hollow exposes a small widget runtime.
The same widget model powers the top bar, the bottom bar, sidebars, and
overlays (modals, prompts, pickers, notifications).

For the API see [`hollow.ui`](reference/lua/ui.md).
For recipes see [UI recipes](examples/ui-recipes.md).

## Mental model

A widget is a table:

```lua
{
  render = function(ctx) ... end,   -- required
  on_event = function(name, e) ... end, -- optional
  on_key   = function(key, mods) ... end, -- overlays only
  on_mount = function() ... end,    -- optional
  on_unmount = function() ... end,  -- optional
  height = 24,                      -- bars
  width  = 200,                     -- sidebars / overlays
  side   = "left",                  -- sidebars
  align  = "top_right",             -- overlays
  backdrop = true,                  -- overlays
  chrome = { bg = "#1f1f28", border = "#3a3a52" },  -- overlays
}
```

`render(ctx)` returns a list of nodes (or rows of nodes).
The runtime draws the widget, then delivers `on_event` callbacks for
clicks and lifecycle events.

`ctx` provides:

- `ctx.term.tab`, `ctx.term.pane`, `ctx.term.tabs`
- `ctx.term.workspace`, `ctx.term.workspaces`
- `ctx.size` (window size in pixels)
- `ctx.time.epoch_ms` and `ctx.time.iso`

## Node primitives

Four primitive nodes cover almost everything:

```lua
hollow.ui.span(text, style?)     -- a styled run of text
hollow.ui.spacer()               -- a flex spacer (pushes siblings apart)
hollow.ui.icon(name, style?)     -- a font icon by name
hollow.ui.group(children, style?) -- nested children
```

A shorthand for inline colored text is `hollow.ui.text(value, style?)`,
and `hollow.ui.row(...)` and `hollow.ui.rows(...)` build row lists.

A span style is a table:

```lua
{ fg = "#dcd7ba", bg = "#1f1f28", bold = true, italic = true, underline = true,
  strikethrough = true, dim = true, id = "my-id", on_click = function() end }
```

`id` plus `on_click` makes a node clickable. The runtime delivers the
event as `on_event("click", { id = "my-id", ... })`.

## The four surfaces

### Top bar

The top bar is the always-on status strip above the panes.
The shipped base config configures it; you can either tweak via
`hollow.ui.topbar.configure({...})` or replace it entirely with
`hollow.ui.topbar.mount(widget)`.

```lua
hollow.ui.topbar.configure({
  workspace = true,    -- or a { format, style } table
  tabs      = true,
  cwd       = true,
  key_legend = false,
  time      = { format = "%H:%M:%S" },
  height    = 24,
})

-- or full replacement:
hollow.ui.topbar.mount(hollow.ui.topbar.new({
  render = function(ctx)
    return {
      hollow.ui.workspace.topbar_button({ text = " workspaces " }),
      hollow.ui.spacer(),
      hollow.ui.bar.time("%H:%M"),
    }
  end,
}))
```

Bar-level primitives live under `hollow.ui.bar` and can be reused by
other bars:

```lua
hollow.ui.bar.tabs()
hollow.ui.bar.workspace()
hollow.ui.bar.time("%H:%M")
hollow.ui.bar.key_legend()
hollow.ui.bar.custom({ id = "weather", render = function(ctx) ... end })
```

### Bottom bar

A second status strip at the bottom of the window. Same widget model as
the top bar.

```lua
hollow.ui.bottombar.mount(hollow.ui.bottombar.new({
  height = 22,
  render = function() return { hollow.ui.bar.time("%H:%M") } end,
}))
```

### Sidebar

A side panel. Can be left or right, fixed width, and optionally reserves
terminal space (shrinks the tiled layout) instead of drawing over it.

```lua
hollow.ui.sidebar.mount(hollow.ui.sidebar.new({
  side   = "right",
  width  = 32,         -- in terminal columns
  reserve = false,     -- true: shrinks the tiled layout
  hidden = false,
  render = function(ctx)
    return {
      hollow.ui.row({ hollow.ui.text("title", { bold = true, fg = "#7e9cd8" }) }),
      hollow.ui.row({ hollow.ui.text(ctx.term.pane.cwd or "", { fg = "#727169" }) }),
    }
  end,
}))
```

### Overlays

A modal stack. Overlays receive `on_key(key, mods)` before normal
keymaps, so they can swallow keys.

```lua
hollow.ui.overlay.push(hollow.ui.overlay.new({
  align = "center",
  backdrop = { color = "#000000", alpha = 96 },
  chrome = { bg = "#1f1f28", border = "#3a3a52", radius = 6 },
  width = 600,
  render = function(ctx) return { ... } end,
  on_key = function(key, mods)
    if key == "<Esc>" then
      hollow.ui.overlay.pop()
      return true
    end
  end,
}))
```

Built on top of overlays:

- `hollow.ui.notify.show / .info / .warn / .error / .clear`
- `hollow.ui.input.open / .close`
- `hollow.ui.select.open / .close`

These accept `align`, `backdrop`, `chrome`, `theme`, `width`, and
`height` options. The notify family auto-dismisses after `ttl`
milliseconds.

## Widget theming

Widgets read colors from the active theme.
`theme.widgets.all` is the shared palette for all built-in widgets; each
widget can also override per-kind (e.g. `theme.widgets.select`).

```lua
hollow.ui.select.open({
  items = { "pwsh", "wsl" },
  theme = {
    panel_bg = "#1f1f28",
    selected_bg = "#2d4f67",
    fg = "#dcd7ba",
  },
  chrome = { bg = "#1f1f28", border = "#3a3a52", radius = 6 },
  -- ...
})
```

Useful widget tokens: `panel_bg`, `panel_border`, `divider`, `title`,
`fg`, `muted`, `input_bg`, `input_fg`, `selected_bg`, `selected_fg`,
`detail`, `notify_fg`, `radius`, `padding`, `margin`, `backdrop`,
`notify_levels` (per-level accent colors).

## Workspace switcher

The workspace switcher is a high-level widget built on
`hollow.ui.select` and `hollow.workspace`.

```lua
hollow.ui.workspace.configure({
  prompt = "Workspaces",
  sources = {
    { resolver = "local", roots = { "C:/code" } },
    { resolver = "wsl",   domain = "wsl", roots = { "/home/me/projects" } },
    { resolver = "ssh",   domain = "tower", roots = { "/home/me/projects" } },
  },
  project_roots = { "C:/code" },
  format_item = function(item)
    return {
      hollow.ui.span(item.is_active and "* " or "  "),
      hollow.ui.span(item.name, { bold = item.is_active }),
      hollow.ui.span(item.cwd and ("  " .. item.cwd) or "", { fg = "#727169" }),
    }
  end,
})

hollow.ui.workspace.open_switcher()
hollow.ui.workspace.create({ on_confirm = function(name) ... end })
hollow.ui.workspace.rename()
hollow.ui.workspace.close()
```

Discovery sources:

| Resolver | Behavior |
| --- | --- |
| `local` | Scans `roots` with `hollow.read_dir` |
| `wsl` | Lists directories through `wsl.exe` |
| `ssh` | Lists directories through `hollow.term.run_domain_process` |

`cwd_resolver = "wsl_unc"` translates Windows UNC paths like
`\\wsl$\Ubuntu\home\me\Projects` back to Linux paths before launching.

## See also

- [`hollow.ui`](reference/lua/ui.md) — full API
- [UI recipes](examples/ui-recipes.md) — drop-in widgets and patterns
- [Themes](themes.md) — palette and widget theme tokens
- [Workspace switcher](reference/lua/workspace.md) — picker details
