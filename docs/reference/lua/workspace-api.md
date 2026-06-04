# `hollow.workspace`

Workspace bootstrap specs: load JSON, open a workspace, and round-trip
the current state.

For the higher-level switcher (open workspaces + discovery + caching)
see [`hollow.ui.workspace`](workspace.md).

## Functions

```lua
hollow.workspace.bootstrap(spec, opts?)               -- open from a spec
hollow.workspace.load(path)                           -- load JSON from disk
hollow.workspace.load_and_bootstrap(path, opts?)      -- load + bootstrap
hollow.workspace.export_current()                      -- current state as spec
hollow.workspace.export_to(path)                      -- write to disk
hollow.workspace.project_local_path(dir?)             -- path to .hollow/workspace.json
hollow.workspace.resolve_auto_bootstrap_path()        -- for the active cwd
hollow.workspace.auto_bootstrap()                      -- run auto-bootstrap
```

## Bootstrap spec

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
  cwd = string | nil,
  domain = string | nil,
  command = string | nil,
  command_mode = "send" | "spawn" | nil,
  close_on_exit = boolean | nil,
  floating = boolean | nil,
  fullscreen = boolean | nil,
  x = number | nil, y = number | nil,
  width = number | nil, height = number | nil,
  size = number | nil,        -- ratio of additional panes
  direction = "horizontal" | "vertical" | nil,
  main = boolean | nil,       -- or `default`
  default = boolean | nil,
}
```

## Behaviour in v1

- File format is JSON.
- Project-local files live at `.hollow/workspace.json`.
- Global named layouts resolve under the user config dir at
  `layouts/<name>.json`.
- Relative `cwd` values resolve against the project root for
  `.hollow/workspace.json`.
- `size` maps to split `ratio` for additional panes in a tab.
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

Auto-bootstrap (called by Hollow at startup when
`config.workspace.auto_bootstrap = "always"`):

```lua
hollow.workspace.auto_bootstrap()
```

The lookup order is the project-local `.hollow/workspace.json` rooted
at the active pane cwd, then `config.workspace.default_layout`.

## See also

- [Configuration](../../configuration.md#workspace-bootstrap)
- [`hollow.ui.workspace`](workspace.md) — switcher and discovery
- [Plugin authoring](../../examples/plugin-authoring.md)
