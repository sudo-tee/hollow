# `hollow.ui.workspace`

The workspace switcher is a high-level widget built on
[`hollow.ui.select`](ui.md) and
[`hollow.workspace`](workspace-api.md).
It merges currently open workspaces, recently used ones, and
configured discovery sources.

For the conceptual model see
[Panes, tabs, workspaces → Workspaces](../../panes-tabs-workspaces.md#workspaces).
For the LuaLS schema see
[`types/hollow.lua`](../../../types/hollow.lua) (`HollowUiWorkspaceItem`,
`HollowUiWorkspaceSource`, `HollowUiWorkspaceSwitcherOptions`).

## Functions

```lua
hollow.ui.workspace.configure(opts?)             -- persisted picker settings
hollow.ui.workspace.clear_cache()                -- reset discovery cache
hollow.ui.workspace.known_workspaces(force?)     -- items from known sources
hollow.ui.workspace.items(force?)                -- open + known merged
hollow.ui.workspace.open_switcher(opts?)         -- show the picker
hollow.ui.workspace.switcher(opts?)              -- alias of open_switcher
hollow.ui.workspace.topbar_button(opts?)         -- clickable bar node
hollow.ui.workspace.create(opts?)                -- create a new workspace
hollow.ui.workspace.rename(workspace?, opts?)     -- rename
hollow.ui.workspace.close(workspace?)            -- close
hollow.ui.workspace.open(opts)                   -- open an ad hoc item
```

## Workspace item shape

```lua
HollowUiWorkspaceItem = {
  id = string,
  name = string,
  cwd = string | nil,
  domain = string | nil,
  source = "open" | "user" | "local" | "wsl" | "ssh",
  is_active = boolean,
  is_open = boolean,
  open_index = integer | nil,
  last_opened_at = integer | nil,
}
```

String items passed to `open` are normalized into `{ name = ... }`
entries.

## Configuring the picker

```lua
hollow.ui.workspace.configure({
  prompt = "Workspaces",
  width = 96,
  height = nil,
  max_height = 18,
  backdrop = true,
  chrome = { bg = "#1f1f28", border = "#3a3a52", radius = 6 },
  theme = { ... },

  cache_ttl_ms = 5000,
  project_roots = { "C:/code" },

  known_workspaces = function() return { ... } end,
  sources = {
    { resolver = "local", domain = "pwsh", roots = { "C:/code" } },
    { resolver = "wsl",   domain = "wsl",  roots = { "/home/me/projects" } },
    { resolver = "ssh",   domain = "tower", roots = { "/home/me/projects" } },
  },

  format_item = function(workspace) return { ... } end,
  filter_item = function(workspace) return workspace.name ~= "scratch" end,
  workspace_color_fn = function(name) return { bg = "#...", fg = "#..." } end,

  status_column_width = 2,
  name_column_width = 24,
  column_gap = 2,

  rename_key = "<C-r>", rename_desc = "rename",
  close_key  = "<C-w>", close_desc  = "close",
  create_key = "<C-n>", create_desc = "create",
})
```

Changing `known_workspaces`, `sources`, or `project_roots` invalidates
the cache. You can also call `hollow.ui.workspace.clear_cache()`
directly.

## Sources

Each source declares how its items are discovered:

```lua
{
  resolver = "local" | "wsl" | "ssh",
  name = "Ubuntu",                    -- optional
  domain = "wsl",                     -- the domain new panes open in
  roots = { "/home/me/projects" },
  items = function() return { ... } end,    -- optional, merged with roots
  cwd_resolver = "wsl_unc" | function(cwd, item, source) ... end,
  default = false,
}
```

| Resolver | Behavior |
| --- | --- |
| `local` | Scans `roots` with `hollow.read_dir(...)` |
| `wsl` | Runs `wsl.exe` and lists child directories |
| `ssh` | Uses `hollow.term.run_domain_process(...)` to list directories on the SSH domain |

`cwd_resolver = "wsl_unc"` is useful when picker items come from
Windows UNC paths like `\\wsl$\Ubuntu\home\me\Projects` but the
launched shell should `cd` to the Linux-side path.

## Discovery and caching

- Open workspaces are always live
- Discovered workspaces are cached for `cache_ttl_ms`
- `force_refresh = true` bypasses the cache once
- `clear_cache()` resets the cached discovery results

Recent activity timestamps are updated from terminal events
(tab activation, cwd change, title change, tab close).

## Opening and switching

`open_switcher()` shows the picker. Default actions:

- Primary action: switch to / open the selected workspace
- `rename_key`: rename the active workspace (default `<C-r>`)
- `close_key`: close the active workspace (default `<C-w>`)
- `create_key`: create a new workspace (default `<C-n>`)

Selection behaviour:

- Already-open workspaces: switch to them
- Known workspaces: open with their `cwd` and `domain`
- `source = "ssh"` workspaces: open in the target domain and send a
  `cd` command
- User-defined items with a `cwd` resend `cd` when re-activated

`open(opts)` is the programmatic entry point. Pass an item directly
or specify `source = "..."` plus an item payload to resolve through
a configured source first.

## Top-bar button

Renders a clickable workspace badge for the top bar. By default shows
the current workspace name (bold) with an index/count suffix (dimmed),
colorized by workspace name.

```lua
hollow.ui.workspace.topbar_button(opts?)
```

Options:

```lua
{
  text      = "custom text",          -- plain text override (skips prefix/suffix)
  prefix    = " ",                    -- before the name (default "  ")
  suffix    = " 2/4",                  -- after the name (default " index/count")
  style     = { fg = "...", bg = "..." },
  colorize  = true,                    -- pick bg/fg from workspace name hash
  id        = "my-button",
  switcher  = { ... },                 -- passed to open_switcher on click
}
```

When `text` is set, returns a single span node. Otherwise returns two
spans (name bold, suffix dimmed). Both have `on_click` wired to
`open_switcher`.

**With `bar.workspace`** (default conf behavior):

```lua
workspace = {
  format = function(ws)
    return hollow.ui.workspace.topbar_button({ colorize = true })
  end,
}
```

**Standalone in a custom bar:**

```lua
hollow.ui.topbar.mount(hollow.ui.topbar.new({
  render = function()
    return {
      hollow.ui.workspace.topbar_button(),
      hollow.ui.spacer(),
      hollow.ui.bar.time("%H:%M"),
    }
  end,
}))
```

## Examples

WSL source with UNC paths:

```lua
hollow.ui.workspace.configure({
  sources = {
    {
      name = "Ubuntu",
      resolver = "local",   -- not "wsl" if roots are UNC paths
      domain = "wsl",
      cwd_resolver = "wsl_unc",
      roots = {
        "\\\\wsl$\\Ubuntu\\home\\me\\Projects",
      },
    },
  },
})
```

Custom picker rows:

```lua
hollow.ui.workspace.configure({
  format_item = function(ws)
    return {
      hollow.ui.span(ws.is_active and "* " or "  "),
      hollow.ui.span(ws.name, { bold = ws.is_active }),
      hollow.ui.span(ws.cwd and ("  " .. ws.cwd) or "", { fg = "#727169" }),
    }
  end,
})
```

Hide items:

```lua
hollow.ui.workspace.configure({
  filter_item = function(ws) return ws.name ~= "scratch" end,
})
```

Customize the top-bar button color (by default derived from the workspace name via HSL hash):

```lua
hollow.ui.workspace.configure({
  workspace_color_fn = function(name)
    if name == "default" then return { bg = "#223344", fg = "#ffffff" } end
    return nil  -- fall back to the default HSL-based generator
  end,
})
```

Return `{ bg, fg }` to override, or `nil` to let the default generator handle it.

## See also

- [Custom UI](../../custom-ui.md#workspace-switcher)
- [WSL → WSL workflow patterns](../../platforms/wsl.md#wsl-workflow-patterns)
- [`hollow.workspace`](workspace-api.md) — workspace bootstrap
