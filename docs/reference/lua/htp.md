# `hollow.htp`

Register custom query and emit channels for HTP (Hollow Terminal
Protocol).

For the conceptual model see
[Shell integration](../../shell-integration.md).
For the wire format see [HTP protocol](../../htp-protocol.md).
For the shell-side helpers see
[Shell integration recipes](../../shell-integration-recipes.md).
For the LuaLS schema see
[`types/hollow.lua`](../../../types/hollow.lua) (`HtpQueryContext`,
`HtpEmitContext`).

## Functions

```lua
hollow.htp.on_query(channel, handler)   -- register a query channel
hollow.htp.on_emit(channel, handler)    -- register an emit channel
hollow.htp.off_query(channel)           -- remove a query channel
hollow.htp.off_emit(channel)            -- remove an emit channel
```

## Handlers

### Query handler

```lua
hollow.htp.on_query("build_status", function(ctx)
  return { running = true, target = ctx.params.target or "debug" }
end)
```

`ctx`:

```lua
HtpQueryContext = {
  pane = HollowPane,
  params = table,
}
```

The return value is JSON-serialized back to the caller.

### Emit handler

```lua
hollow.htp.on_emit("notify", function(ctx)
  hollow.ui.notify.show(ctx.payload.text, { ttl = ctx.payload.ttl or 1500 })
end)
```

`ctx`:

```lua
HtpEmitContext = {
  pane = HollowPane,
  payload = any,
}
```

Emit handlers return nothing. The host replies with a `result` or
`error` frame, depending on whether the handler threw.

## Built-in query channels

`pane`, `current_pane`, `tab`, `current_tab`, `tabs`, `panes`,
`workspace`, `workspaces`, `current_workspace`, `current_domain`,
`echo`.

## Built-in emit channels

`close_pane`, `focus_pane`, `resize_pane`, `send_text`, `split_pane`,
`new_tab`, `close_tab`, `focus_tab`, `next_tab`, `prev_tab`,
`set_tab_title`, `new_workspace`, `close_workspace`, `next_workspace`,
`prev_workspace`, `switch_workspace`, `set_workspace_name`,
`toggle_pane_maximized`, `set_pane_floating`,
`set_floating_pane_bounds`, `move_pane`, `reload_config`, `set_theme`,
`scroll`.

## Example: an `echo` handler

`echo` is already built in, but it is the cleanest demo:

```lua
hollow.htp.on_query("echo", function(ctx) return ctx.params end)
```

Querying it from the shell:

```bash
hollow-cli get htp echo '{"value":42}'
# => {"value":42}
```

## Example: shell-driven picker

```lua
hollow.htp.on_emit("show_picker", function(ctx)
  hollow.ui.select.open({
    items = ctx.payload.items or {},
    actions = {
      { name = "open", fn = function(item) hollow.term.split_pane({ cwd = item.cwd }) end },
    },
  })
end)
```

From a shell:

```bash
hollow-cli emit show_picker '{"items":[{"name":"a","cwd":"/tmp/a"}]}'
```

## See also

- [Shell integration](../../shell-integration.md)
- [HTP protocol](../../htp-protocol.md)
- [Shell integration recipes](../../shell-integration-recipes.md)
- [Native CLI](../cli/native.md)
