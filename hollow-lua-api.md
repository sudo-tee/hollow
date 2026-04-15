# Hollow Lua API Reference

This document describes the current Lua API shipped by Hollow.

## Core idea

Hollow exposes a namespaced runtime table:

```lua
local hollow = require("hollow")
```

Primary namespaces:

- `hollow.config`
- `hollow.term`
- `hollow.events`
- `hollow.keymap`
- `hollow.ui`
- `hollow.htp`
- `hollow.process`

Returned tab, pane, and workspace objects are snapshots. Treat them as read-only.

## `hollow.config`

```lua
hollow.config.set(opts)
hollow.config.get(key)
hollow.config.snapshot()
hollow.config.reload()
```

`set()` merges config state and applies it to the host.

Domain-related config fields:

```lua
hollow.config.set({
  default_domain = "wsl",
  domains = {
    wsl = "wsl.exe",
    pwsh = "pwsh.exe",
    cmd = "cmd.exe",
    ssh = "ssh user@example.com",
    unix = "/bin/zsh",
  },
})
```

`default_domain` picks the shell used for normal tab/pane creation when no domain is passed explicitly.
`domains` maps a domain name to the shell command that should be launched for that domain.

## `hollow.term`

```lua
hollow.term.current_tab()
hollow.term.current_pane()
hollow.term.tabs()
hollow.term.tab_by_id(id)

hollow.term.workspaces()
hollow.term.current_workspace()
hollow.term.set_workspace_name(name)
hollow.term.new_workspace()
hollow.term.next_workspace()
hollow.term.prev_workspace()

hollow.term.new_tab(opts?)
hollow.term.split_pane(direction_or_opts, opts?)
hollow.term.focus_tab(id)
hollow.term.close_tab(id)
hollow.term.set_title(title, tab_id?)
hollow.term.send_text(text, pane_id?)
```

`split_pane` accepts either `(direction, opts?)` or a single options table with:

```lua
{
  direction = "horizontal" | "vertical",
  ratio = number,
  domain = string,
  cwd = string,
}
```

### Shapes

`HollowPane`

```lua
{
  id = integer,
  pid = integer,
  domain = string|nil,
  cwd = string,
  title = string,
  is_focused = boolean,
  size = { rows = integer, cols = integer, width = integer, height = integer },
}
```

`HollowTab`

```lua
{
  id = integer,
  title = string,
  index = integer, -- 1-based in Lua
  is_active = boolean,
  panes = HollowPane[],
  pane = HollowPane,
}
```

`HollowWorkspace`

```lua
{
  index = integer, -- 1-based in Lua
  name = string,
  is_active = boolean,
}
```

## `hollow.events`

```lua
handle = hollow.events.on(name, handler)
hollow.events.off(handle)
hollow.events.once(name, handler)
hollow.events.emit(name, payload?)
```

Built-in events currently include:

- `config:reloaded`
- `term:title_changed`
- `term:tab_activated`
- `term:tab_closed`
- `term:pane_focused`
- `term:cwd_changed`
- `key:unhandled`
- `window:resized`
- `window:focused`
- `window:blurred`

Built-in events cannot be emitted from Lua.

## `hollow.keymap`

Hollow uses Vim-style key notation for all keymaps:

- plain characters: `j`, `/`, `?`
- modified chords: `<C-t>`, `<C-S-Tab>`, `<A-PageDown>`
- leader sequences: `<leader>e`, `<leader>wo`, `<leader><C-p>`

Legacy `ctrl+...`, `leader+...`, and split `mods`/`key` APIs are not supported.

Available helpers:

```lua
hollow.keymap.set(chord, action, opts?)
hollow.keymap.del(chord)
hollow.keymap.get(chord)
hollow.keymap.set_leader(chord, opts?)
hollow.keymap.clear_leader()
hollow.keymap.is_leader_active()
hollow.keymap.get_leader_state()
```

## `hollow.ui`

Shared node primitives:

```lua
hollow.ui.span(text, style?)
hollow.ui.spacer()
hollow.ui.icon(name, style?)
hollow.ui.group(children, style?)
```

Shared bar item primitives:

```lua
hollow.ui.bar.tabs(opts?)
hollow.ui.bar.workspace(opts?)
hollow.ui.bar.time(fmt, opts?)
hollow.ui.bar.key_legend(opts?)
hollow.ui.bar.custom(opts)
```

These are bar-level items rather than topbar-specific items, so the same nodes can be reused by future bar surfaces.

### Widget protocol

All widget surfaces accept a table with at least:

```lua
{
  render = function(ctx) ... end,
  on_event = function(name, e) ... end, -- optional
  on_mount = function() ... end,        -- optional
  on_unmount = function() ... end,      -- optional
}
```

`ctx.term` currently includes:

- `ctx.term.tab`
- `ctx.term.pane`
- `ctx.term.tabs`
- `ctx.term.workspace`
- `ctx.term.workspaces`

### `hollow.ui.topbar`

```lua
widget = hollow.ui.topbar.new(opts)
hollow.ui.topbar.mount(widget)
hollow.ui.topbar.unmount()
hollow.ui.topbar.invalidate()
```

The current renderer adapts topbar widgets onto the existing top status bar path.
A single `hollow.ui.spacer()` splits left and right content.

### `hollow.ui.bottombar`

```lua
widget = hollow.ui.bottombar.new(opts)
hollow.ui.bottombar.mount(widget)
hollow.ui.bottombar.unmount()
hollow.ui.bottombar.invalidate()
```

Bottom bar widgets accept the same list of bar items as the top bar.
Set `opts.height` to reserve vertical space and render the bar at the bottom of the window.

### `hollow.ui.sidebar`

```lua
widget = hollow.ui.sidebar.new(opts)
hollow.ui.sidebar.mount(widget)
hollow.ui.sidebar.unmount()
hollow.ui.sidebar.toggle()
hollow.ui.sidebar.invalidate()
```

Sidebar options:

```lua
{
  side = "left" | "right",
  width = integer,   -- in terminal columns
  reserve = boolean, -- optional, default false
  hidden = boolean,  -- optional
  render = function(ctx) ... end,
}
```

If `reserve = true`, the sidebar shrinks the terminal layout instead of drawing over it.
If the sidebar is hidden or unmounted, reserved space is released.

### `hollow.ui.overlay`

```lua
widget = hollow.ui.overlay.new(opts)
hollow.ui.overlay.push(widget)
hollow.ui.overlay.pop()
hollow.ui.overlay.clear()
hollow.ui.overlay.depth()
```

Overlays stack and receive `on_key(key, mods)` before normal keymaps.

### Built-in overlay helpers

```lua
hollow.ui.notify.show(message, opts?)
hollow.ui.notify.info(message, opts?)
hollow.ui.notify.warn(message, opts?)
hollow.ui.notify.error(message, opts?)
hollow.ui.notify.clear()

hollow.ui.input.open(opts)
hollow.ui.input.close()

hollow.ui.select.open(opts)
hollow.ui.select.close()
```

Notifications accept `ttl` in milliseconds and now dismiss automatically, plus `align` values like `"top_right"` or `"bottom_right"`.

Input/select overlays capture printable keys including digits and punctuation, render a visible caret, support customizable backdrops via `true`, a color string like `"#000000"`, or `{ color = "#000000", alpha = 72 }`, and accept overlay `width`/`height`. Select navigation wraps and scrolls when the list is taller than the visible area.

Built-in widgets (`notify`, `input`, `select`) now resolve a shared palette from `theme.widgets.all` and per-widget sections like `theme.widgets.select`; each call can also override tokens with `opts.theme` or panel chrome with `opts.chrome`.

`hollow.ui.select` also accepts formatted `label`/`detail` content via span nodes, so picker items can be colorized while filtering still matches against the plain text.

It also accepts a shorthand text node form like `{ "Error", fg = "#ff5d62", bold = true }`, which is easier to write than a full `hollow.ui.span(...)` for simple colored labels.

For a lighter DSL, use `hollow.ui.text(...)`, `hollow.ui.row(...)`, and `hollow.ui.rows(...)` to build inline content and conditional row lists without as much ceremony.

There is also a small hyperscript-style helper: `hollow.ui.h(...)` / `hollow.ui.el(...)`, so you can write things like `hwl.ui.h("row", nil, {"Name", fg="#98bb6c"}, hwl.ui.h("text", { fg="#7e9cd8" }, " [ok]"))`.

Component functions now receive `props.children`, `props.children_row`, and `props.children_rows`, there is a `hollow.ui.fragment(...)` helper for nested row groups, and `hollow.ui.tags.row(...)` / `hollow.ui.tags.text(...)` style factories are available if you prefer not to use string tag names.

## `hollow.htp`

Planned namespace, not fully implemented yet:

```lua
hollow.htp.on_query(channel, handler)
hollow.htp.on_emit(channel, handler)
hollow.htp.off_query(channel)
hollow.htp.off_emit(channel)
```

## `hollow.process`

Planned namespace, not fully implemented yet:

```lua
hollow.process.spawn(opts)
hollow.process.exec(opts)
```

## Example

```lua
local hollow = require("hollow")

hollow.config.set({
  default_domain = hollow.platform.is_windows and "wsl" or "unix",
  domains = {
    wsl = "wsl.exe",
    pwsh = "pwsh.exe",
    cmd = "cmd.exe",
    unix = hollow.platform.default_shell,
  },
})

hollow.ui.topbar.mount(hollow.ui.topbar.new({
  render = function(ctx)
    return {
      hollow.ui.span(ctx.term.pane.cwd or "", { fg = "#dcd7ba" }),
      hollow.ui.spacer(),
      hollow.ui.span(hollow.strftime("%H:%M:%S"), { fg = "#7e9cd8" }),
    }
  end,
}))

hollow.keymap.set_leader("<C-Space>", { timeout_ms = 1200 })
hollow.keymap.set("<leader>v", "split_vertical", { desc = "split vertical" })

hollow.term.new_tab({ domain = "pwsh" })
hollow.term.split_pane({ direction = "vertical", ratio = 0.4, domain = "wsl" })
hollow.term.split_pane({ direction = "horizontal", cwd = "/tmp/project" })

hollow.events.on("config:reloaded", function()
  hollow.ui.notify.info("Config reloaded", { ttl = 1500 })
end)
```
