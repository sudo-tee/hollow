# Overview and conventions

The Lua side of Hollow is one global: `hollow`.
Every feature is reached through a dotted path under it.

## The global

```lua
local hollow = require("hollow")
```

`require("hollow")` is provided by the host; it returns the same global
that is also assigned to `_G.hollow`. Modules under
[`src/lua/hollow/`](../../../src/lua/hollow) are loaded on demand.

## Patterns

### Namespaces are dotted paths

Every public function lives at `hollow.<namespace>.<verb>(...)`.
There are no positional arguments; everything is an `opts` table.

```lua
hollow.config.set({ fonts = { size = 16 } })
hollow.term.split_pane({ direction = "vertical", ratio = 0.4 })
hollow.ui.notify.info("saved", { ttl = 1500 })
```

### Snapshots are read-only

`hollow.term.current_tab()`, `hollow.term.tabs()`, and
`hollow.term.current_pane()` return snapshots.
Mutate state through the verb functions (`set_title`, `split_pane`,
`set_pane_tags`, ...); never write to fields on a snapshot.

### Async results

`split_pane`, `new_tab`, and `new_workspace` accept an `on_complete`
callback that fires on the next frame. Successful results include the
created id (`pane_id`, `tab_id`, `workspace_index`); every result has
a `success` boolean.

```lua
hollow.term.split_pane({
  direction = "vertical",
  on_complete = function(result)
    if result.success then
      hollow.term.set_pane_tags({ "editor" }, result.pane_id)
    end
  end,
})
```

For sequential flows, use [`hollow.async`](async.md).

### Events

`hollow.events.on(name, handler)` subscribes; the handler is called on
the host thread with a payload table. Built-in events cannot be
emitted from Lua. See [`hollow.events`](events.md).

## Log and inspect

```lua
hollow.log("starting up", some_value)
hollow.inspect({ a = 1, b = 2 })
```

`hollow.log` writes to the host log (and `hollow.log` next to the
executable). `hollow.inspect` returns a pretty-printed string.

## Filesystem helpers

```lua
local entries = hollow.read_dir("/path/to/dir")
```

`hollow.read_dir(path)` returns an array of absolute entry paths.
For more, use the [`hollow.fs`](fs.md) namespace.

## Date and time

```lua
local s = hollow.strftime("%H:%M:%S")
```

`hollow.strftime(fmt)` formats the current time using the host's
`strftime`. Widgets also receive `ctx.time.epoch_ms` and
`ctx.time.iso` in their render context.

## Scheduling

```lua
hollow.schedule(function()
  -- runs on the next frame
end)

hollow.defer(function()
  -- runs on the next frame (no delay)
end, 1500)
-- or with a 1500ms delay

hollow.on_gui_ready(function()
  -- runs once the GUI is up
end)
```

`schedule` and `defer` are one-shot; the callback is cleaned up after
execution.

## Modal keymaps

Keymaps live in a mode. The default mode is `"normal"`; the runtime
also ships `"copy_mode"`. Bind to a specific mode with
`{ mode = "..." }`. See [`hollow.keymap`](keymap.md).

## Errors

`hollow.util.unsupported(name)` raises a controlled error for features
that exist in the API shape but are not implemented in this build.

## See also

- [`types/hollow.lua`](../../../types/hollow.lua) — LuaLS schema
- [Configuration](../../configuration.md) — config model
- [Custom UI](../../custom-ui.md) — widget model
