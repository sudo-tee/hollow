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
- `hollow.keys`
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
hollow.term.focus_tab(id)
hollow.term.close_tab(id)
hollow.term.set_title(title, tab_id?)
hollow.term.send_text(text, pane_id?)
```

### Shapes

`HollowPane`

```lua
{
  id = integer,
  pid = integer,
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

## `hollow.keys`

High-level key registration:

```lua
hollow.keys.bind(binds)
hollow.keys.bind_one(bind)
hollow.keys.unbind(mods, key)
```

Lower-level leader and chord helpers live under `hollow.keymap`:

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
  shell = hollow.platform.is_windows and "wsl.exe" or hollow.platform.default_shell,
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

hollow.keymap.set_leader("ctrl+space", { timeout_ms = 1200 })
hollow.keymap.set("<leader>v", "split_vertical", { desc = "split vertical" })

hollow.events.on("config:reloaded", function()
  hollow.ui.notify.info("Config reloaded", { ttl = 1500 })
end)
```
