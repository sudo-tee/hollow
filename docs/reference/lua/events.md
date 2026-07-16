# `hollow.events`

Subscribe to host events. Built-in events cannot be emitted from
Lua; use `hollow.events.emit(name, payload)` only for custom events
that you also register handlers for.

For the LuaLS schema see
[`types/hollow.lua`](../../../types/hollow.lua) (`HollowEventName`,
`HollowEventListener`).

## Functions

```lua
handle = hollow.events.on(name, handler)   -- returns a handle (integer)
hollow.events.off(handle)                  -- unsubscribe
hollow.events.once(name, handler)          -- unsubscribe after first call
hollow.events.emit(name, payload?)         -- dispatch a custom event
```

`handler(payload)` is called on the host thread with a payload table.

## Built-in events

| Event | Payload |
| --- | --- |
| `config:reloaded` | (empty) |
| `config:ready` | (empty) — emitted once after config loading completes (including deferred defaults) |
| `workspace:new` | `{ workspace, index }` |
| `workspace:changed` | `{ workspace, index }` |
| `workspace:closed` | `{ name }` — emitted when a workspace becomes empty and is auto-closed |
| `selection:begin` | (empty) |
| `selection:cleared` | (empty) |
| `term:title_changed` | `{ pane, old_title, new_title }` |
| `term:tab_activated` | `{ tab }` |
| `term:tab_closed` | `{ tab_id }` |
| `term:pane_focused` | `{ pane }` |
| `term:pane_layout_changed` | `{ pane }` |
| `term:cwd_changed` | `{ pane, old_cwd, new_cwd }` |
| `term:foreground_process_changed` | `{ pane, old_process, new_process }` |
| `term:bell` | `{ pane }` (`pane.has_bell` is `true` until focus) |
| `key:unhandled` | `{ key, mods }` |
| `window:resized` | `{ size }` (`size` has `rows`, `cols`, `width`, `height`) |
| `window:focused` | (empty) |
| `window:blurred` | (empty) |
| `copy_mode:changed` | `{ active, query?, match_count?, match_index?, selecting?, block? }` |
| `copy_mode:search_requested` | (empty; open a search prompt) |
| `topbar:hover` | `{ id }` |
| `topbar:leave` | (empty) |
| `topbar:click` | `{ id }` |
| `bottombar:hover` | `{ id }` |
| `bottombar:leave` | (empty) |
| `bottombar:click` | `{ id }` |

The `term:bell` event fires once per BEL (`\a`) received by a pane.
The pane snapshot's `has_bell` field stays `true` until the pane
receives focus.

## Examples

React to config reloads:

```lua
hollow.events.on("config:reloaded", function()
  hollow.ui.notify.info("Config reloaded", { ttl = 1200 })
end)
```

Track cwd changes to update a custom widget:

```lua
hollow.events.on("term:cwd_changed", function(e)
  -- e.pane is a HollowPane snapshot
  -- e.new_cwd is the new directory
end)
```

React to copy mode transitions:

```lua
hollow.events.on("copy_mode:changed", function(e)
  if e.active and e.query ~= "" then
    -- show "match_index / match_count" in a custom widget
  end
end)

hollow.events.on("copy_mode:search_requested", function()
  hollow.ui.input.open({
    prompt = "Search",
    on_confirm = function(value)
      require("hollow.state").get().host_api.copy_mode_search_set_query(value)
    end,
  })
end)
```

One-shot subscription:

```lua
hollow.events.once("workspace:new", function(e)
  print("first workspace:", e.workspace.name)
end)
```

## Custom events

```lua
-- emit
hollow.events.on("build_started", function(e)
  hollow.ui.notify.info("build: " .. e.target)
end)
hollow.events.emit("build_started", { target = "release" })
```

Custom event names are plain strings. The host does not interpret
them; they are a local bus between Lua modules in the same Hollow
process.

## See also

- [`hollow.ui`](ui.md) — widgets react to events
- [`hollow.keymap`](keymap.md) — bind keys to actions
- [Copy mode](../../copy-mode.md) — uses `copy_mode:*` events
