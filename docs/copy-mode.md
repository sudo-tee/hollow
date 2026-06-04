# Copy mode

Copy mode is a vim-like modal navigator for the scrollback.
It is a built-in feature of the host; the shipped base config binds
`<C-S-x>` to enter it and supplies default modal bindings.

For the API see [`hollow.keymap`](reference/lua/keymap.md) (mode
`"copy_mode"`) and the copy-mode actions listed under
[Built-in keymap actions](reference/actions.md#copy-mode).

## Entering and exiting

| Chord | Action |
| --- | --- |
| `<C-S-x>` / `<C-S-X>` | `copy_mode` (enter) |
| `q` or `<Esc>` | `copy_mode_exit` |

While in copy mode, the top bar can show a status row with the current
position and a search prompt.

## Movement

The shipped modal bindings are plain vim-ish movement, mapped with
`{ mode = "copy_mode" }`:

| Chord | Action |
| --- | --- |
| `h` / `<Left>` | `copy_mode_move_left` |
| `j` / `<Down>` | `copy_mode_move_down` |
| `k` / `<Up>` | `copy_mode_move_up` |
| `l` / `<Right>` | `copy_mode_move_right` |
| `0` | `copy_mode_line_start` |
| `$` | `copy_mode_line_end` |
| `gg` | `copy_mode_top` |
| `G` | `copy_mode_bottom` |
| `<PageUp>` | `copy_mode_page_up` |
| `<PageDown>` | `copy_mode_page_down` |
| `<Home>` | `copy_mode_top` |
| `<End>` | `copy_mode_bottom` |

`gg` and `G` use the leader-style sequence machinery.

## Selection

| Chord | Action |
| --- | --- |
| `v` | `copy_mode_begin_selection` |
| `<C-v>` | `copy_mode_begin_block_selection` |
| `<Space>` | `copy_mode_clear_selection` |

After `v` (or `<C-v>`), the next movement extends the selection. With
block selection, vertical movement extends the column range, not the
line range.

## Search

| Chord | Action |
| --- | --- |
| `/` | `copy_mode_search` |
| `n` | `copy_mode_search_next` |
| `N` | `copy_mode_search_prev` |

`/` opens a prompt; typing filters and the first match is highlighted.
The status line shows `match_index / match_count`.

`hollow.events.on("copy_mode:search_requested", ...)` lets your config
open a custom search prompt. After the user submits, call
`host_api.copy_mode_search_set_query(value)`.

## Copy and exit

| Chord | Action |
| --- | --- |
| `y` | `copy_mode_copy_selection` |
| `<Enter>` | `copy_mode_copy_selection` |

`y` copies the current selection to the clipboard and exits copy mode.
If no selection is active, it copies the line under the cursor.

## Programmatic access

The host bridge exposes copy mode directly. Lua can drive it via
`hollow.term` actions or via the raw host API in `hollow.ui`.

```lua
hollow.keymap.set("<leader>y", function()
  -- Hand-rolled: enter, select line, copy, exit
  require("hollow.state").get().host_api.copy_mode_enter()
  -- ... extend selection with copy_mode_move_* ...
  require("hollow.state").get().host_api.copy_mode_copy()
  require("hollow.state").get().host_api.copy_mode_exit()
end)
```

In practice the simplest path is the `copy_mode_*` action bindings —
the host bridge is mostly there so the Lua runtime can react to the
`copy_mode:changed` event.

## Events

```lua
hollow.events.on("copy_mode:changed", function(e)
  if e.active then
    -- e.query, e.match_count, e.match_index, e.selecting, e.block
  end
end)
```

Use this to drive an HUD widget (the shipped top bar can render one) or
to log copy activity.

## Adding bindings

The copy-mode bindings are normal keymaps with `{ mode = "copy_mode" }`.
Override or extend in your personal config:

```lua
local hollow = require("hollow")

hollow.keymap.set("w", "copy_mode_move_right",    { mode = "copy_mode" })
hollow.keymap.set("b", "copy_mode_move_left",     { mode = "copy_mode" })
hollow.keymap.set("e", "copy_mode_line_end",      { mode = "copy_mode" })
hollow.keymap.set("H", "copy_mode_page_up",       { mode = "copy_mode" })
hollow.keymap.set("L", "copy_mode_page_down",     { mode = "copy_mode" })
```

## See also

- [`hollow.keymap`](reference/lua/keymap.md) — mode-aware keymaps
- [Built-in keymap actions → copy mode](reference/actions.md#copy-mode)
- [Keybindings → Adding copy-mode bindings](keybindings.md#adding-copy-mode-bindings)
