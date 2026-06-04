# Panes, tabs, workspaces

Hollow organizes the screen into three nested primitives.
This page defines them, shows the Lua API for each, and lists the default
keymaps.

For the full Lua surface see
[`hollow.term`](reference/lua/term.md),
[`hollow.ui.workspace`](reference/lua/workspace.md), and
[`hollow.workspace`](reference/lua/workspace-api.md).
For the keymap surface see [Keybindings](keybindings.md).

## The three primitives

| Primitive | Lifetime | What it contains |
| --- | --- | --- |
| Workspace | Lives until closed | One or more tabs |
| Tab | Lives until closed | One or more panes (tiled + optional floating) |
| Pane | Lives until closed | One shell process + scrollback |

A typical flow: open a workspace, open a tab in it, split the tab into
panes. A workspace is the unit of "I'm switching contexts" — close a
workspace, lose the tabs and panes inside it.

## Workspaces

Workspaces are first-class. The default keymap binds `<C-A-n>` to
`new_workspace`, `<C-A-p>` to `workspace_switcher`, and `<C-A-r>` to
`rename_workspace`. The workspace switcher is a filterable picker that
combines open workspaces, recently used ones, and configured discovery
sources.

From Lua:

```lua
local hollow = require("hollow")

hollow.term.new_workspace({
  name = "backend",
  cwd  = "C:/code/backend",
  domain = "pwsh",
})

hollow.term.set_workspace_name("frontend")
hollow.term.set_workspace_default_cwd("/srv/frontend")

hollow.term.next_workspace()
hollow.term.prev_workspace()
```

Workspaces carry an `id`, an `index` (1-based), a `name`, and a `domain`.
The active workspace is the one your new tabs land in.

The discovery surface is `hollow.ui.workspace.configure(...)`.
See [Workspace switcher](reference/lua/workspace.md) for picker options
like `sources`, `project_roots`, `cache_ttl_ms`, `format_item`, and
`filter_item`.

## Tabs

Tabs are inside a workspace. New tabs use the active workspace's
`default_domain` unless you pass one explicitly.

```lua
hollow.term.new_tab({ domain = "wsl", title = "server" })
hollow.term.focus_tab(tab.id)
hollow.term.close_tab(tab.id)
hollow.term.next_tab()
hollow.term.prev_tab()
hollow.term.set_title("frontend", tab.id)
```

`HollowTab` snapshots expose `id`, `title`, `index`, `is_active`, and a
list of panes:

```lua
local tab = hollow.term.current_tab()
for _, p in ipairs(tab.panes) do
  print(p.id, p.foreground_process, p.cwd)
end
```

## Panes

Panes are shells. Create one with `hollow.term.split_pane(opts)`:

```lua
hollow.term.split_pane({
  direction = "vertical",   -- or "horizontal"
  ratio = 0.4,              -- size of the new pane (0..1)
  domain = "wsl",
  cwd = "C:/code/side",
  command = "npm run dev",
  command_mode = "send",    -- or "spawn" (no echo in pane)
  close_on_exit = false,
  floating = false,         -- true to skip the tiled layout
  fullscreen = false,       -- true to maximize after creation
  -- x, y, width, height in 0..1 for floating panes
})
```

`split_pane` accepts either `(direction, opts)` or a single options table.

### Floating and maximized

A *floating* pane is a child of the tab but does not participate in the
tiled split tree. Bounds are normalized 0..1 in window space.

```lua
hollow.term.split_pane({
  floating = true,
  x = 0.1, y = 0.1, width = 0.6, height = 0.7,
})
hollow.term.set_floating_pane_bounds(pane_id, { x = 0.05, y = 0.1, width = 0.5, height = 0.6 })
```

A *maximized* pane covers the tiled area; other tiled panes are hidden
unless `show_background = true` is passed to `toggle_pane_maximized`.

### Move and resize

```lua
hollow.term.move_pane("left")          -- or "right", "up", "down"
hollow.term.move_pane({ direction = "right", amount = 0.1 })

hollow.term.resize_pane("left", 0.05)  -- axis, delta (0..1)
hollow.term.resize_pane({ axis = "right", delta = -0.05 })
```

`move_pane` reorders tiled panes; for floating panes it nudges the bounds.

### Pane identity

Panes are addressable by `id`. You can also tag them and target by tag:

```lua
hollow.term.set_pane_tags({ "editor" }, pane_id)
hollow.term.add_pane_tag("watch", pane_id)
hollow.term.remove_pane_tag("editor", pane_id)

-- later
hollow.term.send_text("hello", pane_id)
hollow.term.close_pane(pane_id)
hollow.term.focus_pane_by_id(pane_id)
```

This is what makes `hollow-cli pane split --tag editor` and
`hollow-cli pane close --tag editor` work — see
[Native CLI](reference/cli/native.md).

### Pane text and process

```lua
local text = hollow.term.get_pane_text(pane_id)        -- scrollback contents
local tags = hollow.term.get_pane_tags(pane_id)
hollow.term.set_pane_foreground_process(pane_id, "vim")
```

`HollowPane` snapshots expose `id`, `pid`, `domain`, `cwd`, `title`,
`is_focused`, `is_floating`, `is_maximized`, `has_bell`, `frame`, and
`size`. Snapshots are read-only values, not live references.

## Async sequencing

Most operations are queued on the frame thread.
`split_pane`, `new_tab`, and `new_workspace` accept an `on_complete`
callback that fires after the operation runs:

```lua
hollow.term.split_pane({
  direction = "vertical",
  on_complete = function(result)
    if result.success then
      print("created pane", result.pane_id)
    end
  end,
})
```

For sequential flows, use `hollow.async.run` and
`hollow.async.await`:

```lua
hollow.async.run(function()
  local split = hollow.async.await(function(resolve)
    hollow.term.split_pane({
      direction = "vertical",
      on_complete = resolve,
    })
  end)
  if split.success then
    hollow.term.set_pane_tags({ "editor" }, split.pane_id)
  end
end)
```

See [`hollow.async`](reference/lua/async.md).

## Default keymap summary

Full table on [Keybindings](keybindings.md).
The shape of the layout primitives maps to the keymap groups:

- Tabs → tabs section
- Panes → panes / focus / move / resize sections
- Workspaces → workspaces section
