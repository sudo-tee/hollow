# `hollow.term`

Read and mutate tabs, panes, and workspaces; send text to panes; run
domain processes.

For the conceptual model see
[Panes, tabs, workspaces](../../panes-tabs-workspaces.md).
For the LuaLS schema see
[`types/hollow.lua`](../../../types/hollow.lua) (`HollowPane`,
`HollowTab`, `HollowWorkspace`, `HollowDomain`).

## Reading state

```lua
local tab       = hollow.term.current_tab()       -- HollowTab or nil
local pane      = hollow.term.current_pane()      -- HollowPane or nil
local tabs      = hollow.term.tabs()              -- HollowTab[]
local pane      = hollow.term.pane_by_id(id)      -- HollowPane or nil
local tab       = hollow.term.tab_by_id(id)       -- HollowTab or nil
local ws        = hollow.term.current_workspace() -- HollowWorkspace or nil
local workspaces = hollow.term.workspaces()       -- HollowWorkspace[]
local ws        = hollow.term.workspace_by_id(id) -- HollowWorkspace or nil
local domain    = hollow.term.current_domain()    -- HollowDomain or nil
```

Snapshots are read-only values.

### Program status (OSC 7501)

`pane.program_status` is a list of reports sent by programs that implement
OSC 7501. Each record has `id`, `state` (`idle`, `working`, `done`, `blocked`,
`error`), `kind` (`none`, `permission`, `question`, `auth`), optional
`progress` (0–100), `app`, `title`, `message`, and `attention`. `app` inherits from the
nearest ancestor record when omitted. Reports replace whole records; a
clear removes its subtree. The list is ordered by last update, oldest first,
and limited to 128 records per pane. Display strings are bounded and stripped
of control and invisible formatting characters; still treat them as untrusted
plain text, not markup, and identify their source pane when displaying them.

The default tab bar, mux navigator, and workspace switcher show task-state badges.
Mux navigator pane rows show their own status; tab/workspace rows aggregate all
their panes, even when collapsed. Open overlays read live status on each render.
Custom bars can inspect records:

```lua
hollow.events.on("term:program_status_changed", function(event)
  for _, task in ipairs(event.pane.program_status) do
    -- task.state, task.kind, task.progress, task.message
  end
end)
```

Changes within one host tick are coalesced into one event with the final state.
Prompt start removes idle/working records, but retains blocked attention until
replaced/cleared or the child exits. Child exit removes idle/working/blocked
records. Focusing a pane acknowledges its unread blocked/error attention without
removing any status records. New blocked/error reports set `attention = true`
only while the pane is inactive; leaving the pane does not re-arm old reports.
Done/error records persist until replaced/cleared; full reset clears all records.
Unread status shares the existing OSC bell attention indicator, including the
global top-bar bell and its attention-filtered navigator, from any workspace.
Tabs and navigator panes reuse their existing markers rather than adding another
icon. No audible bell is triggered and OSC bell state is unchanged.
This does not infer task status from terminal text or replace shell HTP events.

For a shell-side smoke test:

```sh
printf '\033]7501;state=working:app=demo:progress=25\033\\'
```

Normal prompt-jump actions use Ghostty's native previous/next prompt navigation
relative to the viewport top (next no longer skips the entire visible page).
Copy-mode cursor navigation retains its existing behavior.

## Tab operations

```lua
hollow.term.new_tab(opts)              -- create a tab
hollow.term.focus_tab(id)              -- focus by id
hollow.term.close_tab(id)              -- close by id
hollow.term.next_tab()
hollow.term.prev_tab()
hollow.term.set_title(title, tab_id?)  -- set tab title
```

`new_tab` options:

```lua
{
  cmd = "ls",                  -- run a command after the shell starts
  cwd = "/path",
  env = { FOO = "bar" },
  title = "server",
  domain = "UbuntuWSL",
  command = "ls -la",          -- alias of `cmd` for symmetry with split_pane
  on_complete = function(result) ... end,  -- result.success, result.tab_id
}
```

## Pane operations

### Create and split

```lua
hollow.term.split_pane(opts)
```

`split_pane` accepts either `(direction, opts)` or a single options
table:

```lua
{
  direction = "horizontal" | "vertical",
  ratio = 0.4,                  -- size of the new pane (0..1)
  domain = "UbuntuWSL",
  cwd = "/path",
  command = "npm run dev",
  command_mode = "send",        -- or "spawn"
  close_on_exit = false,
  floating = false,             -- floating pane
  fullscreen = false,           -- maximize after creation
  x = 0.1, y = 0.1,             -- normalized floating bounds
  width = 0.6, height = 0.7,
  tag = "editor",               -- single tag
  tags = { "editor", "main" },  -- or multiple
  on_complete = function(result) ... end,  -- result.success, result.pane_id
}
```

- `command_mode = "send"` (default) types the command into the shell,
  so it echoes in the pane.
- `command_mode = "spawn"` launches the shell with the command
  directly, so it does not appear as typed input. The shell is not
  the user's default shell in this mode.

### Floating and maximized

```lua
hollow.term.toggle_pane_maximized(pane_id?, { show_background = true })
hollow.term.set_pane_floating(pane_id, true)
hollow.term.set_floating_pane_bounds(pane_id, {
  x = 0.05, y = 0.1, width = 0.5, height = 0.6,
})
```

### Move and resize

```lua
hollow.term.move_pane("left")                            -- string form
hollow.term.move_pane({ direction = "right", amount = 0.1 })
hollow.term.resize_pane("left", 0.05)                    -- axis, delta
hollow.term.resize_pane({ axis = "right", delta = -0.05 })
```

`move_pane` reorders tiled panes; for floating panes it nudges the
bounds by `amount` (default `0.08`) in normalized window space.

### Focus

```lua
hollow.term.focus_pane("left")          -- by direction
hollow.term.focus_pane_by_id(pane_id)
```

### Close

```lua
hollow.term.close_pane(pane_id?)        -- default: current pane
```

### Tags

```lua
hollow.term.set_pane_tags({ "editor" }, pane_id?)
hollow.term.add_pane_tag("watch", pane_id?)
hollow.term.remove_pane_tag("watch", pane_id?)
hollow.term.get_pane_tags(pane_id?)     -- string[]
```

Tags identify panes. They are what the
[native CLI](../cli/native.md) targets with `--tag`.

### Text and process

```lua
hollow.term.bell(pane_id?)
hollow.term.send_text("hello", pane_id?)
hollow.term.get_pane_text(pane_id?)             -- scrollback contents
hollow.term.set_pane_foreground_process(pane_id, "vim")
```

## Workspace operations

```lua
hollow.term.new_workspace(opts)         -- create
hollow.term.close_workspace(id?)
hollow.term.next_workspace()
hollow.term.prev_workspace()
hollow.term.switch_workspace(index)     -- 1-based
hollow.term.set_workspace_name(name)
hollow.term.set_workspace_default_cwd(cwd)
hollow.term.reload_config()
hollow.term.scroll(where)               -- "top" | "bottom" | "page-up" | "page-down"
hollow.term.set_theme(name)             -- switch active theme
```

`new_workspace` options:

```lua
{
  cwd = "/path",
  domain = "UbuntuWSL",
  command = "ls",
  name = "backend",
  on_complete = function(result) ... end,  -- result.success, result.workspace_index
}
```

## Run a process in a domain

```lua
local ok, stdout, stderr = hollow.term.run_domain_process(
  { "git", "status" }, domain
)
```

`domain` defaults to the current pane's domain. The function resolves
the configured domain shell and runs the argv through it; the return
shape mirrors `hollow.process.run_child_process`.

## Snapshot shapes

```lua
HollowPane = {
  id = integer,
  pid = integer,
  domain = string | nil,
  cwd = string,
  title = string,
  is_focused = boolean,
  is_floating = boolean,
  is_maximized = boolean,
  has_bell = boolean,
  busy = boolean,
  running = { command, ms } | nil,
  last = { command?, status?, took_ms? } | nil,
  frame = { x, y, width, height },
  foreground_process = string,
  tags = string[],
  size = { rows, cols, width, height },
}

HollowTab = {
  id = integer,
  title = string,
  index = integer,   -- 1-based
  is_active = boolean,
  panes = HollowPane[],
  pane  = HollowPane,  -- the active pane in the tab
}

HollowWorkspace = {
  id = integer,
  index = integer,   -- 1-based
  name = string,
  domain = string | nil,
  is_active = boolean,
}
```

## See also

- [Panes, tabs, workspaces](../../panes-tabs-workspaces.md)
- [Keybindings](../../keybindings.md) — the default actions
- [Native CLI](../cli/native.md) — host-side equivalent
