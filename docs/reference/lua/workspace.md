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
  source = "open" | "user" | "host",
  is_active = boolean,
  is_open = boolean,
  has_bell = boolean,
  program_status_badge = string | nil,
  program_status_state = string | nil,
  program_status_attention = boolean | nil,
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

  known_workspaces = function() return { ... } end,
  sources = {
    { host = connected_host, roots = { "/home/me/projects" } },
    { domain = "pwsh", roots = { "C:/code" } }, -- native-local host by default
    { host = { type = "wsl", distro = "Ubuntu" }, domain = "UbuntuWSL", roots = { "/home/me/projects" } },
    { host = { type = "ssh", destination = "tower" }, domain = "tower", roots = { "/home/me/projects" } },
  },

  format_item = function(workspace) return { ... } end,
  filter_item = function(workspace) return workspace.name ~= "scratch" end,
  workspace_color_fn = function(name) return { bg = "#...", fg = "#..." } end,

  status_column_width = 2,
  name_column_width = 24,
  column_gap = 1,

  rename_key = "<C-r>", rename_desc = "rename",
  close_key  = "<C-w>", close_desc  = "close",
  create_key = "<C-n>", create_desc = "create",
  refresh_key = "<C-l>", refresh_desc = "refresh",
})
```

Changing `known_workspaces`, `sources`, or `project_roots` invalidates
the cache. You can also call `hollow.ui.workspace.clear_cache()`
directly.

## Sources

All directory discovery uses asynchronous `host.fs.list/stat`, including local
sources. The workspace manager does not run `ls`, spawn WSL/SSH commands per scan,
or probe guest paths through the local filesystem.

```lua
{
  host = { type = "wsl", distro = "Ubuntu" }, -- or an already-ready hollow.host
  name = "Ubuntu",                    -- optional
  domain = "UbuntuWSL",                     -- the domain new panes open in
  roots = { "/home/me/projects" },
  items = function() return { ... } end,    -- optional, merged with roots
  default = false,
}
```

Descriptors support `type = "local" | "wsl" | "ssh" | "podman" | "docker"`.
Guest descriptors accept the corresponding [`hollow.host`](host.md) connector
options, with optional `id` (allocated automatically when omitted). Omitted `host`
uses the shared native-local host, except when converting legacy guest settings.
An explicit host takes precedence over legacy resolver/domain inference.

For Podman or Docker running **inside WSL**, put `via` inside the source's
`host` descriptor (not on the source itself):

```lua
{
  name = "Container projects",
  host = {
    type = "podman", -- or "docker"
    container = "dev",
    via = { type = "wsl", distro = "Ubuntu-26.04", user = "me" },
  },
  domain = "ContainerDev",
  roots = { "/work" }, -- paths inside the container
}
```

`via.distro` is required; `via.user` and `via.wsl` (the Windows WSL launcher)
are optional. The WSL user runs the container CLI; it does not change the
container's configured user. Without `via`, the CLI runs on the Hollow client.

The source's `host` controls discovery only. Define `domains.ContainerDev` with
an explicit container shell and the same `host` descriptor to open panes in that
container. Without a source `domain`, opening inherits the current pane's domain;
it does not infer a terminal target from `host`. See the
[complete Podman-through-WSL recipe](../../examples/ui-recipes.md#workspace-switcher-with-podman-inside-wsl).

Equivalent descriptors share one pending/ready connection across sources and
refreshes. The manager closes owned guest connections when their last source is
removed; it never closes caller-supplied ready hosts or the shared native-local
host. Merely clearing discovery caches does not close a healthy connection.
Disabled sources (`default = false`) and sources without roots do not connect.

Guest bootstrap automatically deploys the bundled Linux agent into the selected
guest user's versioned cache, or verifies/reuses an existing copy. The bundle must
be installed with Hollow; nothing is downloaded. Native-local operations need no
agent process. WSL distributions and containers must already exist (containers
must be running), SSH trust/authentication must already be configured, and required
guest utilities are not installed. Connector/platform qualification remains as
documented in [`hollow.host`](host.md); making discovery host-first does not
qualify additional platforms or switch any terminal PTY backend.

Failed connections produce a warning and never fall back to local/shell scanning.
After fixing configuration/connectivity, `clear_cache()` explicitly retries failed
or disconnected managed hosts. Polling and force-refresh never silently reconnect
or replay commands. Caller-owned hosts require caller-managed reconnect.

Host-backed roots and returned
names are passed through as exact byte strings; they are not trimmed, converted
from WSL UNC paths, or probed with local filesystem/process APIs. Listing is
paginated (256 entries per page, at most 4096 entries per root) and directory
checks are limited to four concurrent `stat` requests. `known_workspaces()`
and `items()` stay synchronous: while a scan is pending, they return cached
results and later refresh after completion, including in an already-open picker.
The terminal `domain` is independent: it controls where new panes open, not how
files are accessed. Existing project layout/bootstrap/export APIs are unchanged.

### Migrating legacy configuration

`resolver`, `cwd_resolver`, and `project_roots` are deprecated. A temporary adapter
converts unambiguous settings **in memory**, logs a migration warning and shows it
once per legacy source per runtime. It never rewrites user Lua files. Conversion
to a guest host may deploy the bundled agent; the warning explicitly says so.

* WSL UNC roots (`\\wsl$\Ubuntu\...` / `\\wsl.localhost\Ubuntu\...`) select
  that explicit distribution and become Linux paths. Mixed distributions, mixed
  UNC/native roots, and mismatched domains are rejected; split them into sources.
* `resolver = "wsl"` uses a structured domain's `wsl_distro`, or the legacy explicit
  distro in `name`. `resolver = "ssh"` requires a structured native SSH domain with
  `ssh.alias` or `ssh.host`; it never parses arbitrary shell commands or silently
  changes a WSL-routed SSH client's credential/trust environment.
* Legacy sources without an explicit host can use structured guest domain settings;
  a plain local source uses the native-local host. `project_roots` becomes an implicit
  source when `known_workspaces` is not supplied.
* `cwd_resolver = "wsl_unc"` and custom callbacks run only in the compatibility
  adapter. New configurations should provide host-native paths directly.

Ambiguous sources are disabled with an actionable warning, never guessed. This
adapter is transitional, not a second discovery backend; update configuration now
before a future breaking removal.

## Discovery and caching

- Open workspaces are always live
- Discovered workspaces are cached for `cache_ttl_ms`
- `force_refresh = true` bypasses the cache once
- `clear_cache()` resets the cached discovery results

Recent activity timestamps are updated from terminal events
(tab activation, cwd change, title change, tab close).

## Opening and switching

Workspaces with OSC bell or unread program-status attention in any pane, across
all tabs, appear first and share one yellow bell icon in the default formatter.
Within each attention group, existing workspace ordering is preserved.
Bell state is refreshed each time the picker opens or `items()` is called.
Custom `format_item` callbacks can use `workspace.has_bell` to render their own indicator.

Open workspaces also show a colored OSC 7501 status icon beside the name. Status aggregates
all panes across all tabs, using the same priority as tab-bar badges:
error → blocked → working → done; idle is hidden. Working animates and shows any
reported percentage; blocked kinds have distinct amber icons, done is green, and
error is red. Badges update while the switcher is open,
without resetting search/selection or rescanning discovery sources. Closed known
workspaces have no task status. Custom formatters can use
`workspace.program_status_badge` (including its trailing space) and
`workspace.program_status_state` for state-specific styling. Inactive workspaces
retain live badges. Unread blocked/error attention also shows the bell icon in
the switcher and existing global top-bar attention button. Navigator pane rows
and tabs reuse their existing attention marker; no separate status bell is added.
This does not ring or change OSC bell state. Focusing the source pane clears its attention
indicator, not its status badge; new inactive reports re-arm attention.
Done/error badges dismiss on the first keypress delivered to their source pane,
not while navigating or selecting a workspace in the picker.
Custom formatters can use `workspace.program_status_attention` for this indicator.

`open_switcher()` shows the picker. Default actions:

Open workspaces appear under **OPEN**, followed by domain sections for detached sessions and known/discovered projects.
Search spans every loaded section, including domain names and session IDs.
Domain headings reuse command-palette section rows; focus one and press `<C-n>`, or click its trailing **+**, to create in that domain.
The new workspace becomes persistent only if that domain already has `persist = true`.
Enter or click on a heading toggles collapse; search temporarily reveals matching children.
Activate the explicit load row to load sessions and configured SSH project sources without closing the picker.
Domain headings are flat titles in a brighter shade of their pill hue (**OPENED** uses the theme magenta), with **loading…** while the domain lists sessions or projects.
A search whose matches all fall in one section hides that heading.
Open rows use compact indentation; current/attention markers and colored work indicators share the leading column, while session badges remain beside names.
Domain pills are retained for mixed-domain open rows; other rows inherit their heading instead of repeating the pill.
Name/path columns truncate within reserved widths rather than pushing pills out of view.

- Primary action: switch to / open the selected workspace
- `rename_key`: rename the active workspace (default `<C-r>`)
- `close_key`: close the selected open workspace (default `<C-x>`); headings and status rows are not closable
- `create_key`: create a new workspace in the selected row/header's domain (default `<C-n>`)
- `refresh_key`: list persistent sessions and rescan sources (default `<C-l>`); shown for persistence or configured SSH project sources

Selection behaviour:

- Already-open workspaces: switch to them
- Known workspaces: open with their `cwd` and `domain`
- `source = "ssh"` workspaces: open in the target domain and send a
  `cd` command
- User-defined items with a `cwd` resend `cd` when re-activated
- `source = "session"` rows: attach the persistent session; one attached in another window asks before taking over
- `source = "session_load"` / `"project_load"` rows: load that domain's sessions and configured SSH projects, keeping the switcher open

### Persistent sessions

Domains with `persist = true` add rows for sessions not open in this window.
Local and WSL domains are listed every time the switcher opens.
SSH domains are contacted only by an explicit header/load-row action or refresh of a previously loaded domain; reopening the picker uses cached SSH results.
When SSH project sources are configured, one **Load sessions and projects** action starts both independently.
SSH project sources without persistence also get an on-demand **Load projects** action.
Source `host` selects the discovery machine, while its `domain` independently selects where project panes open.
Loading displays elapsed time and expires after `load_timeout_ms` (default 15000; allowed range 1000–300000), with a visible reason and explicit retry.
Late replies cannot overwrite a timed-out or retried load.
Empty results remain visible as **No sessions**, **All sessions already open**, or **No projects**, rather than removing the domain section.
Session rows carry `session_id`, `session_attached` and `session_badge`, and leave `program_status_badge` empty.
On a session row, `close_key` kills the session after confirmation and `create_key` creates a new session in its domain; `rename_key` does nothing.
See the [persistent sessions guide](../../persistent-sessions-guide.md#find-and-clean-up-sessions).
To recover a lost create reply, list the original domain and attach the ID from the native warning or the `new_workspace` callback's `session_id`; never create a replacement while the result is uncertain.

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

Persistent WSL source with Linux paths:

```lua
hollow.ui.workspace.configure({
  sources = {
    {
      name = "Ubuntu",
      host = { type = "wsl", distro = "Ubuntu" },
      domain = "UbuntuWSL",
      roots = {
        "/home/me/Projects",
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
