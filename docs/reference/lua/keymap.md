# `hollow.keymap`

Bind keys to actions or Lua callbacks.
Hollow uses vim-style chord notation and supports a leader key and
modal bindings (normal, copy_mode).

For the conceptual model see [Keybindings](../../keybindings.md).
For the action list see [Built-in keymap actions](../actions.md).

## Chord syntax

| Form | Meaning |
| --- | --- |
| `j` | Single printable key |
| `<C-t>` | `Ctrl` + `t` |
| `<C-S-Tab>` | `Ctrl` + `Shift` + `Tab` |
| `<A-PageDown>` | `Alt` + `PageDown` |
| `<leader>r` | Leader key followed by `r` |
| `<leader>uu` | Leader sequence (two `u`s) |

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
```

`default` has the same signature as `set` but stores the binding as a
*pending default* instead of registering it immediately. When
`apply_defaults()` runs (automatically after config loading), each pending
entry is registered via `set` unless `load_default_keymaps` is `false`.

This is how `conf/init.lua` registers its shipped keymaps — they are
deferred so the user's override config can disable them before they take
effect.

`set` options:

```lua
{
  desc = "shown in the key-legend widget",
  mode = "normal",                              -- "normal" or "copy_mode"
  timeout_ms = 1200,                            -- for the leader only
}
```

`action` is either a string action name (see
[Built-in keymap actions](../actions.md)) or a Lua function.

## Examples

Replace a built-in action:

```lua
hollow.keymap.set("<C-t>", function()
  hollow.term.new_tab({ domain = "wsl" })
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
hollow.keymap.set_leader("<C-Space>", { timeout_ms = 1200 })
hollow.keymap.clear_leader()
```

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
  next = string[],        -- valid next keys
  next_display = string[],
  desc = string | nil,    -- description of the matching action, if any
  remaining_ms = integer, -- ms until the sequence times out
  timeout_ms = integer,
  complete = boolean,     -- sequence resolved to a final action
}
```

Useful for showing a leader HUD in the top bar.

## Modal notes

A binding in `normal` mode only fires when copy mode is not active.
Bindings in `copy_mode` only fire when copy mode is active.
The runtime also routes `on_key(key, mods)` to mounted overlays before
matching keymaps; see [`hollow.ui.overlay`](ui.md#overlays).

## See also

- [Keybindings](../../keybindings.md) — default keymap
- [Copy mode](../../copy-mode.md) — copy mode bindings
- [Built-in keymap actions](../actions.md) — every action name
