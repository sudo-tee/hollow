# Built-in keymap actions

The runtime ships a fixed set of action names you can pass as a string
to `hollow.keymap.set(chord, "name", ...)`.
They are defined in
[`src/lua/hollow/actions.lua`](../../src/lua/hollow/actions.lua).

The full list, grouped by intent:

## Panes

| Action | What it does |
| --- | --- |
| `split_vertical` | Split the active pane vertically |
| `split_horizontal` | Split the active pane horizontally |
| `split_vertical_in_domain` | Split the active pane vertically with a domain picker |
| `split_horizontal_in_domain` | Split the active pane horizontally with a domain picker |
| `create_floating_pane` | Create a new floating pane |
| `maximize_pane` | Toggle pane maximize (covers the tiled area) |
| `float_pane` | Make the active pane floating |
| `tile_pane` | Return a floating pane to the tiled layout |
| `close_pane` | Close the active pane |

## Focus

| Action | What it does |
| --- | --- |
| `focus_pane_left` | Focus the pane to the left |
| `focus_pane_right` | Focus the pane to the right |
| `focus_pane_up` | Focus the pane above |
| `focus_pane_down` | Focus the pane below |

## Move

| Action | What it does |
| --- | --- |
| `move_pane_left` | Move the active pane left (or nudge a floating pane) |
| `move_pane_right` | Move the active pane right |
| `move_pane_up` | Move the active pane up |
| `move_pane_down` | Move the active pane down |

## Resize

| Action | What it does |
| --- | --- |
| `resize_pane_left` | Resize the active pane's left edge left |
| `resize_pane_right` | Resize the active pane's right edge right |
| `resize_pane_up` | Resize the active pane's top edge up |
| `resize_pane_down` | Resize the active pane's bottom edge down |

## Tabs

| Action | What it does |
| --- | --- |
| `new_tab` | Open a new tab |
| `new_tab_in_domain` | Open a new tab with a domain picker |
| `close_tab` | Close the active tab |
| `next_tab` | Focus the next tab |
| `prev_tab` | Focus the previous tab |
| `rename_tab` | Rename the active tab |

## Workspaces

| Action | What it does |
| --- | --- |
| `new_workspace` | Create a new workspace |
| `workspace_switcher` | Open the workspace switcher picker |
| `create_workspace` | Create a workspace via the input prompt |
| `rename_workspace` | Rename the active workspace |
| `close_workspace` | Close the active workspace |
| `next_workspace` | Switch to the next workspace |
| `prev_workspace` | Switch to the previous workspace |

## Clipboard

| Action | What it does |
| --- | --- |
| `copy_selection` | Copy the current selection |
| `paste_clipboard` | Paste from the clipboard |
| `quick_select` | Open a visible URL by keyboard hint |
| `quick_select_copy` | Copy a visible URL by keyboard hint |

## Scrollback

| Action | What it does |
| --- | --- |
| `scrollback_line_up` | Scroll the active pane up one line |
| `scrollback_line_down` | Scroll the active pane down one line |
| `scrollback_page_up` | Scroll the active pane up one page |
| `scrollback_page_down` | Scroll the active pane down one page |
| `scrollback_top` | Scroll the active pane to the top |
| `scrollback_bottom` | Scroll the active pane to the bottom |
| `prompt_jump_prev` | Jump to the previous prompt in scrollback |
| `prompt_jump_next` | Jump to the next prompt in scrollback |

## Copy mode

Bind these with `{ mode = "copy_mode" }`. See [Copy mode](../copy-mode.md).

| Action | What it does |
| --- | --- |
| `copy_mode` | Enter copy mode |
| `copy_mode_search` | Open the search prompt in copy mode |
| `copy_mode_exit` | Exit copy mode |
| `copy_mode_move_left` | Move cursor one cell left |
| `copy_mode_move_right` | Move cursor one cell right |
| `copy_mode_move_up` | Move cursor one line up |
| `copy_mode_move_down` | Move cursor one line down |
| `copy_mode_line_start` | Move to line start |
| `copy_mode_line_end` | Move to line end |
| `copy_mode_page_up` | Move up one page |
| `copy_mode_page_down` | Move down one page |
| `copy_mode_top` | Jump to the top |
| `copy_mode_bottom` | Jump to the bottom |
| `copy_mode_begin_selection` | Begin a normal selection |
| `copy_mode_begin_block_selection` | Begin a block selection |
| `copy_mode_clear_selection` | Clear the current selection |
| `copy_mode_copy_selection` | Copy selection and exit copy mode |
| `copy_mode_search_next` | Jump to the next search match |
| `copy_mode_search_prev` | Jump to the previous search match |

## Misc

| Action | What it does |
| --- | --- |
| `command_palette` | Open the command palette |
| `reload_config` | Reload configuration |
| `font_size_increase` | Increase font size by 0.5 |
| `font_size_decrease` | Decrease font size by 0.5 |
| `font_size_reset` | Reset font size to the default |

## Custom actions

There are two ways to define custom actions.

### Register a named action

Use `hollow.action.register()` to add a named action that appears in
the command palette and can be bound to a key chord:

```lua
hollow.action.register("command_palette", {
  run = function() hollow.ui.command_palette.open() end,
  desc = "Open command palette",
  category = "general",
})

hollow.keymap.set("<leader>p", "command_palette", { desc = "command palette" })
```

The spec accepts these fields:

| Field | Type | Default | Description |
| --- | --- | --- | --- |
| `run` | `fun()` | required | Function to call when the action is triggered |
| `desc` | `string?` | `""` | Human-readable description shown in the command palette |
| `category` | `string?` | `"general"` | One of `"tab"`, `"pane"`, `"workspace"`, `"window"`, `"scroll"`, `"copy_mode"`, `"general"`, `"user"` |
| `workspace_targetable` | `boolean?` | `false` | If `true`, the command palette prompts for a target workspace before running |

### Bind a Lua function directly

A string action name is just shorthand for a Lua callback.
You can also pass a function directly to `hollow.keymap.set`:

```lua
hollow.keymap.set("<leader>ww", function()
  hollow.term.new_workspace({ name = "scratch" })
  hollow.ui.notify.info("Workspace ready", { ttl = 1200 })
end, { desc = "new scratch workspace" })
```

This style does not register the action in the command palette.

### API reference

```lua
--- Register a named action (appears in the command palette).
---@param name string
---@param spec HollowActionSpec
hollow.action.register(name, spec)

--- Return all registered actions, sorted by category then name.
---@return HollowPaletteEntry[]
hollow.action.list()

--- Call a named action directly.
hollow.action[name]()
```

The `HollowActionSpec` and `HollowPaletteEntry` types are defined in
[`types/hollow.lua`](../../types/hollow.lua).

See [Keybindings](../keybindings.md) for the chord syntax and the
modal binding model, and
[`hollow.keymap`](lua/keymap.md) for the keymap API.
