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
handle = hollow.events.filter(name, handler) -- register a transformation
payload = hollow.events.apply_filters(name, payload) -- custom producer pipeline
```

`handler(payload)` is called on the host thread with a payload table.

## Filters versus notifications

`on`/`once` observe events; their return values are ignored. `filter` registers
a separate synchronous transformation pipeline. It does **not** intercept
`emit`, `on`, or native notification delivery. A producer must explicitly apply
filters and consume the resulting payload before performing its operation.

```lua
local handle = hollow.events.filter("myplugin:launch", function(spec)
  spec.env.EDITOR = "nvim"
  return spec
end)

-- In the plugin that owns the launch operation:
local spec = hollow.events.apply_filters("myplugin:launch", { env = {} })
-- Use spec to perform the operation.
hollow.events.off(handle)
```

Names are arbitrary non-empty strings; payloads and replacements must be tables.
Handlers run in registration order. Each receives a deep copy of the previous
accepted payload. Returning a table accepts a replacement; returning `nil`
discards that handler's mutations and preserves the previous payload. Errors
and other return types are logged and skipped; later handlers still run.
Accepted replacements are copied too, so retaining a reference does not give
the handler control over later filters. Use plain data tables: functions and
userdata are not isolated, and side effects cannot be rolled back.

`off(handle)` removes a filter just like a notification listener. Removals take
effect immediately; registrations during application wait until the next call.
Recursive application of the same name bypasses its filters; different names
can compose. Filters cannot yield and have no implicit cancellation semantics
(`false` is invalid, not cancellation). Custom producers own schema validation,
timing policy, and any explicit cancellation fields. Generic `apply_filters`
has no time budget or schema beyond requiring tables.

### Built-in filter: `term:spawn`

```lua
hollow.events.filter("term:spawn", function(spec) -- HollowSpawnSpec
  if spec.cwd and spec.cwd:match("/work/myproject$") then
    spec.env.EDITOR = "nvim"
  end
  return spec
end)
```

Applied before native local PTY creation, including the initial pane, tabs,
workspaces, tiled/floating splits, and panes created by CLI or workspace layouts.
Register during config loading to affect the initial pane. No pane snapshot
exists yet. `term:pane_created` remains the separate successful-creation event.
Failed spawns may have run filters without producing that notification.

| Field | Meaning | Editable? |
| --- | --- | --- |
| `shell` | Configured shell command string, not parsed argv | No |
| `domain` | Selected domain name, or nil for unnamed local launch | No |
| `cwd` | Resolved local launch directory | Yes: non-empty string or nil to inherit host cwd |
| `env` | Environment override map after domain configuration | Yes: string keys and values |

The map is **not** the full inherited environment. Removing an ordinary entry
removes its explicit override; it does not unset a variable inherited from the
host. Empty string is a valid environment value. Keys cannot be empty or contain
`=`/NUL; values and cwd cannot contain NUL. `HOLLOW_*`, `TERM`, `COLORTERM`, and
`TERM_PROGRAM` are protected, including differently-cased aliases. Unknown spec
fields and edits to shell/domain reject that handler's entire replacement.
Each handler is validated before the next runs.

SSH and Windows WSL launcher domains currently bypass this pipeline. Their guest
cwd/environment need domain-aware transformation rather than edits to the host
launcher. Executable/argv rewriting, cancellation, and environment unsetting
are not supported in this first version.

Each spawn filter has a 50 ms elapsed-time acceptance budget. Late results are
logged and discarded. This is **not a hard execution deadline**: blocking I/O,
native calls, and infinite loops can still block the UI. Keep filters cheap;
do not invoke external processes for direnv/Nix discovery inside them. Prepare
or cache data asynchronously instead. Nested same-name filter application runs
raw, not recursively. Do not create tabs/panes from spawn filters: those operations
are queued and will run later with their own filters, not as nested applications.

Only `term:spawn` currently has a native filter producer. Registering a filter
for an observational event does not change its host behavior.

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
| `term:pane_created` | `{ pane }` |
| `term:pane_exited` | `{ pane, status }` |
| `term:pane_closed` | `{ pane }` |
| `term:pane_layout_changed` | `{ pane }` |
| `term:cwd_changed` | `{ pane, old_cwd, new_cwd }` |
| `term:foreground_process_changed` | `{ pane, old_process, new_process }` |
| `term:command_started` | `{ pane, command, cwd }` |
| `term:command_finished` | `{ pane, command?, status?, took_ms? }` |
| `term:program_status_changed` | `{ pane }` (`pane.program_status` contains the current OSC 7501 records) |
| `term:bell` | `{ pane }` (`pane.has_bell` is `true` until focus) |
| `term:notification` | `{ pane, title, message, level, id?, ttl_ms?, close }` |
| `key:unhandled` | `{ key, mods }` |
| `window:resized` | `{ size }` (`size` has `rows`, `cols`, `width`, `height`) |
| `window:files_dropped` | `{ paths, pane, pane_id, x, y, text }` |
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

`term:pane_created` fires after a pane is successfully added, including the
initial pane, new tabs/workspaces, and tiled/floating splits. Moving a pane or
reloading config does not create it again.

`term:pane_exited` fires once when Hollow observes the pane's child exit, before
automatic removal. `status` is the process exit code; POSIX signal termination
uses `128 + signal`. WSL bypass uses the guest exit status. If the OS status is
unavailable (for example, a failed transport), `status` is `nil`. This event does
not require shell integration, and its pane snapshot is no longer busy.

`term:pane_closed` fires immediately before removal, with a final pane snapshot
that remains usable after removal. Closing a tab or workspace emits it for each
pane. Explicitly closing a live pane emits only `term:pane_closed`; an already
exited child emits `term:pane_exited` first. Moving panes and application shutdown
do not emit close events. These events are observational, not cancellable.

Command lifecycle events rely on Hollow shell integration; Bash, Zsh, and Fish
report them. `command` is shell-provided command text, `status` is the shell's
exit code, and `took_ms` is measured from HTP message receipt. Shells without
these hooks do not update command state.
Command state survives config reloads. The start event's `cwd` comes from the
shell's start payload, falling back to the cwd captured at HTP receipt for older
shell hooks, rather than the pane's cwd at queued dispatch time.

OSC 99, OSC 9, and OSC 777 packets emit `term:notification` and default to an in-app toast.
The payload's `level` is `info`, `warn`, `error`, or `success`.
An event with `close = true` dismisses the matching toast and carries no message.

## File-drop handling

Use `hollow.on_file_drop` to customize what happens after a file drop.
The handler receives the same payload as `window:files_dropped`.

```lua
hollow.on_file_drop(function(e)
  local paths = {}
  for i, path in ipairs(e.paths) do
    paths[i] = path:gsub("^([A-Za-z]):\\", "/mnt/%1/"):gsub("\\", "/")
  end
  return table.concat(paths, " ")
end)
```

Return `nil` or `true` to use default insertion, `false` to consume
the drop, or a string to replace inserted text. The default handler
quotes paths containing spaces and inserts them into pane under drop.
Default insertion is skipped for remote panes, but handler can transfer
files and return replacement text (or send its own text to `pane_id`).
`window:files_dropped` is observational; use `hollow.on_file_drop`
when handler must replace or suppress default insertion.

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
