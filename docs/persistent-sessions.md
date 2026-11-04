# Persistent sessions plan

Status: design approved 2026-11-04. Phase 0 (headless VT spike) done: go (see
[Phase 0 results](#phase-0-results-2026-11-04-go)). Phase 1 (Linux owner +
`connect`) done; see [Phase 1 status](#phase-1-status-2026-11-04). Phase 2
(GUI) next. Snapshot format revised the same
day to ghostty's binary snapshot API with VT formatter fallback.
Supersedes the unapproved October 26 proposal.

## Goal

Quit Hollow, reopen it (or attach from another machine), and land back in the
same running shells with their screen and scrollback. Processes keep running
while no client is attached.

v1 scope:

- Detach/reattach of live sessions.
- Hosts: native Windows, Linux/WSL, SSH to Linux.
- Opt-in per domain: `domains.<name>.persist = true`. Defaults unchanged.

Out of scope for v1:

- Restore after host reboot or owner crash with live processes (only layout
  and metadata survive; see [Crash and reboot](#crash-and-reboot)).
- Scrollback on disk.
- Simultaneous multi-client viewing.
- Remote attach to native Windows hosts.
- Porting `hollow-agent stdio|pty|mux` to Windows.

## Model

Follows the Rex/Tern model: the server owns the session, clients are views.

| Term | Meaning |
| --- | --- |
| Host | Machine that runs one session owner. Identified by host ID. |
| Session | One Hollow workspace living on one host. Identified by host ID + session ID. |
| Pane | One terminal (PTY + headless VT) inside a session. Has a pane ID. |
| Client | A Hollow GUI (or CLI) connected to an owner. |

Rules:

- One session maps 1:1 to one Hollow workspace.
- A persistent workspace is bound to its host. Splits and new tabs spawn on
  that host; requesting another domain inside it is rejected. Non-persistent
  workspaces keep free domain mixing.
- Every new workspace on a `persist = true` domain is persistent. Existing
  non-persistent workspaces cannot be converted (a live PTY cannot move into
  the owner).
- `pty.mode` is ignored on persistent domains; config warns if both are set.
- Closing a pane kills it. Closing the window or quitting Hollow detaches.
  An explicit detach action exists.
- One attached client at a time. A new attach takes over; the previous client
  is detached with a "session taken" notice (like `tmux attach -d`).

## Layout ownership

- The owner owns structure: which panes exist, which tab they belong to, tab
  order. It enforces this on pane create/kill.
- The GUI owns geometry: nested split tree, ratios, focus, floating and
  maximized state, tab names. It is stored in the owner as an opaque,
  Hollow-defined blob with a revision number; stale writes are rejected.
- Lua panes (REPL, sidebar, `ui.pane.register` panes) are stored in the blob as
  specs (module, args, bounds) and recreated by the attaching client. No Lua
  state is preserved.
- `.hollow/workspace.json` stays a hand-edited template; it is never
  overwritten by session state.

## Owner process

One owner per host: `hollow-agent session serve`. Clients use
`hollow-agent session connect`, a stdio-to-endpoint bridge, so remote hosts are
reached through the existing connectors (`wsl.exe ...`, `ssh ...`). The native
Windows GUI connects to the named pipe directly.

| | Linux | Windows |
| --- | --- | --- |
| Endpoint | Unix socket in a `0700` per-user dir under `/tmp` | Named pipe, ACL current user SID only, remote clients rejected |
| Start | `session connect` starts the owner if the socket is missing (lock file, `setsid`, double fork) | GUI starts it with `DETACHED_PROCESS \| CREATE_BREAKAWAY_FROM_JOB` |
| PTY | `forkpty`, no `PR_SET_PDEATHSIG` tied to the client | ConPTY (reuse `src/pty/pty_windows.zig`) |
| Kill tree | Process group | One Job Object per pane, `KILL_ON_JOB_CLOSE` |

- Endpoint path includes the protocol major version, e.g.
  `.../hollow/session-v1.sock`. A new GUI talks to older owners whose version
  it supports; unsupported owners are listed as "outdated, kill to upgrade".
  New sessions always go to a current owner.
- The owner exits when its last session ends. It never kills live sessions on
  idle. `kill-server` is the escape hatch.
- No auth token: same trust model as tmux. Connectors (ssh, wsl.exe)
  authenticate remote access.
- Only the `session` subcommand is ported to Windows. Platform code lives in
  per-OS files (`session_posix.zig`, `session_windows.zig`) selected at
  comptime.

### WSL keepalive

A WSL distro shuts down about 15 s after its last `wsl.exe` console connection
closes (`instanceIdleTimeout`, default 15000 ms), killing background processes.
The Windows owner holds a hidden `wsl.exe -d <distro>` keepalive per WSL host
with live sessions and drops it when that host's session count reaches zero.
The GUI always starts the Windows owner, even for WSL-only use. Hollow never
edits `.wslconfig`.

## Terminal state and wire

- The owner runs a headless ghostty-vt per pane. It is the source of
  snapshots and the only responder to terminal queries (DA, DSR, OSC color),
  so programs never wait on an absent client.
- Attach: the owner pauses PTY reads, sends a snapshot, then streams raw PTY
  bytes. The client feeds both into its own ghostty mirror with PTY replies
  disabled.
- Snapshot format: ghostty's binary snapshot API (`ghostty_snapshot_*`,
  enabled by default in the pinned ghostty). It covers both screens, saved
  cursor, title, modes, palette, tabstops, PWD, mouse state, Kitty keyboard,
  hyperlinks, and optionally Kitty images. Records stream terminal and screen
  state, then READY, then history pages newest to oldest, so the pane is usable
  before scrollback finishes.
- The snapshot format has no cross-build compatibility guarantee. The session
  handshake carries the ghostty build identity. On mismatch (e.g. an older
  owner after an upgrade), the owner falls back to the VT formatter: screen and
  scrollback survive, but title, saved cursor, and the inactive screen do not.
- The owner caps scrollback per pane using the existing scrollback config.
- Input goes to the owner, which is the single writer to the PTY.
- Size: the attached client's pane size wins. The owner resizes on attach and
  on every client resize, and keeps the last size while detached.
- Partially read escape sequences: the owner sets
  `GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES` at terminal creation so the
  snapshot can encode them. The VT formatter fallback cannot, so it forwards
  unparsed trailing bytes after the snapshot.

## Lifecycle edges

- Dead pane: when a process exits, the owner keeps its final screen and exit
  code until a client closes or respawns it. The client shows a placeholder
  with respawn/close keys.
- Missing session on reopen: same placeholder, using the last known cwd and
  command. Hollow never silently starts a fresh shell.
- Activity while detached: the owner keeps a bounded per-session event log
  (last 256 events: bell, exit, title, notification OSCs) and replays it to the
  Activity Center on attach.
- In-pane CLI: inside persistent panes `hollow-cli` uses HTP over the tty
  (OSC 1337), forwarded by the owner to the attached client. Env carries only
  stable host, session, and pane IDs, never a GUI address. While detached, CLI
  calls fail fast with "no client attached".

### Crash and reboot

The owner writes each session's layout blob and per-pane metadata (cwd,
command, title, last exit code) under the host's state dir on every change.
After an owner crash or host reboot, panes come back as dead-pane
placeholders in their original layout. Scrollback is not written to disk in v1.

## Startup and UX

- On launch, Hollow lists sessions on every local and WSL host whose domain
  has `persist = true` and reattaches the ones this client last had attached.
- SSH hosts are listed lazily; startup never blocks on an unreachable host.
- Other sessions appear as "detached" in the workspace switcher and attach
  when picked.

## Scripting surface

- Lua: `hollow.session.list`, `attach`, `detach`, `kill`; events
  `session_attached`, `session_detached`, `session_taken`.
- CLI: `hollow-cli session ls|attach|detach|kill|kill-server`.
- All are registered actions, so they are bindable and in the palette.

## Delivery

Each phase merges independently behind `persist = true`.

| Phase | Scope | Exit criteria |
| --- | --- | --- |
| 0 | Headless VT spike | (1) ghostty-vt links into the agent for static musl (x86_64, aarch64) and Windows; binary size recorded. (2) Binary snapshot encode/decode round trip matches under real workloads: shell with scrollback, vim (alt screen with main scrollback preserved), htop, resize while detached, mid-sequence snapshot. VT formatter fallback checked for screen + scrollback. Gaps get a local ghostty patch, not a downgrade to raw replay. Go/no-go recorded here. |
| 1 | Linux owner + `connect` | Single pane survives client disconnect over WSL and SSH; snapshot attach; take-over. |
| 2 | GUI session workspaces | Session PTY backend, layout blob, auto-reattach, dead panes, host binding. |
| 3 | Windows owner | ConPTY, Job Objects, named pipe, WSL keepalive, `windows-latest` CI. |
| 4 | Polish | Activity log replay, version skew handling, switcher UI, CLI and Lua surface. |

### Phase 0 results (2026-11-04): go

Spike: `spikes/session-snapshot/src/main.c`, built by the temporary
`zig build spike-session-snapshot` step in `build.zig` (reuses Hollow's
`ghostty_dep`). It feeds a recorded PTY stream into a source terminal, encodes
a snapshot, decodes it incrementally, and compares VT format (active screen,
scrollback, all extras), title, pwd, size, cursor, active screen, cursor
visibility, mouse tracking, and scrollback rows. It compares at restore, after
the rest of the stream, and after `ESC[?1049l ESC 8` (primary screen and saved
cursor).

Linking (ReleaseFast, stripped spike binary, almost all of it ghostty-vt):

| Target | Size | Ran |
| --- | --- | --- |
| x86_64-linux-musl, static | 2.35 MB | yes |
| aarch64-linux-musl, static | 2.09 MB | link only (no qemu) |
| x86_64-windows-gnu | 2.29 MB | yes, via WSL interop |

For scale, the current stripped `hollow-agent` is about 7.1 MB.

Round trip (recordings via `script` at 100x30): shell with 5k lines, colors,
title, OSC 7, OSC 8; vim with main scrollback underneath; htop; nvim; 100k
colored lines at 200x50 (8.8k rows retained under a 16 MiB cap).

- All semantic checks pass for full recordings, mid-sequence cuts (`ground=0`),
  and resize while detached (80x24, 140x50).
- Cut sweep every 37 bytes through htop, nvim, vim (1780 cuts): 0 failures.
- 100k-line case: 2.4 MB snapshot, encode 4-7 ms, READY 0.6-1.5 ms, history
  37 pages in about 10 ms.
- Snapshots are byte-identical between Linux musl and Windows builds and decode
  across them in both directions, so a Windows client can read a WSL owner's
  snapshot if both use the same ghostty build.
- VT formatter fallback matches plain text, cursor, and scrollback rows.

Findings to carry into Phase 1:

- Re-encoding a restored terminal is not byte-identical to the source (style
  IDs and page packing differ). Compare semantically, never by snapshot bytes.
- Scrollback limits are not in the snapshot. The decoding side must set
  `GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES` itself after READY.
- Because pages are packed differently, the owner and the mirror reach the
  byte cap at slightly different rows (about one page, e.g. 8852 vs 8619 rows).
  Newest content stays identical; only the oldest history differs. Accepted:
  the mirror is a view.
- ghostty-vt adds about 2.1-2.4 MB to the agent. Phase 1 must decide how the
  standalone agent build (`build-agent.zig.zon`, no GUI deps today) gets the
  ghostty dependency.

### Phase 1 decisions (2026-11-04)

- Build: `src/agent/build_steps.zig` links `ghostty-vt-static` into the agent.
  `zig build --build-file build-agent.zig` reads `build.zig.zon` (not
  `build-agent.zig.zon`), where ghostty is already an eager URL dependency, so
  the agent build stays submodule-free.
- Framing: the 9-byte `kind/stream/len` envelope from `pty_protocol.zig`, with
  session-specific kinds and its own hello (as `mux` does). Stream = pane ID,
  stream 0 = control. Overhead about 0.05% per 16 KiB frame, same as `mux`.
- Payloads: JSON for control (hello, list, create, attach, spawn, kill,
  layout); binary for input, output, resize, snapshot chunks, exit status.
- Slow client: the owner always drains PTYs into its VT. Per-pane credit as in
  `mux` (64 KiB window). If a pane's unsent output to the client exceeds 4 MiB,
  the owner drops it and sends a fresh snapshot (tmux-style resync).
- Threading: one poll loop that also feeds ghostty. No reader threads in v1;
  add them only if measurements need it.
- Debug client: hidden `hollow-agent session debug-attach` (raw tty, snapshot
  redraw via VT formatter, input pass-through, detach key) for manual WSL/SSH
  checks. Automated tests stay in-process with a fake client.
- IDs: session ID = 128-bit random hex from the owner; pane ID = per-session
  `u32` counter, never reused; host ID stays GUI-side.
- Paths (Q49): socket `/tmp/hollow-session-$UID/session-v1.sock` (create
  `0700`, refuse on wrong owner or mode), lock `session-v1.lock` and
  `owner.log` beside it, state `$XDG_STATE_HOME/hollow/sessions/<id>.json`.
  Not `$XDG_RUNTIME_DIR`: without linger, systemd deletes `/run/user/$UID` when
  the user's last login session ends (an SSH drop), taking the socket of a
  still-running owner with it, so the next connect would start a second owner
  and orphan the sessions. Not `/tmp/hollow-$UID`: that is the `0755` shell
  integration dir. The owner touches socket and lock hourly so tmpfiles aging
  never removes them. `HOLLOW_SESSION_DIR` (absolute) overrides the dir for
  tests.
- Why a socket: the owner outlives every client, and stdio pipes only exist
  between a parent and its child. A filesystem-named unix socket lets any later
  client of the same user find the running owner and open its own connection.
  `session connect` bridges connector stdio (ssh, wsl.exe) to it. FIFOs are
  one-way, localhost TCP is reachable by every user, and abstract sockets have
  no file permissions.
- Snapshot send: `ghostty_snapshot_encode_alloc` while PTY reads are paused,
  then frames of at most 16 KiB; the client decodes incrementally.
- Spawn: reuse `pty.zig` spawn (`Spawn` JSON, shell integration, `path_style`)
  without the parent-death signal.
- ghostty binding: C API via translate-c (`ghostty_c`), as in the GUI. The C
  API is Zig compiled into the same static library, so a call is a plain
  function call; the only loss is cross-call inlining, negligible because
  `vt_write` is called per PTY read. Revisit only if profiling shows hot
  per-cell calls.

### Phase 1 status (2026-11-04)

Code: `src/agent/session.zig` (subcommands `serve`, `connect`, `list`,
`kill-server`, hidden `debug-attach`), `src/agent/session_posix.zig` (owner),
`src/agent/session_test.zig` (in-process tests with a fake client on a
socketpair).

Behaviour as built:
- `connect` starts the owner with `setsid` and a double fork. Owner stderr goes
  to `owner.log` in the socket dir. Racing starters are resolved by `flock`
  on `session-v1.lock`; the loser retries for 5 s, then exits.
- Ghostty build identity is the ghostty package hash pinned in
  `build.zig.zon` (passed as a build option). `ghostty_build_info`'s version
  string is `0.1.0-dev` for every dev build, so it cannot tell builds apart.
- Snapshots are encoded lazily per pane, only while the client's queue is
  under 1 MiB, so attaching many large panes never buffers them all at once.
  A pane's output is held until its snapshot is sent; bytes read meanwhile
  are already in the snapshot. Resync uses the same path once the client has
  returned all credit.
- Exit status is sent after PTY EOF, or 200 ms after the reap when a
  background job keeps the slave open; later output only updates the VT.
- Idle shutdown (no sessions, no clients) is cancelled by a new connection;
  `kill-server` and SIGTERM stop listening immediately.
- State files are written atomically on structural changes and removed when
  the session ends.
- Closed panes get SIGHUP to the process group, then SIGKILL after 1.5 s.

Verified: 7 owner tests (binary snapshot attach + take-over + input after
disconnect, VT fallback for a foreign identity, dead pane across reattach,
exit after background-held PTY, idle-stop cancel, layout revision conflict,
credit-starved resync) in Debug, ReleaseSafe and ReleaseSmall. End to end with
the static musl agent: owner autostart (13 ms local, 177 ms via `wsl.exe`),
`connect` killed, `list` shows detached, reattach snapshot, input, `kill-server`
removes socket and state. `debug-attach` checked through a pty (zsh with shell
integration, detach and reattach, exit status). Static agent: 2.6 MB x86_64.
SSH (manual, `debug-attach` over `ssh -t` to WSL's sshd): session survives
both a killed `ssh` client and a killed server-side `sshd-session`; `list`
shows it detached and reattach restores the screen.

Carried into Phase 2:
- Scrollback cap is a fixed 10 MiB per pane until the GUI passes its config.
- The VT fallback does not forward unparsed trailing bytes after the snapshot.
- Title in `list` comes from the owner VT and was empty under zsh
  integration (cwd via OSC 7 works); check in Phase 2.

### Tests per phase

- In-process owner tests with a fake client: snapshot round trip, take-over,
  dead pane, layout revision conflict.
- Protocol framing unit tests, alongside the existing `protocol.zig` tests.
- Windows owner tests in the existing `windows-latest` job.
- Manual qualification checklist: quit/reopen, killed SSH connection, WSL idle
  shutdown, upgrade with live sessions.
