# Persistent sessions (experimental)

Persistent workspaces keep terminal processes, screen state, and scrollback in a host-side owner when the GUI disconnects.
Persistence is opt-in per domain and leaves ordinary domains unchanged.
This implementation supports native Linux, native Windows x86_64, WSL, and SSH to Linux.
Native Windows support is experimental and uses the same asynchronous workspace opening and restoration path.
Windows owner limits are 16 sessions, 16 panes per session, and 64 panes total, with 1 MiB scrollback per pane.
Remote Windows owners are not supported.

## Updating session owners

Updating Hollow installs a new runtime without interrupting sessions.
On Linux and WSL, a connector that finds an owner with live sessions from a different runtime asks it to hand off in place.
The owner re-executes the new agent in the same process and keeps every pane, its screen, and its scrollback.
The window that triggered the handoff reconnects on its own.
Other windows still attached to the owner are disconnected; [reconnect](#detach-and-reconnect) them to continue.
If the new agent cannot take over, the old one resumes and is not asked to upgrade to that build again.
The triggering window shows a "Session handoff" toast with the old and new build IDs, or a warning after a fallback.
Handle the [`session:handoff`](reference/lua/events.md) event to react to it in your config.
Each handoff also writes one line to `/tmp/hollow-session-$UID/owner.log`:
`session handoff from build <id> complete: adopted N sessions, M panes` on success, or `session handoff to build <id> failed; resumed …` after a fallback.
See the [upgrade plan](persistent-sessions-upgrade-plan.md) for details.

Set `upgrade` on a domain to choose the policy:

```lua
domains = {
  persistent_test = { persist = true, upgrade = "retire_empty" },
}
```

- `"handoff"` (default) replaces Linux and WSL owners in place.
- `"retire_empty"` keeps live sessions on the old owner until they end.
- `"never"` leaves outdated owners running.

Native Windows owners, empty owners, and the `retire_empty` policy use empty-only retirement.
A connector detects a different runtime and requests empty-only retirement.
Existing and detached sessions keep running on their original owner.
After its last session ends, the old owner exits despite idle GUI clients.
The next connection starts the installed runtime without replaying old sessions.
On Windows, idle GUI-held WSL pins are drained automatically during retirement.
Live or detached WSL sessions still prevent retirement until they end.
Reconnecting to a live WSL session remains supported during retirement.
The guest confirms empty-only shutdown before its keepalive is released.
Guest observation failures never count as an empty state.
The owner checks emptiness atomically with admission to protect racing creates.

Owners predating the `retire-empty` capability cannot participate in automatic replacement.
For that first upgrade, finish sessions and disconnect clients to let them exit.
Updates never forcibly stop legacy owners or migrate shell environments.
Legacy WSL guests without `drain-empty` also need a normal shutdown.

## WSL lifetime on Windows

Persistent WSL domains now borrow a Windows-owner keepalive before create, attach, or discovery can reach the guest owner.
The hidden WSL connection belongs to the Windows owner, not the GUI, and remains while guest sessions exist.
After the last GUI pin, a 30-second drain grace and a confirmed empty guest list permit cleanup.
Failed observation is not treated as an empty list; only read-only watcher recovery is automatic, never session creation or another mutation.
The Windows owner supports at most eight distro/user host records shared across GUI instances.
Use an explicit `user` in the WSL host descriptor when you need a stable user identity across changes to the distro's default user.

This requires both an updated Windows owner advertising `wsl-keepalive` and an updated Linux agent supporting internal `session wait --hold`.
Rebuild the full agent bundle, rather than only the fast GUI development target, or update your explicit `agent_path`.
Existing Linux session owners do not need restarting.
An older running Windows owner or missing helper fails visibly before guest create is submitted; Hollow never falls back to a disposable pane or kills an old owner to upgrade it.
Finish its native sessions before explicitly replacing an older Windows owner.

Explicit `wsl --terminate`, `wsl --shutdown`, owner crashes, and host shutdown can still end sessions.
Do not stop the Windows owner while relying on its WSL keepalives.
Automated private fixtures verify detach/reattach continuity and cleanup, but otherwise-idle distro survival still needs qualification in a spare distro.

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

For native Windows, use an explicit local host and a Windows shell:

```lua
hollow.config.set({
  domains = {
    persistent_windows = {
      persist = true,
      host = { type = "local" },
      shell = "powershell.exe -NoLogo -NoProfile",
    },
  },
})
```

The Windows session-only owner is included in Windows builds, releases, and development GUI builds.
Missing owner binaries fail visibly; Hollow does not probe Linux or fall back to a disposable shell.
`agent_path` on a Windows local host must be an absolute Windows path; guest host overrides remain absolute Linux paths.
Managed bundles run from an immutable, checksum-addressed cache under `%LOCALAPPDATA%\hollow\session-owners` so GUI upgrades do not overwrite a resident owner executable.
For an explicit `agent_path`, keep that file unchanged while its owner runs and use a versioned path when upgrading.
Native persistent PowerShell receives OSC-based cwd/title integration without inheriting GUI pane or workspace identifiers.
Do not configure `wsl.exe` as a native-local persistent shell: select an explicit WSL host instead.
Detached owner startup requires permission to leave the GUI launcher's Windows job; restrictive launchers fail visibly rather than creating an owner that would die with the GUI.
Headless App/controller integration and an isolated real-window create/split/tab/quit/restore smoke check are qualified.
The real-window fixture used a prestarted private owner because this runner rejects detached breakaway startup; it does not qualify GUI-driven owner startup under a permissive launcher or visual rendering correctness.

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

While a session connects, a "Connecting persistent session" notification is shown; click it to cancel.
Failures, such as a missing session or a lost create reply, replace it with an error or warning notification that stays until you click it.
Both kinds land in the attention history.
Handle the [`session:notice`](reference/lua/events.md) event to customize them.
If Lua cannot show a notice, Hollow draws it as a native panel over the panes instead.

## Find and clean up sessions

The workspace switcher is the one place to restore and manage sessions.
When it opens, it lists each local and WSL persistent domain in the background.
Sessions not open in this window appear after the open workspaces, with their first pane's cwd and a pane count.
Press Enter on a session row to attach it.
A session another window holds is marked "attached elsewhere", and Enter asks before taking it over.

SSH domains are never contacted just because the switcher opened.
Each SSH persistent domain shows an on-demand load row instead; press Enter on it or its domain heading to list that host.
Configured SSH project sources are loaded by the same action, without connecting while the picker merely opens or filters.
Loaded SSH results remain cached until an explicit refresh.
Open workspaces stay in the **OPEN** section; detached sessions and projects are grouped by domain below it.
Each domain heading offers a **+** button and `<C-n>` to create in that domain.
Loading has an elapsed indicator and a bounded timeout; empty and failed hosts keep a visible status row with a refresh/retry action.
Once loaded, the host is listed again whenever the switcher opens.
A host that cannot be listed shows "Sessions unavailable" with the reason; press Enter to retry.

On a session row:

- `<C-x>` kills the session after confirmation;
- `<C-n>` creates a new session in that row's domain;
- `<C-l>` lists every loaded host again and rescans workspace sources.

The refresh key appears only when some domain has `persist = true`.
See the [workspace reference](reference/lua/workspace.md) to change the keys.

Outside the GUI, list what a host owns with the CLI:

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
Hidden panes and window docks are saved too: hiding or showing a pane and docking or undocking it mark the layout dirty.
Reattachment restores the saved structure, dock scope and ratio, hidden flags, and the original processes in its panes.
Workspace docks belong to their workspace; global docks belong to the session that owns their panes.
A global dock is restored only in its owning session, so another session attached to the same window keeps its own global docks.
If a global dock's edge is already occupied by another session's pane, the restored pane becomes a tab instead of replacing the occupant.
Creating an edge or dock split directly in a session-backed workspace is rejected; move an existing pane into a dock with `hollow.term.dock_pane` instead.
Ordinary geometry edits settle briefly before saving rather than serializing a layout on every drag frame.
Closing a tab or workspace waits for pending pane creation and includes the acknowledged child in the close operation.

Each workspace permits one pending pane creation at a time.
Another request while it is busy reports an error rather than silently falling back or duplicating a spawn.
Pane domains must remain the workspace's domain; use another workspace for another host/domain.
Changing a domain's host profile does not retarget an already attached session.

## Exited panes and missing sessions

Exiting an interactive shell with Ctrl+D or `exit` automatically closes its pane after the owner acknowledges removal.
Ctrl+D inside a running application is still delivered to that application.
Directly launched applications and commands keep their final screen and show a footer with the exit code, unless launched with `close_on_exit = true`.
Shell launches with explicit command or script arguments also retain their output.
Press Enter to respawn the original command in the same cwd, or Ctrl+D to close the pane.
The new process writes below the old output.
If the owner rejects a respawn, a "Pane respawn failed" notice shows its reason; the existing screen stays intact and Hollow never retries automatically.
Bind the `respawn_pane` action, or call `hollow.term.respawn_pane()`, to respawn from elsewhere.
Owners started by an older Hollow cannot respawn, so the footer offers only Ctrl+D.
Owners predating shell-exit policy retain exited shells too; restart the owner after ending its sessions to enable the new policy.

If an attach names a session the owner no longer has, Hollow shows "Session not found on host".
Run `hollow-cli session list` to see live sessions, or open a new workspace.

## Recover a lost create reply

New owners advertise `create-id`, allowing Hollow to reserve a random session ID before sending create.
If the reply is lost, or you cancel after submission, the warning shows that exact ID and an attach command.
The same ID is written to the log with the original domain and returned as `session_id` in an uncertain `new_workspace` completion result.
The ID identifies a possible session, not proof that create succeeded.

List the original domain, then explicitly attach the matching session:

```sh
hollow-cli session list --domain persistent_test
hollow-cli session attach <id-from-warning> --domain persistent_test
```

The workspace switcher can also list and attach it, with confirmation if it is attached elsewhere.
CLI attach takes over another attachment without confirmation, so check the list first.
Hollow never repeats create, automatically attaches, or resends the original startup command during recovery.
The original command may not have run if its reply was lost before publication; inspect the recovered shell before running it yourself.
An ID collision rejects create rather than creating another process or implicitly attaching.
Older owners do not support reserved IDs; their warning still asks you to find the session through the list.
Recovery notices are not saved across GUI restarts; use the log or session list if the notice is gone.

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

Once every startup attach has finished, the session you had focused last is focused again.
Shell integration works without client-local pane IDs in persistent panes, and the owner retains the shell-reported foreground command for reattachment.
This keeps foreground-process-based tab labels and plugins such as smart-splits working after reconnecting.
After updating shell integration or owner code, existing owners and shells must be restarted after their sessions end; updating the GUI alone does not replace a running owner or install hooks in an existing shell.

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

## Performance and benchmark timing

Persistent sessions parse output in the host owner before forwarding it to the GUI.
The owner answers the DSR query used by `./bench.sh repaint`, so its printed timings and shell `time` can finish before the GUI has drained the forwarded output.
Those timings do not establish GUI display throughput or time to the final visible frame.

The GUI adapter combines queued output frames within each bounded parser read, as ordinary PTYs do.
Without combining them, the GUI's 16-read poll limit could process only 64 KiB when transport frames were 4 KiB, despite a 2 MiB byte limit.
Combining frames removes that artificial cap without changing parser time budgets, receive-ahead bounds, or the owner's credit window.
This is a GUI-only fix; an existing owner need not be restarted for it.

## Qualification checks

### Native Windows bundle replacement

Run `zig build --build-file build-agent.zig test-session-native-windows -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe --summary failures`.
The private live-owner fixture now replaces its bundle with a real executable built in a different optimization mode, publishes a new checksum-addressed cache entry, and uses that executable's bridge to reattach to the original owner.
It checks the original owner PID, host identity, shell-variable continuity, and original cached image digest.
After explicitly ending only the fixture session and disconnecting all clients, it waits for natural owner exit, starts the replacement at the same private endpoint, and checks a fresh session works.
This qualifies same-protocol executable replacement, not arbitrary historical protocol or capability skew.
Private fixture owners intentionally use ephemeral host identities across owner restarts; durable production identity has separate tests.
No production owner or installed bundle is modified.

### Otherwise-idle WSL survival

Use a disposable, otherwise-unused distro, never the distro running this checkout or other work.
Keep the Windows-owned keeper and its executable on a Windows filesystem so observing the test does not keep a development distro alive.
Record the distro's configured idle timeout without changing `.wslconfig`.
Create a persistent session containing a shell variable or counter and record its owner PID and session ID.
Close all GUI clients and unrelated WSL connections to that distro, including shells, editors, services, and test runners.
Wait comfortably beyond both the configured idle timeout and the keeper's 30-second drain grace, observing only from Windows without executing guest commands.
Reconnect and verify the original owner PID, session ID, and shell state.
End only the test session, disconnect again, and verify keeper collection followed by the distro returning to its idle stopped state.
Do not use `wsl --terminate` or `wsl --shutdown` as evidence of idle behavior; explicit termination is outside the persistence guarantee.
If another process keeps the distro active, the result is inconclusive rather than a pass.

### Native Windows live-window smoke

An isolated Windows GUI fixture created one persistent session, split its first tab, and added a second tab for three total panes.
It set a PowerShell variable in the first pane, closed the actual window through `WM_CLOSE`, launched a new window, and verified startup restored the same session ID, two tabs, and three panes.
The restored first pane incremented the original variable from 41 to 42, confirming process-state continuity.
Configuration, remembered-session files, IPC metadata, and shell-integration files used private application-data directories.
A test-only forwarding executable added an internal private owner namespace; no namespace override was added to the public Lua API.
The owner was prestarted in that private namespace because detached startup fails closed with `ACCESS_DENIED` under this runner's job restrictions.
Only the private owner was stopped afterwards; the installed GUI and its owners were not restarted.
This is a real-window lifecycle smoke check, not pixel-level visual inspection or otherwise-idle WSL qualification.

## Current limits

- New ordinary panes cannot be spawned directly on a persistent domain; create a workspace instead.
- Moving tabs or panes across a persistent-workspace boundary is rejected.
- Quitting waits briefly (up to 500 ms) for the final layout save; a lost connection can still drop the latest geometry, but never kills owner processes.
- Panes opened or closed after the last save are reconciled on reattach: closed panes are removed from their splits and new panes appear as extra tabs.
- Lost-create recovery is explicit list/attach, not automatic; old owners cannot provide the exact ID.
- Owner crashes, host reboots, and WSL shutdown do not preserve live processes.
- Windows-owned WSL keepalives are implemented; otherwise-idle spare-distro survival remains unqualified.
- Native real-window lifecycle and same-protocol bundle replacement are qualified in private fixtures; permissive-launcher GUI owner startup, visual inspection, and historical version skew remain separate checks.

For implementation details, see the [architecture and implementation plan](persistent-sessions.md).
