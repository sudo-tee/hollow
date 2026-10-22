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
