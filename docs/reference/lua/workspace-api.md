# `hollow.workspace`

Workspace bootstrap specs: load JSON, open a workspace, and round-trip
the current state.

For the higher-level switcher (open workspaces + discovery + caching)
see [`hollow.ui.workspace`](workspace.md).

## Functions

```lua
hollow.workspace.bootstrap(spec, opts?)               -- open from a spec
hollow.workspace.load(path)                           -- load JSON from disk
hollow.workspace.load_host(host, path, opts?)          -- promise: bounded read-only host JSON
hollow.workspace.load_and_bootstrap(path, opts?)      -- load + bootstrap
hollow.workspace.export_current()                      -- current state as spec
hollow.workspace.export_to(path)                      -- write to disk
hollow.workspace.project_local_path(dir?)             -- path to .hollow/workspace.json
hollow.workspace.resolve_auto_bootstrap_path()        -- for the active cwd
hollow.workspace.auto_bootstrap()                      -- run auto-bootstrap
hollow.workspace.bootstrap_project(dir?, domain?)      -- load project-local layout
hollow.workspace.bootstrap_project_async(dir?, domain?) -- promise: host-native project/default layout
```

## Bootstrap spec

`load_host` uses the same `hollow.host` filesystem API for local or remote reads,
preserves path bytes and returns a cancellable promise. `opts.max_bytes` defaults
to 1 MiB (maximum 1 MiB); oversized/invalid documents reject rather than truncate.
It never probes local paths, runs commands or creates panes. Remote pane/domain
policy must be chosen separately before calling `bootstrap`; loading a spec does
not authorize its commands. Existing synchronous local loading is unchanged.
See [host API](host.md#read-only-workspace-loading).

```json
{
  "name": "my-project",
  "tabs": [
    {
      "name": "editor",
      "panes": [
        { "cwd": ".", "command": "nvim", "main": true }
      ]
    },
    {
      "name": "backend",
      "layout": "vertical",
      "panes": [
        { "cwd": "server", "command": "npm run dev" },
        { "cwd": "server", "command": "npm test --watch", "size": 0.25 }
      ]
    }
  ]
}
```

Shape:

```lua
HollowWorkspaceBootstrapSpec = {
  name = string | nil,
  tabs = HollowWorkspaceBootstrapTab[],
}

HollowWorkspaceBootstrapTab = {
  name = string | nil,
  layout = "horizontal" | "vertical" | nil,
  panes = HollowWorkspaceBootstrapPane[],
}

HollowWorkspaceBootstrapPane = {
  lua = string | nil,         -- registered GUI Lua factory instead of a terminal
  args = table | nil,         -- copied JSON factory args
  title = string | nil,       -- Lua pane title override
  tags = string[] | nil,
  cwd = string | nil,
  domain = string | nil,
  command = string | nil,
  command_mode = "send" | "spawn" | nil,
  close_on_exit = boolean | nil,
  floating = boolean | nil,
  fullscreen = boolean | nil,
  hidden = boolean | nil,     -- created, then hidden after the tab is built
  x = number | nil, y = number | nil,
  width = number | nil, height = number | nil,
  size = number | nil,        -- ratio of additional panes
  direction = "horizontal" | "vertical" | nil,
  edge = "left" | "right" | "top" | "bottom" | nil, -- terminal panes only
  main = boolean | nil,       -- or `default`
  default = boolean | nil,
}
```

### Lua pane leaves

Register a factory in the GUI config with
[`hollow.ui.pane.register`](ui.md#factories-and-persistence), then reference it
in the same layout as terminal leaves:

```json
{
  "name": "Tools",
  "tabs": [{
    "name": "Tasks",
    "panes": [
      { "lua": "tasks", "args": { "title": "Build" }, "main": true },
      { "lua": "tasks", "args": { "title": "Tests" }, "size": 0.4 }
    ]
  }]
}
```

Lua leaves use `direction`, `size`, `main`, `tags`, floating bounds and
`fullscreen`, but do not launch terminal commands. Lua-first tabs/workspaces
are created directly without temporary PTYs. With no `replace_current`, a
Lua-first bootstrap adds a tab and preserves the existing tab. The
`kind = "lua", module = "tasks"` spelling is also accepted.

`load`/`load_host` only read JSON; they do not invoke factories. Bootstrap
requires registered factories and valid bounded JSON args; unknown factories
raise an error rather than launching a terminal. Treat bootstrap as executable
configuration: factories may have effects, just as terminal leaves may run
commands. Loading an untrusted layout does not authorize bootstrapping it.

Export includes named Lua leaves with creation args, titles, tags, focus, split
ratios, floating geometry, edge placement and hidden state. A pane is exported
with `edge` only while it is still docked to the window edge it was created on;
bootstrap creates edge panes after every other pane in the tab, in order, so
each wraps the whole layout again. Hidden panes (terminal or Lua) are
still created and run; bootstrap hides them only after every pane in the tab
exists, so split order and ratios match the export. A hidden pane cannot take
focus, so `hidden` wins over `main`. It omits anonymous Lua panes and tabs left empty
by their omission. Neither functions nor live Lua state are serialized. File
bootstrap creates new IDs; config reload instead keeps IDs/layout and rebuilds
owners. Workspace layouts remain linear, not arbitrary nested split trees.
See [example layout](../../examples/lua-pane-workspace.json).

## Behaviour in v1

- File format is JSON.
- Project-local files live at `.hollow/workspace.json`.
- Global named layouts resolve under the user config dir at
  `layouts/<name>.json`.
- Relative `cwd` values resolve against the project root for
  `.hollow/workspace.json`.
- `size` maps to split `ratio` for additional panes in a tab.
- Exported additional panes preserve their current split `direction` and `size` ratio.
- One pane may set `main: true` (or `default: true`) to receive
  focus after bootstrap.
- Tabs are linear layouts today; nested split trees are not supported
  yet.

## Examples

Load and bootstrap manually:

```lua
local spec = hollow.workspace.load("/path/to/.hollow/workspace.json")
hollow.workspace.bootstrap(spec, { base_dir = "/path/to" })
```

Bootstrap from a known name:

```lua
hollow.workspace.bootstrap({
  name = "scratch",
  tabs = { { panes = { { cwd = "/tmp" } } } },
})
```

Export the current workspace:

```lua
hollow.workspace.export_to("/tmp/workspace.json")
```

Load a project-local layout into a newly created workspace:

```lua
hollow.workspace.bootstrap_project("/path/to/project")
```

Auto-bootstrap (called by Hollow at startup when
`config.workspace.auto_bootstrap = "always"`):

```lua
hollow.workspace.auto_bootstrap()
```

The lookup order is the project-local `.hollow/workspace.json` rooted
at the active pane cwd, then `config.workspace.default_layout`.

Workspace-switcher opens use `bootstrap_project_async`: project layouts are read
through the terminal domain's configured host using guest-native paths, without
WSL UNC conversion. The domain defaults to the active pane's domain. Connections
are shared with workspace discovery when descriptors match. Global default layouts
are read through the client-local filesystem worker only after the project layout
is absent; host connection failures do not fall back to local project paths.
The promise resolves `true` after starting bootstrap, or `false` if
neither layout exists or the active workspace/pane changed before loading finished.
Invalid layouts and I/O errors reject. WSL opens still wait for shell cwd resolution
where configured. The older synchronous `bootstrap_project` and startup/export
helpers remain unchanged; use the asynchronous API for host-backed project loading.

## See also

- [Configuration](../../configuration.md#workspace-bootstrap)
- [`hollow.ui.workspace`](workspace.md) — switcher and discovery
- [Plugin authoring](../../examples/plugin-authoring.md)
