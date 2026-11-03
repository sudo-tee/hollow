# `hollow.keymap`

Bind keys to actions or Lua callbacks.
Hollow uses vim-style chord notation and supports a leader key and
modal bindings (normal, copy_mode).

For the conceptual model see [Keybindings](../../keybindings.md).
For the action list see [Built-in keymap actions](../actions.md).

## Chord syntax

| Form           | Meaning                    |
| -------------- | -------------------------- |
| `j`            | Single printable key       |
| `<C-t>`        | `Ctrl` + `t`               |
| `<C-S-Tab>`    | `Ctrl` + `Shift` + `Tab`   |
| `<A-PageDown>` | `Alt` + `PageDown`         |
| `<leader>r`    | Leader key followed by `r` |
| `<leader>uu`   | Leader sequence (two `u`s) |

Mods: `C-` (Ctrl), `S-` (Shift), `A-` (Alt).
Legacy `ctrl+...`, `leader+...`, and split `mods`/`key` APIs are not
supported.

## Functions

```lua
hollow.keymap.set(chord, action, opts?)         -- set or replace
hollow.keymap.default(chord, action, opts?)     -- queue as default (deferred)
hollow.keymap.apply_defaults()                  -- register queued defaults
hollow.keymap.del(chord, opts?)                 -- remove (returns boolean)
hollow.keymap.get(chord, opts?)                 -- read current action

hollow.keymap.set_leader(chord?, opts?)         -- set the leader key
hollow.keymap.clear_leader()                    -- remove the leader
hollow.keymap.is_leader_active()                -- boolean
hollow.keymap.get_leader_state()                -- HollowLeaderState or nil
hollow.keymap.group(prefix, desc, opts?)         -- label a leader group
hollow.keymap.cancel()                          -- cancel the current sequence
```

`default` has the same signature as `set` but stores the binding as a
_pending default_ instead of registering it immediately. When
`apply_defaults()` runs (automatically after config loading), each pending
entry is registered via `set` unless `load_default_keymaps` is `false`.

This is how `conf/init.lua` registers its shipped keymaps — they are
deferred so the user's override config can disable them before they take
effect.

`set` options:

```lua
{
  desc = "shown in the leader preview",
  mode = "normal",                              -- "normal" or "copy_mode"
  args = {},                                    -- named action arguments
}
```

`action` is either a string action name (see
[Built-in keymap actions](../actions.md)) or a Lua function.

## Examples

Replace a built-in action:

```lua
hollow.keymap.set("<C-t>", function()
  hollow.term.new_tab({ domain = "UbuntuWSL" })
end, { desc = "new tab in wsl" })
```

Bind a leader sequence:

```lua
hollow.keymap.set("<leader>e", "split_vertical", { desc = "split vertical" })
```

Bind in copy mode:

```lua
hollow.keymap.set("h", "copy_mode_move_left", { mode = "copy_mode" })
hollow.keymap.set("gg", "copy_mode_top",     { mode = "copy_mode" })
```

Remove a binding:

```lua
hollow.keymap.del("<C-S-c>")
```

Configure the leader:

```lua
hollow.keymap.set_leader("<C-Space>", { timeout_ms = 5000 })
hollow.keymap.clear_leader()
```

`timeout_ms` belongs to `set_leader`, not `set`: it is the idle time allowed
between leader steps (default 5000 ms). Ordinary key sequences keep their
independent 1000 ms timeout. Valid steps and Backspace navigation renew the
leader timeout; the preview delay never delays execution.

`group(prefix, desc, opts?)` labels a leader prefix without replacing its action
or children. `opts.mode` selects normal or copy mode. Labels can be declared
before bindings; description-only groups do not activate the leader.

```lua
hollow.keymap.group("<leader>u", "Configuration")
hollow.keymap.set("<leader>uu", "reload_config", { desc = "Reload config" })
```

The passive overlay appears after 200 ms by default. Use
`hollow.ui.leader_preview.configure({...})` to change delay, position, geometry,
theme, or choose `mode = "bottombar"`; pass `false` to hide hints without
disabling bindings. See [Leader discovery](../../keybindings.md#discovering-bindings)
for configuration examples and navigation behavior.

## Leader state

`hollow.keymap.get_leader_state()` returns a snapshot of the leader
state machine when the leader is in the middle of a sequence:

```lua
HollowLeaderState = {
  active = boolean,       -- true if a sequence is in flight
  mode = HollowKeyMode,   -- current mode
  prefix = string,        -- leader key
  sequence = string[],    -- keys pressed so far
  display = string,       -- pretty version of `sequence`
  started_at_ms = integer, -- start of the entire sequence (host clock)
  next = {                -- valid next keys, sorted by key
    { key = string, desc = string | nil, complete = boolean, has_children = boolean },
  },
  next_display = string[],
  desc = string | nil,    -- description of the matching action, if any
  remaining_ms = integer, -- ms until the sequence times out
  timeout_ms = integer,
  complete = boolean,     -- sequence resolved to a final action
}
```

Also describes in-flight ordinary sequences; `prefix == "<leader>"` identifies
leader sequences. Useful for custom hints or a leader HUD in a bar.

## Modal notes

A binding in `normal` mode only fires when copy mode is not active.
Bindings in `copy_mode` only fire when copy mode is active.
The runtime also routes `on_key(key, mods)` to mounted overlays before
matching keymaps; see [`hollow.ui.overlay`](ui.md#overlays).

## See also

- [Keybindings](../../keybindings.md) — default keymap
- [Copy mode](../../copy-mode.md) — copy mode bindings
- [Built-in keymap actions](../actions.md) — every action name
