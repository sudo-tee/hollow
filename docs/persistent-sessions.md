# Persistent sessions plan

Status: design approved 2026-11-04. Phase 0 (headless VT spike) done: go (see
[Phase 0 results](#phase-0-results-2026-11-04-go)). Phase 1 (Linux owner +
`connect`) done; see [Phase 1 status](#phase-1-status-2026-11-04). Phase 2
(GUI) started: snapshot decoder, asynchronous transport, and session-backed
terminal pane adapter are implemented; workspace/controller wiring is next. See
[Phase 2 status](#phase-2-status-2026-11-04).
Snapshot format revised the same
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
  Interactive-shell exits instead schedule owner-acknowledged close when attached.
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
  has `persist = true` and reattaches the ones this client remembers.
  Remembering is Lua policy (`src/lua/hollow/session_restore.lua`): entries
  `{domain, id, host?}` in `<data dir>/sessions.json`, at most 64, recorded on
  `workspace:new` and dropped when `workspace:closed` reports
  `session_ended`, on a successful kill, or when a reachable host lacks them.
  `domains.X.restore = false` opts a domain out.
- Startup creates a fresh default-domain session only when the list confirmed
  no remembered session survives and no attach outcome is uncertain. Sessions
  attached by another client prompt before take-over.
- SSH hosts are never contacted at startup; a notice and the
  `restore_sessions` action restore them on demand.
- SSH trust is the user's job in v1: the connector is non-interactive
  (`BatchMode=yes`, `StrictHostKeyChecking=yes`), so the host key must already
  be in `known_hosts` and key or agent auth must work (`ssh <host> true`
  succeeds without a prompt). See `docs/reference/lua/host.md`.
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
- Client receive-ahead: the GUI grants credit on receipt while it holds at most
  4 MiB of unparsed output per pane and 16 MiB per connection; beyond that,
  parsing returns credit.
  Returning credit only after parsing capped a pane at one 64 KiB window per
  GUI frame (about 4 MiB/s at 60 Hz).
  Because the owner answers DSR from its own VT, a `repaint` benchmark then
  reported normal numbers while the GUI showed the backlog much later.
  Credit grants coalesce per pane outside the bounded outgoing queue.
  A resync event therefore discards that pane's queued pre-resync output:
  the owner's snapshot already contains it, and replaying it after READY drew
  stale alt-screen frames over the restored primary screen.
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
- Optional, if it fits Phase 2: SSH host-trust layer. Split
  `connector_unavailable` into `unknown_host`, `host_key_changed` and
  `auth_failed`; for an unknown host, show the SHA256 fingerprint and on
  confirm retry once with `StrictHostKeyChecking=accept-new`; a changed key is
  a hard error showing the offending `known_hosts` entry; no password prompts.
  Until then users set up SSH trust themselves (see Startup and UX).

### Phase 2 status (2026-11-04)

Implemented foundation (not yet exposed through GUI workspace creation):
- `src/term/session_snapshot.zig`: caller-owned terminal returned at READY,
  then one history/image record decoded per `next` call. The caller reapplies
  its scrollback limit, keeps the terminal alive until decoder cleanup, and
  may render or parse live bytes between records. Invalid/truncated snapshots
  poison the decoder without destroying the terminal returned by READY.
- Buffer and reader sources are supported. Ghostty's reader is synchronous:
  zero bytes means permanent EOF. Network-backed decoding must run off the
  GUI thread and wait for data, not present temporary starvation as EOF.
  Terminal ownership must be handed off between decode and GUI use, never
  accessed concurrently by decoder and renderer (handoff implemented below).
- `Runtime.terminalWriteMirror` suppresses PTY replies only while parsing
  owner output. The normal callback is restored afterwards because Ghostty
  also uses it for user paste encoding. Native/nonpersistent parsing is
  unchanged.
- GUI and agent build options use the same ghostty package identity helper.
- `zig build test-session-snapshot` verifies READY rendering before history,
  live parsing during history restore, both screens, title, continuation,
  scrollback limit, truncated data, ownership/cleanup, identity, and query
  suppression without losing user paste. Passed on Linux (Debug, ReleaseSafe,
  ReleaseSmall) and Windows x86_64 (via WSL interop); Windows GUI cross-build
  also passed.
  Linux GUI build/full `test` link is blocked by missing X11, Xi, Xcursor,
  GL and ALSA development libraries in this environment.

Session transport implemented (workspace integration described below):
- `src/session/client.zig`: GUI-independent protocol state, request correlation,
  handshake/build-identity validation, owned messages and output-credit ledger.
  Limits per connection: 64 retained requests, 1024 pane metadata slots, and
  512 frames / 8 MiB payload per queue, plus in-flight frames. Requests are
  marked submitted before writing; connection loss distinguishes `not_sent`
  from `uncertain`. No automatic retry, replay, native fallback or new shell.
- `src/session/transport.zig`: asynchronous deployment and `session connect`
  over the existing connectors. One connection per attached workspace, with
  cancellable reader/writer/watchdog tasks, no per-pane I/O threads. Full
  receive queues pause reads without blocking the writer or GUI; returned
  messages own their payloads. Snapshot chunks are exposed as messages;
  decoder/terminal ownership hand-off is handled by the pane layer below.
- Output grants are returned only after parsing, not when a frame arrives.
  Attachment generations prevent stale input/resize/credit from reaching a
  new session with reused pane IDs. Implicit attached-pane actions are held
  off until attach/create replies have been dequeued by the GUI.
- The watchdog uses deadlines and condition waits, not idle polling. Credit
  writes reuse an armed check rather than waking the watchdog per frame.
  Handshake and request timeouts use the configured agent timeout; blocked
  writes time out after 3 s. Shutdown joins blocked I/O, including readers
  paused on full queues. Destroying a bridge only detaches; pane `close` and
  `kill-server` remain explicit protocol requests.
- Verified with `zig build --build-file build-agent.zig test-session-transport`
  in Debug, ReleaseSafe and ReleaseSmall: real-owner detach/reattach, snapshot,
  input, output across credit windows, sibling-preserving close and take-over;
  fake connectors exercise lost replies, unanswered requests, full receive
  queues, oversized headers, blocked writes and idle-watchdog behavior. Pure
  tests cover bounds, allocation failures, stale generations and correlation.
  Existing agent-loop and agent-PTY tests also pass.
- `zig build test-session-client` runs portable client contracts (also passed
  as native Windows tests). `test-session-connector` is an opt-in WSL check:
  `-Dtarget=x86_64-windows-gnu -Dsession-test-wsl=<distro>
  -Dsession-test-agent=<preinstalled-guest-agent-path>`. Passed with a native
  Windows transport through `wsl.exe`: bridge destruction, reattach snapshot,
  and input to the original process. It creates a unique private test endpoint
  and kills its owner afterwards; it does not test WSL idle shutdown.

Session-backed terminal pane adapter implemented:
- `src/pty/session.zig` is a `Pty.session` backend. A workspace controller
  owns the connection and routes frames; the adapter owns bounded pane output,
  not the connector. Received output is credited within the receive-ahead
  bound; parsing releases that bound. Large paste admission is atomic across chunks/allocation failures;
  input, close and resize are generation-fenced. Queue pressure preserves the
  latest resize for retry. Exit status leaves the final terminal intact.
- `deinit` releases only the local view. `requestClose` explicitly queues one
  owner-side pane close and reports admission failure. The future controller
  must retain the connection until close replies/failure and must not remove a
  pane if close admission fails. Window teardown must not call pane close.
- `src/term/session_snapshot_job.zig` decodes the network-backed binary prefix
  off thread and transfers the terminal at READY. Thereafter its worker only
  collects raw history bytes; it never mutates the rendered terminal. After
  `snapshot_end`, GUI polling decodes one history/image record at a time from
  the complete buffer, with no network waits. Thus the screen is usable before
  history transfer finishes, but history decode starts after that transfer.
  VT fallback is streamed into a fresh worker-owned terminal until EOF. Each
  job bounds its queue to 512 frames / 8 MiB and total encoded input to 64 MiB.
- `src/term/session_pane.zig` binds a remote pane without launching a local
  shell, refuses conversion of live panes, and replaces terminal/render/input
  handles transactionally. Readiness, sanitizer state, image/compression caches
  and retained-texture damage are reset. A controller hook releases external
  terminal borrowers (search, etc.) before old terminal destruction; wiring
  app-owned UI state to that hook is still required.
- Post-snapshot live bytes wait for READY installation; they cannot be parsed
  into a blank/old terminal and then overwritten. History can be decoded between
  live parsing/rendering calls. Invalid snapshots preserve the old screen;
  prefix failure holds subsequent parsing pending controller recovery. A late
  history error leaves the already-restored terminal usable.
- Verified with `test-session-pane`, `test-session-snapshot` and
  `test-session-client`: partial reads/credit, paste, stale handles, resize
  pressure, transactional helper allocation, search-borrower release, hidden
  render-helper reconstruction, snapshot/live ordering, malformed data, early
  READY while history is withheld, and cancellation before/after READY. Real
  owner check creates a `Pane`, tears down the view and connector, restores a
  binary snapshot into a new `Pane`, sends input to the original process and
  retains its final screen/exit code 7 before explicit close. Passed on Linux
  (Debug/ReleaseSafe/ReleaseSmall) and native Windows via WSL interop. The real
  owner test uses `HOLLOW_TEST_AGENT=<native-linux-agent>` on Linux or explicit
  `-Dsession-test-wsl=<distro> -Dsession-test-agent=<guest-agent-path>` for WSL.

GUI workspace/controller wiring implemented for an already-attached session:
- The App creates wake-wired session connections and owns the controller and
  connection after publishing a workspace. Pane views borrow the connection;
  App teardown destroys views first, then closes the bridge without remote pane
  closes.
- The GUI frame pumps bounded controller batches before and after pane polling.
  Full pane queues and aggregate snapshot pressure retain one pending frame and
  retry after parsing/history progress. Output credit follows the bounded
  receive-ahead rule above.
- Explicit pane, tab, and workspace closes queue owner-side close requests.
  Views remain until close acknowledgement; rejected requests keep the pane
  usable and allow retry. App-owned find/copy/selection/quick-select borrowers
  are invalidated around terminal replacement without Lua reentrancy.
- After takeover or transport loss, close removes only the disconnected local
  view; it never sends owner mutations against the new viewer. Until owner-side
  moving panes/tabs across session boundaries remains rejected instead of
  creating mixed ownership.
- Workspace snapshot buffering has a 64 MiB aggregate encoded-input cap, in
  addition to transport and per-job bounds.
- `src/session/layout.zig` defines the versioned, owner-pane-ID geometry blob;
  `src/mux/session_layout.zig` captures/restores tab order, tiled split trees,
  floating geometry/restore anchors, focus, maximization, and workspace name.
  Restore validates the whole blob before publishing any views. Unknown versions,
  invalid references, cycles/shared nodes, excessive depth, nonfinite geometry,
  and mismatched pane membership fail without overwriting owner state.
- Layout updates are explicit and revision-checked through the controller. Only
  an acknowledged success advances the local revision; conflicts stop further
  writes until reconciliation. No automatic per-frame serialization or replay.
  Automatic layout saving now follows geometry changes and acknowledged pane
  mutations.
  Owner spawn/close keeps the opaque blob and returns an advanced revision, so
  an in-flight save is fenced but geometry survives a missed follow-up save.
- Attach reconciles the saved blob against live owner panes
  (`codec.decodeReconciled`): closed or duplicate panes are pruned, splits
  collapse into the surviving child, dangling anchors/focus/maximization are
  reset, empty tabs drop, and unreferenced panes become trailing tabs.
  A malformed or oversized blob logs a warning and falls back to one tab per
  pane; an unknown version still fails so an older client never overwrites it.
  The reconciled layout is not written back until the next ordinary save.
- Quit flushes pending geometry (`session_spawn.flushLayouts`, 500 ms total
  budget): it waits for an in-flight save, sends any debounced dirty layout,
  and waits for its acknowledgement while discarding pane output.
- Experimental `domains.<name>.persist = true` now routes workspace creation
  through strict host resolution and asynchronous owner admission, including
  default-domain startup without a disposable ordinary shell.
  `hollow.term.attach_session(id, opts)` explicitly reattaches through the chosen
  persistent domain; workspace snapshots expose `session_id`.
  Host options, request data and callback generation are captured before I/O;
  stale queued session operations are rejected after config reload.
  Native Windows owners remain unsupported; Linux-local, WSL and SSH-to-Linux
  use the existing connector/deployment machinery without native fallback.
- Async admission foundation: `src/session/open.zig` owns a copied create/attach
  request and stops at the matching reply, before consuming pane snapshots or
  output. `src/app/session_open.zig` bounds pending operations to 16, captures
  domain/name and originating Lua callback generation, and transfers successful
  connections to workspace controllers. Request preparation precedes connector
  startup; failed/canceled opens close nonblocking and are joined only after EOF
  (or during shutdown). Submitted requests are never replayed. This is an internal
  App API and the configured startup/domain flow share this implementation.
- Empty-mux preparation: startup automation waits for a terminal target (without
  keeping idle rendering spinning), domain snapshots tolerate no active pane,
  and automatic last-workspace quit is suppressed while a live open is pending.
  Explicit window Quit still works. `beginStartup` binds startup automation to
  its own operation/pane, never to an unrelated terminal that appears first or
  gains focus. A failed/closed startup target does not fall back to another pane.
- `src/session/notice.zig` holds bounded, allocation-free connecting/failure
  status (32 records, latest first). Native rendering works without Lua or any
  terminal panes. Click connecting status to cancel; click failed status to
  dismiss. Uncertain cancellation retains a warning because an owner session may
  already exist; there is no automatic retry. Lua modal/overlay input remains
  above the card. Notice transitions request redraw, but static status adds no
  animation polling. Native GPU appearance still needs a real GUI smoke check.
- `test-session-borrowers` exercises borrower cleanup and App close/ACK behavior
  on Windows. The Linux root test link remains blocked by missing X11, Xi,
  Xcursor, GL, and ALSA development libraries.

Creation/attachment validation now includes real-owner App integration:
- A configured domain creates a workspace, queues an initial command into its
  continuing interactive shell, destroys the GUI/connector, explicitly reattaches,
  and reads the original shell variable before acknowledged close.
- Remote shell arguments are preserved; WSL launcher arguments are unwrapped
  rather than launched on the guest. Persistent children do not inherit transient
  GUI pane/workspace IDs or the client's command endpoint; CLI traffic uses OSC.
- Config and strict-host tests avoid unrelated detached WSL platform discovery.

Owner-backed tabs and splits implemented:
- A bounded GUI operation pool captures workspace/tab/source IDs, callback
  generation, guest spawn data and startup input. One pending spawn per workspace
  is admitted only over that workspace's existing generation-fenced connection.
- New views bind at the spawn reply barrier before subsequent output; new panes
  start from a blank VT, without a redundant snapshot. Failure to publish after
  owner acknowledgement detaches safely for later recovery, never replays spawn.
- Captured destinations/focus survive asynchronous replies, including floating
  splits; missing split targets fall back to another tab in the same workspace.
  Close intents wait until pending spawn is resolved and include the new child.
- Geometry/name/focus saves coalesce behind outstanding revisions and mutations.
  Ordinary edits debounce for 100 ms with a deadline-driven wake, not idle
  polling or per-frame serialization. Rejected/conflicting saves are visible and
  do not automatically overwrite owner geometry.
- Real Windows-to-WSL App tests create two tabs and three independent shells,
  save a split layout, destroy the full App/connector, reattach and verify both
  structure and every shell's variables, then close the workspace through ACKs.

- Session discovery: `src/session/query.zig` runs one list or kill over a fresh
  per-host connector, never attaches and never replays; a lost kill reply is
  `uncertain`. `src/app/session_query.zig` bounds queries to eight slots, frees
  a slot only after its bridge ends and its result is claimed (Lua callback, or
  the CLI's terminal `session_result` read) or 60 s pass. Results mark sessions
  shown in this GUI as `open` and peek saved workspace names from layouts.
  Lua: `hollow.term.list_sessions` / `kill_session` over `term_session_request`.
  Command API/CLI: `session_list`, `session_kill`, `session_result`,
  `session_attach`; `hollow-cli session list|kill|attach`.

- Host identity: the owner creates `<state dir>/host-id` (32 hex chars, 0600)
  once under its lock and sends it as optional `Welcome.host`. A host ID that
  cannot be persisted is not sent. Clients ignore invalid IDs. Controllers keep
  the host from publication; `workspace.session_host`, list/kill results and
  `open` matching (session ID plus host when both are known) use it.

- Dead/missing-session UX: owners advertise `Welcome.features = ["respawn"]`
  and accept `respawn` for exited panes, re-forking the saved spawn under the
  same screen. Clients send it only when advertised and never replay it.
  An exited application/command pane shows a native footer (exit code, Enter respawn,
  Ctrl+D close); Lua `hollow.term.respawn_pane`, action `respawn_pane`, event
  `term:pane_respawned`. `SessionNotFound` gets an actionable notice, and
  open/attach callbacks report `status`, `error`, `outcome`, `remote`.

- Shell-exit policy: owner `PaneInfo.close_on_exit` distinguishes interactive
  shell launches from applications, scripts, and one-shot commands.
  Shell exits (including Ctrl+D) schedule ordinary owner-acknowledged removal;
  applications retain their screen unless explicitly marked `close_on_exit`.
  Reattached exited shells receive the same cleanup, while transport loss never
  triggers it and older owners retain their previous behavior.

- Remembered sessions: `workspace:closed` now also fires for unnamed session
  workspaces with `session_id`, `session_host?` and `session_ended` (true only
  for an owner-acknowledged last close, never for detach, take-over or a lost
  link; the last workspace's closure is emitted before quit). App calls
  `hollow._session_startup(default_domain_or_nil)` once at init; true means
  Lua owns the default domain's first session. Lua API
  `hollow.term.restore_sessions`, `remembered_sessions`, action
  `restore_sessions`. Missing sessions are forgotten silently rather than
  shown as placeholder workspaces.

- Switcher sessions: the workspace switcher is the single GUI entry point.
  `src/lua/hollow/ui/workspace/sessions.lua` keeps per-domain list state
  (idle/loading/ready/failed), lists local/WSL persist domains on open and SSH
  ones only on demand, and emits `workspace:items_changed`. Rows for sessions
  open here or with an attach pending are hidden. Enter attaches (take-over
  asks first); kill confirms, never retries, and re-lists on failure.

Next implementation slices:
1. Manual GUI verification of startup restore, switcher, native notices, and shell auto-close.
2. Recheck repaint visual completion after GUI output-read coalescing; measure any remaining pipeline bottleneck before adding bounded window negotiation.
3. Placeholder workspaces for missing sessions, if wanted.

Respawn rejection now has dedicated native notice wording and preserves the pane's screen and exit status without retry.
Lost-create recovery now uses a random client-reserved ID when the owner advertises `create-id`.
Owners reject collisions instead of attaching or spawning again.
An uncertain create exposes its ID in a native notice, log, and Lua failure callback for explicit list/attach in the original domain.
No automatic create replay, takeover, or startup-command replay occurs; old owners keep the generic warning.
Recovery is not durable GUI-side state: after a restart, use the log or host session list.

The persistent pane adapter now combines queued output frames within each parser read.
Previously, small transport frames consumed the GUI's 16-read allowance one frame at a time, imposing a 64 KiB/tick cap with 4 KiB frames despite a 2 MiB byte budget.
A regression checks byte-quota draining through a final repaint marker; time/byte budgets, credit limits, and protocol remain unchanged.
Producer/DSR timings still measure the owner parser rather than GUI completion, so visual confirmation remains necessary.

`persist = true` is experimental and defaults to false.
Native Windows owner and WSL keepalive remain Phase 3.
SSH trust remains user-managed.

### Tests per phase

- In-process owner tests with a fake client: snapshot round trip, take-over,
  dead pane, layout revision conflict.
- Protocol framing unit tests, alongside the existing `protocol.zig` tests.
- Windows owner tests in the existing `windows-latest` job.
- Manual qualification checklist: quit/reopen, killed SSH connection, WSL idle
  shutdown, upgrade with live sessions.
