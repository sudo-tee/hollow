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

`pane.kind` is `"terminal"` or `"lua"`. Lua panes share native layout and focus
fields but have no PTY. Named Lua panes expose `pane.module` and `pane.args`
(creation-time JSON, not live state); floating Lua snapshots also include
normalized `pane.floating_bounds`. Use
[`hollow.ui.pane`](ui.md#lua-panes) to create or look up a Lua UI owner. Guard
terminal-only operations by `kind` when iterating mixed panes.

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

The default tab bar, mux navigator, and workspace switcher show colored status icons:
an animated blue working spinner (with percentage when reported), amber blocked-kind
icons, a green completion check, and a red error cross. Idle has no indicator.
Mux navigator pane rows show their own status; tab/workspace rows aggregate all
their panes, even when collapsed. Open overlays read live status on each render.
When a child terminal enables focus reporting, Hollow forwards focus-in/out events
when pane or workspace focus changes, as well as when the Hollow window gains or
loses focus.
Custom bars can inspect records:

```lua
hollow.events.on("term:program_status_changed", function(event)
  for _, task in ipairs(event.pane.program_status) do
    -- task.state, task.kind, task.progress, task.message
  end
end)
```

Changes within one host tick are coalesced into one event with the final state.
Prompt start (OSC 133 A) and child exit remove idle/working/blocked records.
Done/error survive both events. Focusing a pane acknowledges its unread
blocked/error attention without removing any status records. New blocked/error reports set `attention = true`
only while the pane is inactive; leaving the pane does not re-arm old reports.
The first keypress delivered to the source pane dismisses its done/error records;
picker navigation, focus changes, and programmatic writes do not. Blocked records
remain until replaced/cleared, prompt start, or exit. Full reset clears all records;
soft reset and alternate-screen changes do not. No timeout or heartbeat is used.
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

When `domain` is omitted, new tabs inherit the active pane's domain, falling
back to the configured default when the pane has no domain. An omitted `cwd`
inherits the active pane's cwd only when the domains match.

## Pane operations

### Owned background jobs

`hollow.term.jobs.spawn(opts)` creates a retained, no-focus terminal job using the
same backend as [`job spawn`](../cli/jobs.md). It does not invoke the CLI.

```lua
local job = hollow.term.jobs.spawn({
  argv = { "make", "test" }, -- or cmd = "make test && make build"
  cwd = "/work/project",
  -- domain = "UbuntuWSL",
  user_shell = true,
})

hollow.async.run(function()
  local result = job:wait({ timeout_ms = 120000 }):await()
  if result.status == 0 then
    job:cleanup():await()
  else
    local output = job:output():await()
    -- output.data is base64 raw PTY bytes; inspect without replaying escapes.
    -- Keep failed pane available for user inspection.
    print("Tests failed in pane " .. result.pane_id)
  end
end)
```

Spawn returns immediately with a job object. Native operations run through the
frame queue, never through blocking socket reads. Every operation below except
`handle()` returns a `hollow.async` promise; use `:next()` / `:catch()` or
`:await()` inside `hollow.async.run`.

| Method | Result |
| --- | --- |
| `job:ready()` | Creation metadata: `pane_id`, `tab_id`, `workspace_id`, ownership `token`, pre-launch `cursor` |
| `job:handle()` | Copy of creation metadata, or `nil` while creation is pending |
| `job:get()` | Current running/exited state, nullable process `status`, cursor and output loss indicators |
| `job:output()` | `{encoding="base64", data=..., truncated=..., incomplete=..., capacity_bytes=...}` |
| `job:wait({timeout_ms=?, auto_close=?})` | Completion state/status plus resource IDs and ownership token |
| `job:cleanup()` | `true` after closing the matching exited pane; rejects running jobs |

Methods can be called before creation finishes; they queue behind `ready()`.
Supply exactly one of literal `argv` or shell `cmd`, plus optional `cwd`, `domain`,
and `user_shell`. Unknown options and malformed arguments are rejected.
`user_shell` loads target interactive-shell configuration, not a live pane's
temporary environment. Defaults and resource/output limits match the CLI.

`wait()` polls retained job state with deferred, nonblocking reads. A nonzero
process exit fulfills the promise; inspect `result.status`. Missing status means
unknown, not success. Without `timeout_ms`, waiting has no deadline. Timeout
rejects with `{code="timeout", message=..., handle=...}` and leaves the job intact;
you can call `wait()` again. Other request failures reject with `{code, message}`.

`auto_close=true` closes after **any** observed exit, including failure, and adds
`closed=true`. Closing discards retained output; timeout never auto-closes.
Wrong ownership, manual pane closure, and cleanup races return backend errors.
Dropping the Lua object or reloading Lua does not clean up the pane automatically;
save the handle if you need to inspect/clean it through the CLI later. There is
no kill/cancel method: cleanup is not cancellation.

This differs from `hollow.process.spawn`: terminal jobs create visible panes on
the selected terminal host, rather than a pane-less process with separate
stdout/stderr. Existing `hollow.term.run` instead drives an existing shell pane.

### Create and split

```lua
hollow.term.split_pane(opts)
```

`split_pane` accepts either `(direction, opts)` or a single options
table:

```lua
{
  direction = "horizontal" | "vertical",
  edge = "left" | "right" | "top" | "bottom", -- full tiled-layout edge
  dock = "global" | "workspace", -- with edge: window dock across tabs
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

- `tag`/`tags` are applied once the pane exists, before `on_complete`
  runs, so the callback can already find the pane by tag. Pass one or
  the other, not both.
- `command_mode = "send"` (default) types the command into the shell,
  so it echoes in the pane.
- `command_mode = "spawn"` launches the shell with the command
  directly, so it does not appear as typed input. The shell is not
  the user's default shell in this mode.

### Visibility without destroying the PTY

```lua
hollow.term.set_pane_visible(pane_id, false) -- hide; keep session running
hollow.term.set_pane_visible(pane_id, true)  -- show same session
```

Hidden panes remain in the mux and keep their terminal process, but are
excluded from layout, input hit testing and focus navigation. Tiled layouts
expand into the freed area. Hiding the last visible pane in a tab is ignored.
Snapshot objects include `is_hidden`. This is independent of terminal
transport detach/reattach and does not persist the process across app exits.
Owner-backed persistent sessions do save the hidden flag with the layout.
`split_pane({ edge = "right", ratio = 0.3, command = "lazygit",
command_mode = "spawn" })` creates an edge-docked PTY; edge placement
cannot be combined with `floating = true`.

### Window docks

```lua
hollow.term.dock_pane(pane_id, { edge = "right", scope = "global", ratio = 0.3 })
hollow.term.undock_pane(pane_id)  -- back into the active tab as an edge split
hollow.term.docks()               -- docked pane snapshots, global first
```

Docks keep a pane on a window edge across tab switches. `scope` is
`"global"` (default, every workspace) or `"workspace"`; `ratio` (default
0.3) is the dock's share of the window content. One pane per edge per
scope; a tab's last pane and occupied slots are refused. Docked snapshots
carry `dock = { edge, scope, workspace_id?, ratio }`. Owner-backed
persistent sessions save dock scope and ratio with the layout; a global
dock is restored only in the session that owns its pane. See
[Window docks](../../panes-tabs-workspaces.md#window-docks).

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
[native CLI](../cli/native.md) targets with `--tag`. Hollow stores them
with the pane, not in Lua: tags set from Lua and from the CLI
(`pane set-tag`, `pane set-tags`) are the same set, they survive config
reloads, and they are dropped when the pane closes. `get_pane_tags`
returns them sorted. Leading and trailing whitespace is trimmed; empty
tags are rejected. At most 64 tags per `set_pane_tags` call are kept.

### Text and process

```lua
hollow.term.bell(pane_id?)
hollow.term.send_text("hello", pane_id?)       -- Lua panes: decoded as key events
hollow.term.get_pane_text(pane_id?)             -- scrollback contents
hollow.term.set_pane_foreground_process(pane_id, "vim")
```

### Run a command and await completion

```lua
hollow.term.run("cargo test", {
  pane_id = pane.id,       -- default: focused pane, captured now
  timeout_ms = 30000,       -- default: 30 seconds
}):next(function(result)
  -- result.pane_id, result.command, result.status, result.took_ms
  if result.status ~= 0 then
    hollow.ui.notify.show("Tests failed")
  end
end):catch(function(err)
  hollow.ui.notify.show(tostring(err))
end)
```

Returns a `hollow.async` promise, also usable with `:await()` inside
`hollow.async.run`. Sends the command plus Enter to an existing shell; it
does not spawn a process. Commands must be non-empty, single-line strings
without control characters. `result.command` is the submitted text, before
shell expansion. Nonzero exit status fulfills the promise normally.

Completion requires both command lifecycle hooks and the following prompt
readiness hook. This lets a `:next()` callback submit another `run` safely.
Output is not captured; `get_pane_text` reads pane scrollback, not a command's
isolated output. Promise callbacks returning another promise do not flatten it;
use sequential `:await()` calls for multi-command scripts.

Requires updated Hollow Bash, Zsh, or Fish integration (start a new shell after
upgrading). `pane.at_prompt` is false until a readiness hook arrives; merely
having `busy == false` is insufficient. PowerShell and older integrations do
not support this API. Calls reject immediately for unknown panes, unknown shell
readiness, alternate-screen programs, or a pending run in the same pane.

Use a dedicated automation pane with an empty input line: readiness hooks do
not inspect the shell's editable input buffer. Do not mix manual input, other
controllers, or raw `send_text`/`send_key` calls with runs. Commands must actually
execute and return to a prompt; comments, incomplete shell syntax, interactive
programs, and commands that replace/exit the shell cannot complete normally.

Timeout, pane exit/closure, pane replacement, and input failures reject the
promise. A timeout **only stops waiting**; it does not interrupt the command.
The timeout includes waiting for the next prompt. Pending promises belong to
the current Lua runtime and are discarded on config reload; shell command
state and readiness survive reloads.

## Workspace operations

```lua
hollow.term.new_workspace(opts)         -- create
hollow.term.attach_session(id, opts)    -- experimental persistent attachment
hollow.term.list_sessions(opts)         -- discover persistent sessions on a host
hollow.term.kill_session(id, opts?)     -- end one persistent session
hollow.term.restore_sessions(opts?)     -- reattach remembered persistent sessions
hollow.term.remembered_sessions()       -- sessions remembered for restore
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

### Persistent workspaces

For a domain with `persist = true`, `new_workspace` admits asynchronous owner creation instead of spawning an ordinary pane.
Its completion callback runs after the workspace is published, not when the request is merely queued.
`workspace.session_id` is the host-owned ID for a persistent workspace and is absent for an ordinary workspace.
`workspace.session_host` is the owner's stable host ID, kept in the owner's state directory across restarts.
It is absent for ordinary workspaces and for owners that predate host IDs.
Together, `session_host` and `session_id` identify one session across domains that reach the same host.

`attach_session(session_id, opts)` accepts a nonempty ID and optional `{ domain, name, on_complete }` table.
The optional `trace_intent` is `"open"` or `"restore"` for diagnostic logs.
It does not change attachment or takeover policy.
The domain must have persistence enabled and resolve to the host that owns the session.
An omitted domain inherits the current terminal domain, then the configured default domain.
Attachment is asynchronous and uses the same `{ success, workspace_index }` completion result as `new_workspace`.
It takes over any existing attachment without creating another shell.
No create or attach request is automatically replayed after connection loss.
A failed persistent open reports `status`, `error`, and `outcome`, plus `remote` when the owner answered.
`status = "session_not_found"` means the owner is reachable and the session no longer exists, so opening a fresh workspace is safe.
Any other failure has `status = "session_open_failed"`.
An `outcome` of `"uncertain"` means the owner may have acted, so do not create a replacement.
An uncertain create also includes `session_id` when the owner supports reserved create IDs.
Use `list_sessions` in the original domain to check whether that ID exists, then explicitly call `attach_session`; never replay `new_workspace` or its startup command automatically.
The ID is a recovery hint, not proof of success, and is absent for older owners and failed attaches.

`respawn_pane(pane_id?)` restarts the exited process of a persistent pane from its original command, cwd, and environment.
The old screen stays, and the new process writes below it.
It returns `true` once queued; otherwise it returns `false, reason`, for example `"PaneAlive"`, `"NotSessionPane"`, or `"Unsupported"` for an owner that predates respawn.
`term:pane_respawned` fires with `{ pane }` when the owner accepts; a rejection shows a native notice.
A lost reply is never retried, and the pane stays exited until you respawn it again.
While a persistent pane is exited, a footer shows its exit code, and Enter respawns it and Ctrl+D closes it.
The `respawn_pane` action binds the same behavior to any key.

`list_sessions({ domain?, on_complete })` asks the domain's host owner for its sessions without attaching to any of them.
`kill_session(session_id, { domain?, on_complete? })` ends one session and all of its panes.
Both resolve the domain like `attach_session` and open a short-lived connection of their own.
They return `true` once queued; otherwise they return `nil, err` and the callback never runs.
At most eight discovery queries run at once.

```lua
hollow.term.list_sessions({
  domain = "persistent_test",
  on_complete = function(result)
    if not result.success then
      print("list failed: " .. result.error)
      return
    end
    for _, session in ipairs(result.sessions) do
      -- session.id, .name?, .attached, .open, .revision
      -- session.panes[i]: { id, title, cwd, cols, rows, exited, exit_status? }
      print(session.id, session.name or "", session.open and "open here" or "")
    end
  end,
})
```

`attached` means some client is attached, possibly another GUI.
`open` means a workspace in this GUI shows the session.
`name` is the saved workspace name, when the saved layout records one.
A successful kill result is `{ success = true, domain, session }`.
A failure carries `status` and `error`, and when the owner was contacted, `outcome` and an optional owner message in `remote`.
An `outcome` of `"uncertain"` means the kill may have happened: list again rather than retrying it.
A successful kill also forgets the session for startup restore.

### Remembered sessions

Hollow remembers each persistent session opened in a domain with `persist = true`, unless the domain sets `restore = false`.
The list lives in `sessions.json` in the user data directory and keeps at most 64 entries, dropping the oldest.
A session is forgotten when its owner ends it, when it is killed, or when a reachable host no longer has it.
Closing the GUI or losing the connection keeps it remembered.

`remembered_sessions()` returns the entries, oldest first, as `{ domain, id, host? }`.
`restore_sessions({ domain? })` lists each remembered domain's host, SSH included, and reattaches the sessions it still has.
It returns the number of domains it queried, and never creates a fresh session.
Sessions already open here are skipped, and sessions attached by another client ask before taking them over.
Startup does the same for local and WSL domains only; see the [guide](../../persistent-sessions-guide.md#persistent-startup).

See the [persistent sessions guide](../../persistent-sessions-guide.md) for configuration, cleanup, and current limitations.

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
  at_prompt = boolean,
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
