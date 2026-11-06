# Persistent sessions (experimental)

Persistent workspaces keep terminal processes, screen state, and scrollback in a host-side owner when the GUI disconnects.
Persistence is opt-in per domain and leaves ordinary domains unchanged.
This implementation supports Linux owners locally, inside WSL, or through SSH to Linux.
Native Windows owners are not supported yet.

## Enable a test domain

Add a separate domain first, without changing your default domain:

```lua
hollow.config.set({
  domains = {
    persistent_test = {
      persist = true,
      host = { type = "wsl", distro = "Ubuntu" },
    },
  },
})
```

Use your actual WSL distribution name.
For native Linux, use `host = { type = "local" }` instead.
For SSH, use an explicit `host = { type = "ssh", destination = "my-alias" }` descriptor and configure SSH trust yourself first.
Existing agent deployment settings such as `agent_path`, `agent_dir`, and `timeout_ms` apply to the host descriptor.
An omitted shell selects the guest login shell; an explicit guest shell such as `/bin/zsh -l` preserves its arguments.

Create a workspace through the Lua REPL or your own action:

```lua
hollow.term.new_workspace({
  domain = "persistent_test",
  name = "persistent-check",
})
```

Creation is asynchronous.
A native connecting card appears while the owner starts or the connector opens.
Click it to cancel.
Failures stay visible rather than falling back to an ordinary shell.
If the request may already have reached the owner, cancellation retains an uncertainty warning.
Do not automatically repeat a create request after an uncertain result.

## Detach and reconnect

After creation succeeds, read and save `hollow.term.current_workspace().session_id` from the Lua REPL.
Run a long-lived process or set a shell variable in that workspace.
Close the GUI window to detach.
Do not close its pane, tab, or workspace: those actions explicitly terminate owner panes.

After reopening Hollow, attach using the saved ID and the same host domain:

```lua
hollow.term.attach_session("saved-session-id", {
  domain = "persistent_test",
  on_complete = function(result)
    if not result.success then
      print("Persistent session attachment failed")
    end
  end,
})
```

Attachment rebuilds terminal views without starting another shell.
It takes over the session if another client is attached; the previous client retains a disconnected view.
Closing a disconnected view only removes that local view.
To clean up the test session, explicitly close its workspace after reattaching.

## Find and clean up sessions

Instead of saving IDs by hand, list what a host owns:

```sh
hollow-cli session list --domain persistent_test
hollow-cli session attach <id> --domain persistent_test
hollow-cli session kill <id> --domain persistent_test
```

From Lua, use `hollow.term.list_sessions` and `hollow.term.kill_session`; see the [term reference](reference/lua/term.md#persistent-workspaces).
Each listed session reports whether any client is attached, whether this GUI already shows it, its saved workspace name, and its panes.
Listing never attaches, so it does not disturb another GUI.
An owner started only to answer a list exits again once it is idle.
A kill whose reply is lost is reported as uncertain and never retried; list again to check.
See the [CLI reference](reference/cli/sessions.md) for output and failure details.

## Tabs, splits, and saved layout

Normal tab and split actions now create additional owner-backed terminal panes inside the same session.
Creation is asynchronous: a view is published after the owner acknowledges its pane, without starting a client-local shell.
If you change focus while creation is pending, the new pane stays at its original destination without stealing focus or scrolling your current terminal.
Floating splits and fullscreen placement use the same path.

Tab order, split geometry, floating bounds, focus, maximization, and workspace names are saved through revision-checked updates.
Ordinary geometry edits settle briefly before saving rather than serializing a layout on every drag frame.
Reattachment restores the saved structure and the original processes in its panes.
Closing a tab or workspace waits for pending pane creation and includes the acknowledged child in the close operation.

Each workspace permits one pending pane creation at a time.
Another request while it is busy reports an error rather than silently falling back or duplicating a spawn.
Pane domains must remain the workspace's domain; use another workspace for another host/domain.
Changing a domain's host profile does not retarget an already attached session.

## Exited panes and missing sessions

When a process in a persistent pane exits, the pane keeps its final screen and shows a footer with the exit code.
Press Enter to respawn the original command in the same cwd, or Ctrl+D to close the pane.
The new process writes below the old output.
Bind the `respawn_pane` action, or call `hollow.term.respawn_pane()`, to respawn from elsewhere.
Owners started by an older Hollow cannot respawn, so the footer offers only Ctrl+D.

If an attach names a session the owner no longer has, Hollow shows "Session not found on host".
Run `hollow-cli session list` to see live sessions, or open a new workspace.

## Persistent startup

Set `default_domain = "persistent_test"` only when you want startup to create a persistent workspace.
Hollow then starts with an empty mux while the connection opens, rather than launching a disposable ordinary shell.
Startup commands remain targeted to that startup operation's pane even if another workspace gains focus.

Hollow remembers the persistent sessions you open and reattaches them at the next launch.
At startup it lists each local and WSL domain that has remembered sessions, then:

- reattaches every remembered session that no client is using;
- asks before taking over sessions another window has attached;
- forgets sessions the host no longer has, without a notice;
- keeps sessions whose host answers with a different host ID.

A fresh session in the default domain is created only when the host confirmed that none of its remembered sessions survive, or when you decline every take-over.
If the host cannot be listed, or an attach may have reached the owner, startup creates nothing and shows a warning instead, so a live session is never duplicated.
A startup command always gets its own fresh session.

SSH hosts are never contacted at startup.
A notice offers to restore remembered SSH sessions, and the `restore_sessions` action or `hollow.term.restore_sessions()` does the same at any time.

Sessions are forgotten when their last pane closes or they are killed.
Quitting, detaching, or losing the connection keeps them.
Set `restore = false` on a domain to stop remembering its sessions:

```lua
hollow.config.set({
  domains = {
    persistent_test = { persist = true, restore = false },
  },
})
```

The list is stored in `sessions.json` in the user data directory and holds at most 64 sessions.

## Current limits

- New ordinary panes cannot be spawned directly on a persistent domain; create a workspace instead.
- Moving tabs or panes across a persistent-workspace boundary is rejected.
- Quitting waits briefly (up to 500 ms) for the final layout save; a lost connection can still drop the latest geometry, but never kills owner processes.
- Panes opened or closed after the last save are reconciled on reattach: closed panes are removed from their splits and new panes appear as extra tabs.
- GUI session discovery and recovery of a lost create reply are not implemented yet.
- Owner crashes, host reboots, and WSL shutdown do not preserve live processes.
- WSL keepalive remains future work.

For implementation details, see the [architecture and implementation plan](persistent-sessions.md).
