# Hollow Lua API Reference

This document describes the current Lua API shipped by Hollow.

For the broader docs map, start with `README.md` in this directory.

Hollow is still an early project, but the Lua API is usable today and is central
to how the product is configured and extended.

The current build is validated primarily on Windows and WSL.

## Core Idea

Hollow exposes a namespaced runtime table:

```lua
local hollow = require("hollow")
```

Primary namespaces:

- `hollow.config`
- `hollow.fonts`
- `hollow.json`
- `hollow.term`
- `hollow.workspace`
- `hollow.events`
- `hollow.keymap`
- `hollow.ui`
- `hollow.htp`
- `hollow.process`

Additional top-level helpers:

- `hollow.read_dir(path)`

Returned tab, pane, and workspace objects are snapshots. Treat them as read-only.

## `hollow.fonts`

```lua
hollow.fonts.list()
hollow.fonts.find(query)
hollow.fonts.has(family, style?)
hollow.fonts.pick(candidates, style?)
```

These helpers expose the same font inventory used by the host when resolving
font family names.

Example:

```lua
local preferred = hollow.fonts.pick({
  "Cascadia Mono",
  "Consolas",
  "DejaVu Sans Mono",
})

if preferred then
  hollow.config.set({
    fonts = {
      family = preferred,
    },
  })
end
```

## `hollow.config`

```lua
hollow.config.set(opts)
hollow.config.get(key)
hollow.config.snapshot()
hollow.config.reload()
```

`set()` merges config state and applies it to the host.

In the shipped app, the bundled `conf/init.lua` base config is loaded first and
any user config override is loaded after it, so user files only need to override
the values they care about.

Domain-related config fields:

```lua
hollow.config.set({
  default_domain = "wsl",
  domains = {
    wsl = {
      shell = "wsl.exe",
      default_cwd = "/home/me",
    },
    pwsh = { shell = "pwsh.exe" },
    cmd = { shell = "cmd.exe" },
    ssh = {
      ssh = {
        alias = "user@example.com",
        backend = "wsl",
        reuse = "auto",
      },
    },
    unix = { shell = "/bin/zsh" },
  },
})
```

`default_domain` picks the shell used for normal tab/pane creation when no domain is passed explicitly.
`domains` maps a domain name to either a shell string or an object with per-domain options.
`default_cwd` is used when a pane starts in that domain without an explicit cwd.

Workspace bootstrap config:

```lua
hollow.config.set({
  workspace = {
    auto_bootstrap = "always", -- or "never"
    default_layout = "default", -- resolves to ~/.config/hollow/layouts/default.json
  },
})
```

When `auto_bootstrap = "always"`, Hollow checks for a project-local `.hollow/workspace.json` rooted at the active pane cwd first, then falls back to `workspace.default_layout` when present.

## `hollow.json`

```lua
hollow.json.encode(value)
hollow.json.decode(text)
```

These helpers convert between Lua values and JSON strings. They are intended for simple data files such as workspace bootstrap specs.

## `hollow.workspace`

```lua
hollow.workspace.bootstrap(spec, opts?)
hollow.workspace.load(path)
hollow.workspace.load_and_bootstrap(path, opts?)
hollow.workspace.export_current()
hollow.workspace.export_to(path)
hollow.workspace.project_local_path(dir?)
hollow.workspace.resolve_auto_bootstrap_path()
hollow.workspace.auto_bootstrap()
```

This namespace handles workspace bootstrap specs stored as JSON.

## `hollow.async`

```lua
hollow.async.run(fn)
hollow.async.await(register)
hollow.async.promise(register)
```

Use this namespace when you want to script queued Hollow operations in sequence.
`hollow.async.run(fn)` starts a coroutine.
`hollow.async.await(register)` suspends until `resolve(value)` or `reject(error)` is called.
`hollow.async.promise(register)` creates a reusable promise object with `:next(...)`, `:catch(...)`, and `:await()`.

Bootstrap file shape:

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

Current v1 behavior:

- the file format is JSON
- project-local files live at `.hollow/workspace.json`
- global named layouts resolve under the user config dir at `layouts/<name>.json`
- relative `cwd` values resolve against the project root for `.hollow/workspace.json`
- `size` maps to split `ratio` for additional panes in a tab
- one pane may set `main: true` (or `default: true`) to receive focus after bootstrap
- tabs are linear layouts today; nested split trees are not supported yet

Example manual bootstrap:

```lua
local spec = hollow.workspace.load("/path/to/project/.hollow/workspace.json")
hollow.workspace.bootstrap(spec, { base_dir = "/path/to/project" })
```

Export the current workspace snapshot:

```lua
hollow.workspace.export_to("/tmp/workspace.json")
```

SSH domain options:

```lua
domains = {
  tower = {
    ssh = {
      host = "10.0.0.8",
      user = "root",
      alias = "tower",
      backend = "native", -- or "wsl"
      reuse = "none", -- or "auto"
    },
  },
}
```

`alias` uses an SSH config host directly when `host` is not provided. When `host` is set, Hollow prefers `user@host`.
`backend = "wsl"` launches the SSH client through `wsl.exe`, which is useful on Windows when you want Linux-side SSH config and multiplexing behavior.
`reuse = "auto"` enables OpenSSH multiplexing flags for WSL/Linux-backed SSH domains. Native Windows OpenSSH falls back safely without extra reuse flags.

Workspace picker sources can also use SSH-backed discovery:

```lua
hollow.ui.workspace.configure({
  sources = {
    {
      domain = "tower",
      resolver = "ssh",
      roots = {
        "/home/root/projects",
      },
    },
  },
})
```

`resolver = "ssh"` runs a remote directory listing through `hollow.term.run_domain_process(...)` and turns the resulting directories into workspace candidates.
This requires the SSH domain to work non-interactively, for example with SSH keys, an agent, or WSL-backed multiplexing.

## `hollow.term`

```lua
hollow.term.current_tab()
hollow.term.current_pane()
hollow.term.tabs()
hollow.term.tab_by_id(id)

hollow.term.workspaces()
hollow.term.current_workspace()
hollow.term.set_workspace_name(name)
hollow.term.set_workspace_default_cwd(cwd)
hollow.term.new_workspace(opts?)
hollow.term.next_workspace()
hollow.term.prev_workspace()

hollow.term.new_tab(opts?)
hollow.term.split_pane(direction_or_opts, opts?)
hollow.term.toggle_pane_maximized(pane_id?, opts?)
hollow.term.set_pane_floating(pane_id, floating)
hollow.term.set_floating_pane_bounds(pane_id, opts)
hollow.term.move_pane(direction_or_opts, opts?)
hollow.term.focus_tab(id)
hollow.term.close_tab(id)
 hollow.term.set_title(title, tab_id?)
 hollow.term.send_text(text, pane_id?)
 hollow.term.get_pane_text(pane_id?)
 hollow.term.get_pane_tags(pane_id?)
 hollow.term.set_pane_tags(tags, pane_id?)
 hollow.term.add_pane_tag(tag, pane_id?)
 hollow.term.remove_pane_tag(tag, pane_id?)
 hollow.term.set_pane_foreground_process(pane_id, process)
 hollow.term.run_domain_process(args, domain?)
 ```

`split_pane` accepts either `(direction, opts?)` or a single options table with:

```lua
{
  direction = "horizontal" | "vertical",
  ratio = number,
  domain = string,
  cwd = string,
  command = string,
  command_mode = "send" | "spawn",
  close_on_exit = boolean,
  floating = boolean,
  fullscreen = boolean,
  x = number,
  y = number,
  width = number,
  height = number,
  on_complete = function(result) end,
}
```

Set `floating = true` to create a new floating pane without inserting a new split into the tiled layout.
Set `fullscreen = true` to maximize the newly created pane immediately after creation.
Set `command` to run a command in the newly created pane.
Set `command_mode = "send"` (default) to type the command into the shell, which will echo it in the pane.
Set `command_mode = "spawn"` to launch the shell with that command directly so it does not appear as typed input. Beware this mode is not running the application with the user's default shell.
Set `close_on_exit = true` to close the pane after that command finishes. This is opt-in and leaves normal split panes unchanged.
When creating a floating pane, `x`, `y`, `width`, and `height` set the initial normalized bounds in `0..1` space.
Set `on_complete = function(result) ... end` to run code after the queued mux operation finishes on the frame thread. `result.success` is always present; successful `split_pane` callbacks also receive `result.pane_id`.

`new_tab(opts?)` and `new_workspace(opts?)` also accept `on_complete` callbacks. Successful results include `tab_id` and `workspace_index` respectively.

Example sequential flow:

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

`toggle_pane_maximized` defaults to the active pane and accepts `{ show_background = true }` to keep tiled panes rendered underneath the maximized pane.

`move_pane` reorders tiled panes in the requested direction; for floating panes it nudges the pane by `amount` (default `0.08`) in normalized window space.

`set_floating_pane_bounds` expects normalized values in the `0..1` range:

```lua
{
  x = number,
  y = number,
  width = number,
  height = number,
}
```

### Shapes

`HollowPane`

```lua
{
  id = integer,
  pid = integer,
  domain = string|nil,
  cwd = string,
  title = string,
  is_focused = boolean,
  is_floating = boolean,
  is_maximized = boolean,
  foreground_process = string|nil,
  frame = { x = integer, y = integer, width = integer, height = integer },
  size = { rows = integer, cols = integer, width = integer, height = integer },
}
```

`HollowTab`

```lua
{
  id = integer,
  title = string,
  index = integer, -- 1-based in Lua
  is_active = boolean,
  panes = HollowPane[],
  pane = HollowPane,
}
```

`HollowWorkspace`

```lua
{
  index = integer, -- 1-based in Lua
  name = string,
  is_active = boolean,
}
```

## `hollow.events`

```lua
handle = hollow.events.on(name, handler)
hollow.events.off(handle)
hollow.events.once(name, handler)
hollow.events.emit(name, payload?)
```

Built-in events currently include:

- `config:reloaded`
- `term:title_changed`
- `term:tab_activated`
- `term:tab_closed`
- `term:pane_focused`
- `term:pane_layout_changed`
- `term:cwd_changed`
- `term:foreground_process_changed`
- `key:unhandled`
- `window:resized`
- `window:focused`
- `window:blurred`

Built-in events cannot be emitted from Lua.

## Filesystem And Process Helpers

```lua
hollow.read_dir(path)
hollow.process.run_child_process(args)
hollow.term.run_domain_process(args, domain?)
```

`read_dir(path)` returns an array of absolute entry paths for the given absolute directory path.

`hollow.process.run_child_process(args)` runs a child process with the provided argv array and returns:

```lua
success, stdout, stderr
```

This mirrors the simple tuple style used by WezTerm-style config APIs, but is implemented by Hollow.

`hollow.term.run_domain_process(args, domain?)` resolves the configured Hollow domain shell and runs the argv through that domain.
If `domain` is omitted, Hollow uses the current pane domain.
It returns the same tuple:

```lua
success, stdout, stderr
```

## `hollow.keymap`

Hollow uses Vim-style key notation for all keymaps:

- plain characters: `j`, `/`, `?`
- modified chords: `<C-t>`, `<C-S-Tab>`, `<A-PageDown>`
- leader sequences: `<leader>e`, `<leader>wo`, `<leader><C-p>`

Legacy `ctrl+...`, `leader+...`, and split `mods`/`key` APIs are not supported.

Available helpers:

```lua
hollow.keymap.set(chord, action, opts?)
hollow.keymap.del(chord)
hollow.keymap.get(chord)
hollow.keymap.set_leader(chord, opts?)
hollow.keymap.clear_leader()
hollow.keymap.is_leader_active()
hollow.keymap.get_leader_state()
```

## `hollow.ui`

`hollow.ui` is the main Lua surface for custom presentation inside Hollow.
It covers:

- bar widgets for persistent UI attached to the window chrome
- sidebars and overlays for temporary or secondary UI
- built-in notify/input/select widgets
- the workspace switcher and related helpers

The most useful mental model is that Hollow has a small widget runtime. You
return rows and nodes from `render(...)`, Hollow draws them, and event hooks let
you respond to clicks, key presses, and lifecycle changes.

Shared node primitives:

```lua
hollow.ui.span(text, style?)
hollow.ui.spacer()
hollow.ui.icon(name, style?)
hollow.ui.group(children, style?)
```

Shared bar item primitives:

```lua
hollow.ui.bar.tabs(opts?)
hollow.ui.bar.workspace(opts?)
hollow.ui.bar.time(fmt, opts?)
hollow.ui.bar.key_legend(opts?)
hollow.ui.bar.custom(opts)
```

These are bar-level items rather than topbar-specific items, so the same nodes can be reused by future bar surfaces.

### Widget Model

All widget surfaces ultimately use the same core widget shape:

```lua
{
  render = function(ctx) ... end,
  on_event = function(name, e) ... end, -- optional
  on_key = function(key, mods) ... end, -- overlays only
  on_mount = function() ... end,        -- optional
  on_unmount = function() ... end,      -- optional
  width = integer,                      -- optional, overlays/sidebar
  height = integer,                     -- optional
  max_height = integer,                 -- optional
  chrome = { bg = "#000000", border = "#333333" } | true | false,
  theme = { ... },                      -- helper widgets only
  backdrop = true | "#000000" | { color = "#000000", alpha = 72 },
}
```

Use `render(ctx)` to derive UI from the current terminal state instead of trying
to keep your own copy of everything in sync.

The widget context includes:

- `ctx.term.tab`
- `ctx.term.pane`
- `ctx.term.tabs`
- `ctx.term.workspace`
- `ctx.term.workspaces`
- `ctx.size`
- `ctx.time`

### Widget protocol

All widget surfaces accept a table with at least:

```lua
{
  render = function(ctx) ... end,
  on_event = function(name, e) ... end, -- optional
  on_mount = function() ... end,        -- optional
  on_unmount = function() ... end,      -- optional
}
```

`ctx.term` currently includes:

- `ctx.term.tab`
- `ctx.term.pane`
- `ctx.term.tabs`
- `ctx.term.workspace`
- `ctx.term.workspaces`

`render(...)` can return normal rows, overlay rows, or bar items depending on the
surface. In practice:

- top bars and bottom bars usually return bar items plus `hollow.ui.spacer()`
- sidebars and overlays usually return rows built from `hollow.ui.text(...)`, `hollow.ui.row(...)`, `hollow.ui.rows(...)`, or tag helpers

`on_event(name, e)` is how widgets react to host events such as terminal state
changes and clickable bar-node events.

`on_mount()` and `on_unmount()` are useful for wiring listeners or resetting
ephemeral state around the widget lifetime.

### `hollow.ui.topbar`

```lua
hollow.ui.topbar.configure(opts)
widget = hollow.ui.topbar.new(opts)
hollow.ui.topbar.mount(widget)
hollow.ui.topbar.unmount()
hollow.ui.topbar.invalidate()
```

`configure(...)` customizes the shipped top bar without replacing the whole
surface. `mount(...)` still takes full ownership when you want a completely
custom widget.

The current renderer adapts topbar widgets onto the existing top status bar path.
A single `hollow.ui.spacer()` splits left and right content.

Typical use cases:

- replace the shipped top bar entirely
- show current cwd, workspace, clock, or mode state
- mount clickable buttons that open overlays or the workspace switcher

Example:

```lua
hollow.ui.topbar.configure({
  tabs = {
    fit = "content",
  },
  time = { format = "%H:%M:%S" },
})
```

### `hollow.ui.bottombar`

```lua
widget = hollow.ui.bottombar.new(opts)
hollow.ui.bottombar.mount(widget)
hollow.ui.bottombar.unmount()
hollow.ui.bottombar.invalidate()
```

Bottom bar widgets accept the same list of bar items as the top bar.
Set `opts.height` to reserve vertical space and render the bar at the bottom of the window.

Use this when you want persistent status without replacing the top bar.

### `hollow.ui.sidebar`

```lua
widget = hollow.ui.sidebar.new(opts)
hollow.ui.sidebar.mount(widget)
hollow.ui.sidebar.unmount()
hollow.ui.sidebar.toggle()
hollow.ui.sidebar.invalidate()
```

Sidebar options:

```lua
{
  side = "left" | "right",
  width = integer,   -- in terminal columns
  reserve = boolean, -- optional, default false
  hidden = boolean,  -- optional
  render = function(ctx) ... end,
}
```

If `reserve = true`, the sidebar shrinks the terminal layout instead of drawing over it.
If the sidebar is hidden or unmounted, reserved space is released.

Use sidebars for secondary information that should stay visible while the shell
continues to run, such as project context, hints, or a workspace list.

### `hollow.ui.overlay`

```lua
widget = hollow.ui.overlay.new(opts)
hollow.ui.overlay.push(widget)
hollow.ui.overlay.pop()
hollow.ui.overlay.clear()
hollow.ui.overlay.depth()
```

Overlays stack and receive `on_key(key, mods)` before normal keymaps.

This is the base for modal UI. The built-in notify, input, and select helpers are
implemented on top of overlays.

Use overlays for:

- quick pickers
- prompts and text input
- transient notifications
- command palettes or modal launchers

### Built-in overlay helpers

```lua
hollow.ui.notify.show(message, opts?)
hollow.ui.notify.info(message, opts?)
hollow.ui.notify.warn(message, opts?)
hollow.ui.notify.error(message, opts?)
hollow.ui.notify.clear()

hollow.ui.input.open(opts)
hollow.ui.input.close()

hollow.ui.select.open(opts)
hollow.ui.select.close()
```

Notifications accept `ttl` in milliseconds and now dismiss automatically, plus `align` values like `"top_right"` or `"bottom_right"`.

Input/select overlays capture printable keys including digits and punctuation, render a visible caret, support customizable backdrops via `true`, a color string like `"#000000"`, or `{ color = "#000000", alpha = 72 }`, and accept overlay `width`/`height`. Select navigation wraps and scrolls when the list is taller than the visible area.

Built-in widgets (`notify`, `input`, `select`) now resolve a shared palette from `theme.widgets.all` and per-widget sections like `theme.widgets.select`; each call can also override tokens with `opts.theme` or panel chrome with `opts.chrome`.

`hollow.ui.select` also accepts formatted `label`/`detail` content via span nodes, so picker items can be colorized while filtering still matches against the plain text.

It also accepts a shorthand text node form like `{ "Error", fg = "#ff5d62", bold = true }`, which is easier to write than a full `hollow.ui.span(...)` for simple colored labels.

For a lighter DSL, use `hollow.ui.text(...)`, `hollow.ui.row(...)`, and `hollow.ui.rows(...)` to build inline content and conditional row lists without as much ceremony.

There is also a small hyperscript-style helper: `hollow.ui.h(...)` / `hollow.ui.el(...)`, so you can write things like `hwl.ui.h("row", nil, {"Name", fg="#98bb6c"}, hwl.ui.h("text", { fg="#7e9cd8" }, " [ok]"))`.

Component functions now receive `props.children`, `props.children_row`, and `props.children_rows`, there is a `hollow.ui.fragment(...)` helper for nested row groups, and `hollow.ui.tags.row(...)` / `hollow.ui.tags.text(...)` style factories are available if you prefer not to use string tag names.

### `hollow.ui.input`

`hollow.ui.input.open(opts)` opens a simple modal text prompt backed by the
overlay stack.

Useful options:

- `prompt`
- `default`
- `width`
- `height`
- `backdrop`
- `chrome`
- `theme`
- `on_confirm(value)`
- `on_cancel()`

Behavior:

- `Enter` confirms
- `Escape` cancels
- `Backspace` deletes
- printable keys append to the current value

Example:

```lua
hollow.ui.input.open({
  prompt = "Rename tab",
  default = hollow.term.current_tab() and hollow.term.current_tab().title or "",
  on_confirm = function(value)
    local tab = hollow.term.current_tab()
    if tab then
      hollow.term.set_title(value, tab.id)
    end
  end,
})
```

### `hollow.ui.select`

`hollow.ui.select.open(opts)` opens a filterable picker overlay.

Useful options:

- `items`
- `label(item)`
- `detail(item)`
- `prompt`
- `query`
- `width`
- `height`
- `max_height`
- `backdrop`
- `chrome`
- `theme`
- `actions`
- `on_cancel()`

Behavior:

- `Enter` runs the first action
- `Up` / `Down` move selection
- typing filters entries
- `Backspace` edits the query
- `Escape` closes the picker
- action keybindings are resolved from `actions[i].key`

The first action is the primary action. Additional actions show up as hints in
the footer and can be bound to custom chords like `<C-r>` or `<C-w>`.

Example:

```lua
hollow.ui.select.open({
  prompt = "Domain",
  items = {
    { name = "pwsh", desc = "PowerShell" },
    { name = "wsl", desc = "Windows Subsystem for Linux" },
  },
  label = function(item)
    return item.name
  end,
  detail = function(item)
    return item.desc
  end,
  actions = {
    {
      name = "open",
      desc = "new tab",
      fn = function(item)
        hollow.ui.select.close()
        hollow.term.new_tab({ domain = item.name })
      end,
    },
  },
})
```

### `hollow.ui.workspace`

The workspace UI helpers build on `select`, `input`, and `term` APIs to provide
a complete workspace switcher and launcher.

Available helpers:

```lua
hollow.ui.workspace.configure(opts?)
hollow.ui.workspace.clear_cache()
hollow.ui.workspace.known_workspaces(force_refresh?)
hollow.ui.workspace.items(force_refresh?)
hollow.ui.workspace.open_switcher(opts?)
hollow.ui.workspace.switcher(opts?)
hollow.ui.workspace.topbar_button(opts?)
hollow.ui.workspace.create(opts?)
hollow.ui.workspace.rename(workspace?, opts?)
hollow.ui.workspace.close(workspace?)
hollow.ui.workspace.open(opts)
```

This is more than a picker. It merges:

- currently open workspaces from `hollow.term.workspaces()`
- cached known workspaces from configured sources
- optional project-root scans
- optional user-supplied items and filters

Open workspaces are listed first. Known-but-not-open workspaces are merged in,
deduplicated by workspace identity, and sorted by recent activity plus name.

#### Workspace Item Shape

Workspace items passed through the switcher normalize to:

```lua
{
  id = string,
  name = string,
  cwd = string|nil,
  domain = string|nil,
  source = "open" | "user" | "local" | "wsl" | "ssh",
  is_active = boolean,
  is_open = boolean,
  open_index = integer|nil,
  last_opened_at = integer|nil,
}
```

String items are accepted and normalized into `{ name = ... }` entries.

#### `workspace.configure(opts)`

`configure(...)` updates the persisted workspace switcher settings stored in UI
state. It is the main place to define how workspace discovery works.

Important options:

- `prompt`: picker title, default `"Workspaces"`
- `width`: picker width, default `96`
- `height`: fixed picker height
- `max_height`: maximum picker height, default `18`
- `backdrop`, `chrome`, `theme`: select overlay styling
- `cache_ttl_ms`: discovery cache TTL, default `5000`
- `project_roots`: local filesystem roots scanned by the default discovery callback
- `known_workspaces`: callback returning extra workspace items
- `sources`: table or callback returning workspace sources
- `format_item(workspace)`: custom row formatter for picker entries
- `filter_item(workspace)`: optional predicate; return `false` to hide an item
- `status_column_width`, `name_column_width`, `column_gap`: tune the default tabular layout
- `rename_key`, `rename_desc`: secondary rename action binding and label
- `close_key`, `close_desc`: close action binding and label
- `create_key`, `create_desc`: create action binding and label

Changing `known_workspaces`, `sources`, or `project_roots` invalidates the cache.
You can also call `hollow.ui.workspace.clear_cache()` directly.

#### Workspace Sources

Each source can declare:

```lua
{
  resolver = "local" | "wsl" | "ssh",
  name = string,
  domain = string,
  roots = { ... },
  items = function() ... end,
  cwd_resolver = "wsl_unc" | function(cwd, item, source) ... end,
  default = boolean,
}
```

Resolver behavior:

- `local`: scans `roots` with `hollow.read_dir(...)`
- `wsl`: shells out through `wsl.exe` and turns child directories into items
- `ssh`: uses `hollow.term.run_domain_process(...)` to list directories on an SSH domain

If `items()` is present, its results are merged with discovered directories from
`roots`.

`cwd_resolver = "wsl_unc"` is useful when your picker items come from Windows UNC
paths like `\\wsl$\Ubuntu\home\me\Projects` but the launched shell should `cd`
to the Linux-side path.

#### Discovery And Caching

The switcher keeps a cache of discovered workspaces and a `last_opened` map in UI
state.

- open workspaces are always live
- discovered workspaces are cached for `cache_ttl_ms`
- `force_refresh = true` bypasses the cache once
- `clear_cache()` resets the cached discovery results

Recent activity timestamps are updated from terminal events like tab activation,
cwd changes, title changes, and tab close events.

#### Opening And Switching Workspaces

`open_switcher(opts?)` shows the picker.

Default actions inside the picker:

- primary action: switch/open
- `rename_key`: rename the active workspace, default `<C-r>`
- `close_key`: close the active workspace, default `<C-w>`
- `create_key`: create a new workspace, default `<C-n>`

Behavior details:

- selecting an already-open workspace switches to it
- selecting a known workspace opens a new workspace using its `cwd` and `domain`
- for `source = "ssh"`, Hollow opens the workspace in the target domain and then sends a `cd` command rather than trying to use a local startup cwd
- if an open workspace came from a user-defined item and has a `cwd`, switching back to it can resend `cd` to restore that location

`workspace.open(opts)` is the programmatic entrypoint. You can pass an ad hoc item
directly, or specify `source = "..."` plus an item payload to resolve through a
configured source first.

#### Workspace Examples

Use local project roots:

```lua
hollow.ui.workspace.configure({
  project_roots = {
    "C:/Users/me/Projects",
    "D:/src",
  },
})
```

Use a WSL source rooted in UNC paths and translate them back to Linux paths:

```lua
hollow.ui.workspace.configure({
  sources = {
    {
      name = "Ubuntu",
      resolver = "local", -- if you put wsl here, it will try to run wsl.exe to list directories, which does not work with UNC paths
      domain = "wsl",
      cwd_resolver = "wsl_unc",
      roots = {
        "\\\\wsl$\\Ubuntu\\home\\me\\Projects",
      },
    },
  },
})
```

Use an SSH-backed source:

```lua
hollow.ui.workspace.configure({
  sources = {
    {
      domain = "devbox",
      resolver = "ssh",
      roots = {
        "/home/me/projects",
      },
    },
  },
})
```

Customize picker rows:

```lua
hollow.ui.workspace.configure({
  format_item = function(workspace)
    return {
      hollow.ui.span(workspace.is_active and "* " or "  "),
      hollow.ui.span(workspace.name, { bold = workspace.is_active }),
      hollow.ui.span(workspace.cwd and ("  " .. workspace.cwd) or "", { fg = "#727169" }),
    }
  end,
})
```

Hide items you do not want in the picker:

```lua
hollow.ui.workspace.configure({
  filter_item = function(workspace)
    return workspace.name ~= "scratch"
  end,
})
```

Mount a workspace button in the top bar:

```lua
hollow.ui.topbar.mount(hollow.ui.topbar.new({
  render = function()
    return {
      hollow.ui.workspace.topbar_button({
        text = " workspaces ",
      }),
      hollow.ui.spacer(),
      hollow.ui.bar.time("%H:%M"),
    }
  end,
}))
```

 ## `hollow.htp`
 
 `hollow.htp` is implemented and is the Lua-facing entrypoint for shell-to-host
 integration.
 
 ### Shell Integration
 
 Hollow supports a proprietary protocol (HTP) that allows shells to communicate
 metadata (like CWD changes or command execution) back to the host. 
 
 This integration allows the host to:
 - Automatically update the pane title/status based on the running process
 - Trigger UI updates when the shell changes directories
 - Orchestrate complex layout changes from within the shell
 
 To enable this, add the corresponding script from the `shell-integration/` folder to your shell's rc file (e.g., `.zshrc` or `.bashrc`) on your system.
 
 For detailed implementation examples for Zsh, Bash, and others, see
 `htp-shell-examples.md`.
 
 ```lua
 hollow.htp.on_query(channel, handler)
 hollow.htp.on_emit(channel, handler)
 hollow.htp.off_query(channel)
 hollow.htp.off_emit(channel)
 ```

Built-in queries currently include:

- `pane`
- `current_pane`
- `tab`
- `current_tab`
- `tabs`
- `panes`
- `workspace`
- `workspaces`
- `current_workspace`
- `current_domain`
- `echo`

Built-in emits currently include:

- `close_pane`
- `focus_pane`
- `resize_pane`
- `send_text`
- `split_pane`
- `new_tab`
- `close_tab`
- `focus_tab`
- `next_tab`
- `prev_tab`
- `set_tab_title`
- `new_workspace`
- `close_workspace`
- `next_workspace`
- `prev_workspace`
- `switch_workspace`
- `set_workspace_name`
- `toggle_pane_maximized`
- `set_pane_floating`
- `set_floating_pane_bounds`
- `move_pane`

- `reload_config`
- `set_theme`
- `scroll`

The primary shipped HTP frontend is `hollow-cli`, with `hollow cli` available as the native command path.

Examples:

```bash
hollow-cli get current-pane
hollow-cli workspace new --cwd /repo --name repo
hollow-cli pane split vertical --cmd "npm run dev"
hollow-cli get htp echo '{"value":42}'
hollow-cli emit custom_channel '{"value":42}'
```

Use `htp-shell-examples.md` for lower-level transport examples and shell helper notes.

## `hollow.process`

This namespace exists, but `spawn` and `exec` are still placeholders.

```lua
hollow.process.spawn(opts)
hollow.process.exec(opts)
```

For process execution today, use:

```lua
hollow.process.run_child_process(args)
hollow.term.run_domain_process(args, domain?)
```

## Example

```lua
local hollow = require("hollow")

hollow.config.set({
  default_domain = hollow.platform.is_windows and "wsl" or "unix",
  domains = {
    wsl = { shell = "wsl.exe" },
    pwsh = { shell = "pwsh.exe" },
    cmd = { shell = "cmd.exe" },
    unix = { shell = hollow.platform.default_shell },
  },
})

hollow.ui.topbar.mount(hollow.ui.topbar.new({
  render = function(ctx)
    return {
      hollow.ui.span(ctx.term.pane.cwd or "", { fg = "#dcd7ba" }),
      hollow.ui.spacer(),
      hollow.ui.span(hollow.strftime("%H:%M:%S"), { fg = "#7e9cd8" }),
    }
  end,
}))

hollow.keymap.set_leader("<C-Space>", { timeout_ms = 1200 })
hollow.keymap.set("<leader>v", "split_vertical", { desc = "split vertical" })

hollow.term.new_tab({ domain = "pwsh" })
hollow.term.split_pane({ direction = "vertical", ratio = 0.4, domain = "wsl" })
hollow.term.split_pane({ direction = "horizontal", cwd = "/tmp/project" })
hollow.term.split_pane({ floating = true, width = 0.6, height = 0.7 })
hollow.term.split_pane({ floating = true, fullscreen = true, domain = "wsl" })

hollow.events.on("config:reloaded", function()
  hollow.ui.notify.info("Config reloaded", { ttl = 1500 })
end)
```
