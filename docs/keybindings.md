# Keybindings

Hollow uses Vim-style chord notation, modal bindings, and a leader key.
This page covers the key syntax, the default keymap shipped in
[`conf/init.lua`](../conf/init.lua), and how to override anything from
your personal config.

For the full action list, see
[Built-in keymap actions](reference/actions.md).
For the API, see [`hollow.keymap`](reference/lua/keymap.md).

## Chord syntax

| Form | Meaning |
| --- | --- |
| `j` | Single printable key |
| `<C-t>` | `Ctrl` + `t` |
| `<C-S-Tab>` | `Ctrl` + `Shift` + `Tab` |
| `<A-PageDown>` | `Alt` + `PageDown` |
| `<leader>r` | The leader key followed by `r` |
| `<leader>uu` | The leader key followed by `u`, then `u` (sequence) |

Mods you can chain: `C-` (Ctrl), `S-` (Shift), `A-` (Alt).
Legacy `ctrl+...`, `leader+...`, and split `mods`/`key` APIs are not
supported; use the `<...>` form.

## Modes

Every binding belongs to a mode. Hollow ships two:

- `normal` — the default; binding applies to the focused pane
- `copy_mode` — the modal scrollback navigator; see [Copy mode](copy-mode.md)

`mode` defaults to `"normal"`. Bind to copy mode with
`{ mode = "copy_mode" }`.

## The leader key

The leader key is a prefix that opens a small mini-language of two-key
sequences. The shipped base config sets `<C-Space>` with a 1200 ms timeout:

```lua
hollow.keymap.set_leader("<C-Space>", { timeout_ms = 1200 })
```

Override from your personal config with a different chord.
`hollow.keymap.clear_leader()` removes the leader entirely.

## The default keymap

This is the keymap shipped in
[`conf/init.lua`](../conf/init.lua).
Override any entry by calling `hollow.keymap.set(...)` again with the
same chord and a new action — last set wins.

### Clipboard

| Chord | Action |
| --- | --- |
| `<C-S-c>` | `copy_selection` |
| `<C-S-v>` | `paste_clipboard` |
| `<S-Insert>` | `paste_clipboard` |

### Tabs

| Chord | Action |
| --- | --- |
| `<C-t>` | `new_tab` |
| `<C-w>` | `close_tab` |
| `<C-Tab>` | `next_tab` |
| `<C-S-Tab>` | `prev_tab` |
| `<C-A-Right>` | `next_tab` |
| `<C-A-Left>` | `prev_tab` |

### Workspaces

| Chord | Action |
| --- | --- |
| `<C-A-n>` | `new_workspace` |
| `<C-A-p>` | `workspace_switcher` |
| `<C-A-r>` | `rename_workspace` |
| `<C-A-w>` | `close_workspace` |
| `<C-A-Right>` | `next_workspace` |
| `<C-A-Left>` | `prev_workspace` |

### Panes

| Chord | Action |
| --- | --- |
| `<C-\>` | `split_vertical` |
| `<C-S-\>` | `split_horizontal` |
| `<C-S-w>` | `close_pane` |
| `<C-S-m>` | `maximize_pane` |
| `<C-S-f>` | `float_pane` |
| `<C-A-S-f>` | `tile_pane` |

#### Focus

| Chord | Action |
| --- | --- |
| `<C-S-Left>` | `focus_pane_left` |
| `<C-S-Right>` | `focus_pane_right` |
| `<C-S-Up>` | `focus_pane_up` |
| `<C-S-Down>` | `focus_pane_down` |

#### Move

| Chord | Action |
| --- | --- |
| `<C-A-h>` | `move_pane_left` |
| `<C-A-l>` | `move_pane_right` |
| `<C-A-k>` | `move_pane_up` |
| `<C-A-j>` | `move_pane_down` |

#### Resize

| Chord | Action |
| --- | --- |
| `<C-A-S-Left>` | `resize_pane_left` |
| `<C-A-S-Right>` | `resize_pane_right` |
| `<C-A-Up>` | `resize_pane_up` |
| `<C-A-Down>` | `resize_pane_down` |

### Scrollback

| Chord | Action |
| --- | --- |
| `<A-S-PageUp>` | `scrollback_page_up` |
| `<A-S-PageDown>` | `scrollback_page_down` |
| `<C-S-Home>` | `scrollback_top` |
| `<C-S-End>` | `scrollback_bottom` |
| `<A-S-Up>` | `prompt_jump_prev` |
| `<A-S-Down>` | `prompt_jump_next` |

### Copy mode

| Chord | Action |
| --- | --- |
| `<C-S-x>` | `copy_mode` |
| `<C-S-X>` | `copy_mode` (alias) |
| `<leader>/` | `copy_mode_search` |

See [Copy mode](copy-mode.md) for the modal bindings.

### Leader bindings

| Chord | Action |
| --- | --- |
| `<leader>r` | Rename current tab |
| `<leader>uu` | Reload config |

### Font size

| Chord | Action |
| --- | --- |
| `<C-S-minus>` | Decrease font size by 0.5 |
| `<C-S-equal>` | Increase font size by 0.5 |
| `<C-0>` | Reset font size |

These are bound to inline Lua callbacks in `conf/init.lua`; see
[Config snippets](examples/config-snippets.md#font-size-shortcuts) for the
pattern.

## Overriding keymaps

```lua
local hollow = require("hollow")

-- Replace an action
hollow.keymap.set("<C-t>", function()
  hollow.term.new_tab({ domain = "wsl" })
end, { desc = "new tab in wsl" })

-- Remove a binding
hollow.keymap.del("<C-S-c>")

-- Bind a leader sequence
hollow.keymap.set("<leader>e", "split_vertical", { desc = "split vertical" })
```

Inline callbacks and string action names are equivalent.
`desc` is used by the key-legend widget and by the workspace switcher.

## Adding copy-mode bindings

```lua
hollow.keymap.set("h", "copy_mode_move_left",  { mode = "copy_mode" })
hollow.keymap.set("j", "copy_mode_move_down",  { mode = "copy_mode" })
hollow.keymap.set("k", "copy_mode_move_up",    { mode = "copy_mode" })
hollow.keymap.set("l", "copy_mode_move_right", { mode = "copy_mode" })
hollow.keymap.set("gg", "copy_mode_top",       { mode = "copy_mode" })
hollow.keymap.set("G",  "copy_mode_bottom",    { mode = "copy_mode" })
hollow.keymap.set("v",  "copy_mode_begin_selection",      { mode = "copy_mode" })
hollow.keymap.set("<C-v>", "copy_mode_begin_block_selection", { mode = "copy_mode" })
hollow.keymap.set("y",  "copy_mode_copy_selection", { mode = "copy_mode" })
hollow.keymap.set("/", "copy_mode_search",         { mode = "copy_mode" })
hollow.keymap.set("n", "copy_mode_search_next",    { mode = "copy_mode" })
hollow.keymap.set("N", "copy_mode_search_prev",    { mode = "copy_mode" })
hollow.keymap.set("q", "copy_mode_exit",           { mode = "copy_mode" })
hollow.keymap.set("<Esc>", "copy_mode_exit",       { mode = "copy_mode" })
```

## Reference

- [`hollow.keymap`](reference/lua/keymap.md) — full API
- [Built-in keymap actions](reference/actions.md) — every action name
- [Copy mode](copy-mode.md) — the modal binding surface
