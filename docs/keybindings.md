# Keybindings

Hollow uses Vim-style chord notation, modal bindings, and a leader key.
This page covers the key syntax, the default keymap shipped in
[`conf/init.lua`](../conf/init.lua), and how to override anything from
your personal config.

For the full action list, see
[Built-in keymap actions](reference/actions.md).
For the API, see [`hollow.keymap`](reference/lua/keymap.md).
See [Quick select](quick-select.md) for keyboard-driven link opening.

## Chord syntax

| Form           | Meaning                                             |
| -------------- | --------------------------------------------------- |
| `j`            | Single printable key                                |
| `<C-t>`        | `Ctrl` + `t`                                        |
| `<C-S-Tab>`    | `Ctrl` + `Shift` + `Tab`                            |
| `<A-PageDown>` | `Alt` + `PageDown`                                  |
| `<leader>r`    | The leader key followed by `r`                      |
| `<leader>uu`   | The leader key followed by `u`, then `u` (sequence) |

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

The leader key starts a sequence of keys. The shipped base config uses
`<C-Space>` with a **5-second idle timeout per step**:

```lua
hollow.keymap.set_leader("<C-Space>", { timeout_ms = 5000 })
```

Override from your personal config with a different chord.
`hollow.keymap.clear_leader()` removes the leader entirely.

### Discovering bindings

Pause for 200 ms after pressing the leader to see a compact, non-focusable
overlay in the bottom-right corner. It shows the current prefix, aligned next
keys and descriptions; `›` marks a group. Known shortcuts execute immediately,
without waiting for the overlay. Once visible, hints update immediately as you
enter groups. Each valid step renews the idle timeout.

Press **Escape** to cancel or **Backspace** to go up a group (at the root,
Backspace cancels). An explicitly bound Backspace takes precedence. Unmatched
keys cancel and are consumed, not sent to the terminal. Hints close on execution,
timeout, loss of window focus, copy-mode changes, or opening a modal.
Ordinary sequences such as copy-mode `gg` retain a separate 1-second timeout.

```lua
hollow.ui.leader_preview.configure({
  delay_ms = 200,          -- 0 shows hints immediately
  align = "bottom_right",
  width = 48,             -- cells
  max_height = 20,        -- rows; long lists scroll with the mouse
})

-- Alternatives (choose one):
hollow.ui.leader_preview.configure({ mode = "bottombar" })
hollow.ui.leader_preview.configure(false) -- hide leader UI, keep bindings
```

Settings merge with the current configuration; `{ enabled = true }` re-enables
hints. Overlay and disabled modes do not show a leader bottom bar or reserve
terminal space, including during the preview delay. Bottom-bar mode retains the
prefix and inline hints. Copy-mode and quick-select bars are unaffected.
The overlay follows `ui.widgets.all` and `ui.widgets.leader_preview` theme colors;
`configure({ theme = { title = "#88c0d0" } })` overrides this widget only.

Give custom callbacks a `desc`, and optionally label groups:

```lua
hollow.keymap.group("<leader>w", "Workspace")
hollow.keymap.set("<leader>wn", "new_workspace", { desc = "New workspace" })
```

Group labels do not replace bindings. Without a description, named actions use
their readable action name and callbacks show “Lua callback”. Preview rendering
is bounded to 70 next keys per prefix; all bindings remain executable.
See [`hollow.keymap`](reference/lua/keymap.md) for the state API.

## The default keymap

This is the keymap shipped in
[`conf/init.lua`](../conf/init.lua).
Override any entry by calling `hollow.keymap.set(...)` again with the
same chord and a new action — last set wins.

### Clipboard

| Chord        | Action            |
| ------------ | ----------------- |
| `<C-S-c>`    | `copy_selection`  |
| `<C-S-v>`    | `paste_clipboard` |
| `<S-Insert>` | `paste_clipboard` |

### Tabs

| Chord         | Action      |
| ------------- | ----------- |
| `<C-t>`       | `new_tab`   |
| `<C-w>`       | `close_tab` |
| `<C-Tab>`     | `next_tab`  |
| `<C-S-Tab>`   | `prev_tab`  |
| `<C-A-Right>` | `next_tab`  |
| `<C-A-Left>`  | `prev_tab`  |

### Workspaces

| Chord         | Action               |
| ------------- | -------------------- |
| `<C-A-n>`     | `new_workspace`      |
| `<C-A-p>`     | `workspace_switcher` |
| `<C-A-r>`     | `rename_workspace`   |
| `<C-A-w>`     | `close_workspace`    |
| `<C-A-Right>` | `next_workspace`     |
| `<C-A-Left>`  | `prev_workspace`     |

### Panes

| Chord       | Action             |
| ----------- | ------------------ |
| `<C-\>`     | `split_vertical`   |
| `<C-S-\>`   | `split_horizontal` |
| `<C-S-w>`   | `close_pane`       |
| `<C-S-m>`   | `maximize_pane`    |
| `<C-S-f>`   | `float_pane`       |
| `<C-A-S-f>` | `tile_pane`        |

#### Focus

| Chord         | Action             |
| ------------- | ------------------ |
| `<C-S-Left>`  | `focus_pane_left`  |
| `<C-S-Right>` | `focus_pane_right` |
| `<C-S-Up>`    | `focus_pane_up`    |
| `<C-S-Down>`  | `focus_pane_down`  |

#### Move

| Chord     | Action            |
| --------- | ----------------- |
| `<C-A-h>` | `move_pane_left`  |
| `<C-A-l>` | `move_pane_right` |
| `<C-A-k>` | `move_pane_up`    |
| `<C-A-j>` | `move_pane_down`  |

#### Resize

| Chord           | Action              |
| --------------- | ------------------- |
| `<C-A-S-Left>`  | `resize_pane_left`  |
| `<C-A-S-Right>` | `resize_pane_right` |
| `<C-A-Up>`      | `resize_pane_up`    |
| `<C-A-Down>`    | `resize_pane_down`  |

### Scrollback

| Chord            | Action                 |
| ---------------- | ---------------------- |
| `<A-S-PageUp>`   | `scrollback_page_up`   |
| `<A-S-PageDown>` | `scrollback_page_down` |
| `<C-S-Home>`     | `scrollback_top`       |
| `<C-S-End>`      | `scrollback_bottom`    |
| `<A-S-Up>`       | `prompt_jump_prev`     |
| `<A-S-Down>`     | `prompt_jump_next`     |

### Copy mode

| Chord       | Action              |
| ----------- | ------------------- |
| `<C-S-x>`   | `copy_mode`         |
| `<C-S-X>`   | `copy_mode` (alias) |

See [Copy mode](copy-mode.md) for the modal bindings.

### Leader bindings

| Chord        | Action                      |
| ------------ | --------------------------- |
| `<leader>r`  | Rename current tab          |
| `<leader>uu` | Reload config               |
| `<leader>p`  | Open the command palette    |
| `<leader>f`  | [Find](find.md) in terminal |
| `<leader>/`  | [Find](find.md) (alias)     |
| `<leader>q`  | Quick select visible text   |

### Font size

| Chord         | Action                    |
| ------------- | ------------------------- |
| `<C-S-minus>` | Decrease font size by 0.5 |
| `<C-S-equal>` | Increase font size by 0.5 |
| `<C-0>`       | Reset font size           |

These are bound to inline Lua callbacks in `conf/init.lua`; see
[Config snippets](examples/config-snippets.md#font-size-shortcuts) for the
pattern.

## Overriding keymaps

```lua
local hollow = require("hollow")

-- Replace an action
hollow.keymap.set("<C-t>", function()
  hollow.term.new_tab({ domain = "UbuntuWsl" })
end, { desc = "new tab in wsl" })

-- Remove a binding
hollow.keymap.del("<C-S-c>")

-- Bind a leader sequence
hollow.keymap.set("<leader>e", "split_vertical", { desc = "split vertical" })

-- Deleting a keymap
hollow.keymap.del("<leader>uu")
```

Inline callbacks and string action names are equivalent.
`desc` is used by the key-legend widget and by the workspace switcher.

## Disabling default keymaps

Set `load_default_keymaps` to `false` in your override config to prevent
all shipped keymaps from registering. You can then define your own from
scratch:

```lua
hollow.config.set({ load_default_keymaps = false })

-- Define only the bindings you want
hollow.keymap.set("<C-t>", "new_tab")
hollow.keymap.set("<C-S-x>", "close_tab")
```

Note: `set_leader` is not affected by this flag — it is config, not a
keymap binding. If you also want a custom leader, call
`hollow.keymap.set_leader(...)` in your override config.

The `config:ready` event fires after defaults are applied (or skipped).
Use it to run code that depends on the final keymap state:

```lua
hollow.events.on("config:ready", function()
  -- all keymaps are registered (or not) at this point
  hollow.ui.notify.info("keymaps ready", { ttl = 1200 })
end)
```

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
- [Quick select](quick-select.md) — visible-link hints
