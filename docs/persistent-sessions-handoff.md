# Persistent sessions handoff

Updated 2026-11-05. Working branch: `feat/persistent-sessions`. Nothing pushed.
Primary plan/status: [persistent-sessions.md](persistent-sessions.md).
User guide: [persistent-sessions-guide.md](persistent-sessions-guide.md).
Earlier commit IDs below predate the user's rebase onto main; use `git log` for current IDs.

## Current checkpoint

- Phase 1 complete: Linux owner/connect; local, WSL and manual SSH checks pass.
- `6b6548c`: GUI snapshot decoder foundation.
- `ab6924a`: asynchronous session transport.
- `3c6157d`: session-backed panes and READY handoff.
- `af9ccd9`: GUI workspace controllers and acknowledged closes.
- `ef13ec6`: versioned layout codec/restore and revision-checked updates.
- `1b35661`: asynchronous workspace create/attach admission.
- GUI workspace/controller wiring now supports publishing an already-attached
  session. App owns controller/connection, pumps bounded frames around pane
  parsing, retries backpressure, and removes panes only after close ACK. App
  borrower invalidation and aggregate snapshot budgeting are wired. `domains.<name>.persist`
   is now exposed experimentally for configured creation and explicit attachment;
   automatic startup reattachment is not implemented.
   Owner-backed tabs/splits and automatic layout saves now exist.
   Next: stale/missing-pane reconciliation, graceful final-layout flush,
   session discovery and remembered host/session identities.
- Leave dirty `third_party/{lua-zluajit,luajit-upstream,nightwatch,sokol}` alone.
- Review hardening: disconnected/taken-over views close locally; generic native
  creation and cross-workspace moves involving session workspaces remain guarded.
  Dedicated owner-backed creation is supported. Workspace count decrements on removal.
  Bounded frame batches request another wake when work remains. Deferred borrower
  cleanup compares activation/pointer identity before validating pane liveness;
  no freed-pane dereferences or selection save/restore across Lua callbacks.
- Layout codec/restore checkpoint: `src/session/layout.zig` validates a strict
  version-1 JSON blob (flat indexed split trees, owner pane IDs, bounded to 256
  KiB, depth 32, 64 panes/tab, 1024 panes/workspace). `src/mux/session_layout.zig`
  captures/restores tabs, splits, floating geometry/anchors, focus, maximization,
  and workspace name. Factory validates before allocating/publishing views.
  Controller layout requests carry current revision, advance only after ACK,
  and fence further writes on revision conflict. Automatic saves are now wired.
- Owner spawn/close keeps opaque geometry and increments/returns revision.
  Attach reconciles stale membership (prune closed, append new panes); a
  corrupt blob falls back to one tab per pane. Quit flushes the last debounced
  layout and waits up to 500 ms total for acknowledgement.
  Real-owner fixture now saves geometry before detach and restores it on attach.
- Layout validation passed Linux Debug/ReleaseSafe/ReleaseSmall and native
  Windows through WSL. Codec tests cover invalid graphs, limits, geometry,
  identities, and allocator failures; mux tests inject allocation failure across
  multi-pane split/floating restore and capture and assert bindings roll back.
  Owner tests cover layout retention on spawn/close and revision advancement.
  Reconciliation passed Linux Debug/ReleaseSafe/ReleaseSmall, agent loop/PTY/
  transport suites, and Windows-through-WSL pane/snapshot/client/borrowers.
- Async-open foundation: `src/session/open.zig` prepares a deep-copied request
  before any transport starts, submits once on readiness, stops at reply barrier,
  and distinguishes not-sent/uncertain/rejected failures without replay.
  Owned attachment replies outlive the opener. `src/app/session_open.zig:begin`
  admits at most 16 operations, owns captured domain/name and callback generation,
  and publishes successful views with connection ownership transferred to App's
  controller. Cancellation/failure retires bridges only after EOF; shutdown joins.
  Zero pending opens take a fast path. Lua/config entry points now exist.
- Async-open tests: copied nested spawn arguments, outcome/cancel/reply barriers,
  independent attachment lifetime, allocator rollback, App publication/cancel,
  capacity rejection, captured name/domain, and real-owner create/attach pass.
  Linux Debug/ReleaseSafe/ReleaseSmall, Windows->WSL pane tests, Windows App tests,
  Windows GUI cross-build pass. Empty-mux startup guards landed; opted-in startup
  now skips ordinary-shell bootstrap and uses asynchronous owner creation.
- Native notice/targeting checkpoint: `src/session/notice.zig` stores 32 bounded
  notices without allocation; latest status renders as a top-right native card,
  including empty mux or absent Lua. Connecting click cancels, failed click
  dismisses, uncertain cancellation remains a warning until explicitly dismissed.
  Input queues stable notice IDs and honors Lua overlay/modal priority. Notice
  transitions requestRedraw; no idle animation loop. No-notice render layer/order
  stays unchanged. GPU appearance has NOT been manually verified.
- `beginStartup` now captures operation ID; publication binds startup command to
  that operation's pane ID, regardless of later focus. Failure, cancellation,
  missing/closed target, or disconnected session cannot reroute startup command
  into another terminal. Native default remains active-pane behavior. Tests cover
  focus changes, unrelated panes, target disappearance, notice state, cancellation
  uncertainty, redraw wake, and bounded/clipped status geometry. Windows App
  tests and GUI cross-build pass; Linux session/headless suites pass.
- Domain-entry checkpoint: `src/app/session_domain.zig` resolves hosts strictly
  through `Runtime.sessionHost` / `hollow._session_host`, prepares bounded guest
  argv/env and admits the async opener. `persist=true` supports named workspace
  creation and default-domain startup; native defaults are unchanged.
  Windows-native hosts fail visibly; Linux-local, WSL, SSH Linux use agent owners.
  Public `hollow.term.attach_session(id, {domain,name,on_complete})` reattaches;
  `workspace.session_id` exposes owner identity for manual recovery.
  Startup currently creates a NEW session, not automatic reattach.
- New workspace commands are prepared before connector start, transferred into
  the published pane's startup-input queue, and run inside its continuing shell.
  They must NOT be sent as `Spawn.command` (shell would exit after command).
  Actual guest shell argv is preserved; WSL launcher strings are unwrapped.
  Persistent owner children clear inherited GUI IDs/command endpoint and use OSC.
  Domain env cannot inject transient GUI endpoint/ID bindings.
- Rebase complete onto main; native-notice checkpoint is `65158da`.
  New config tests no longer spawn detached platform discovery: Runtime test
  construction disables that unrelated worker. Explicit session queue entries
  carry Lua generation; stale requests cannot reroute after config reload.
  Workspace argument copies are all-or-nothing under OOM, never dropped to null.
- `test-session-borrowers` accepts the existing `-Dsession-test-wsl` and
  `-Dsession-test-agent` options for an isolated real-owner App test: configured
  create + initial command -> full App teardown -> explicit attach -> original
  shell variable -> acknowledged close. It uses a unique endpoint, never kills
  the user's ordinary owner. GUI appearance still needs manual smoke check now
  that configuration exposes a real entry path.
- `cef7219`: opt-in domain creation, persistent startup and public explicit attach.
  User verified actual reattachment; reported tab/split no-ops, which drove the
  current owner-backed mutation slice.
- `src/app/session_spawn.zig` now owns bounded pending tab/split operations.
  It copies process/placement/input/callback data, compares current domain target
  to captured connection options, and submits over the existing owner connection.
  One queued/inflight spawn per workspace; no replay after admission.
  Controller.spawn_active fences close admission and controller retirement until
  reply handling binds the child or explicitly detaches for recovery.
- Dedicated `Mux.addSessionPane` handles captured destination/focus, floating and
  floating-only splits, same-workspace fallback, bounds and allocation rollback.
  Generic native creation remains guarded; cross-session moves stay rejected.
  Newly spawned panes need no snapshot and are output-ready at the reply barrier.
- Layout dirty flags save after spawn/close ACKs and debounce ordinary edits for
  100 ms. App idle wake includes the save deadline, but skips waits blocked on
  network ACKs/mutations. Attach publication suppresses automatic writes so it
  never overwrites owner layout merely by opening it. Rename and focus/layout
  changes persist. Conflicts/rejections surface once as native warnings.
- Close workspace/tab while spawn is pending retains original views until child
  binds, then closes it too. Known successful spawn + GUI OOM detaches rather
  than routing unbound data or killing/replaying an uncertain owner operation.
  Background spawn ACKs do not change focus or scroll another active pane.
- Real App Windows->WSL fixture now verifies two tabs/three original shells and
  nested split structure survive full GUI teardown/explicit attach. Mock tests
  cover reply/output barriers, serialized saves, debounce wake, close races,
  host drift, lost reply, UI allocation failure, rename and background scroll.

- Receive-ahead checkpoint (2026-11-05): user saw `bench_workloads.py repaint`
  report normal numbers in a persistent pane while the GUI displayed results
  late. Cause: credit returned only after parse, i.e. one 64 KiB window per GUI
  frame, and owner VT answers the bench's drain DSR itself.
  `src/session/client.zig` now grants on receipt under per-pane/aggregate
  bounds, coalesces grants per pane outside `outgoing`, and retries grants
  withheld by the aggregate bound when another pane parses.
  Owner protocol and 64 KiB in-flight window are unchanged.
  Tests pass (Linux Debug/ReleaseSafe/ReleaseSmall, Windows->WSL incl.
  borrowers, Windows GUI cross-build).
  Follow-up regression: owner resyncs once all credit is back, which no longer
  means "all parsed"; stale queued frames replayed over the snapshot (bench
  frames left on primary screen). Controller resync now drops queued output
  and releases its receive-ahead. User still reports a small residual lag:
  likely 64 KiB window / WSL RTT; window negotiation not started.
- `7beae1e`: stale layout reconciliation, quit flush and receive-ahead.
- Discovery checkpoint (slice 2, uncommitted): `session/query.zig` (single-use
  list/kill, never replayed) and `app/session_query.zig` (8 bounded slots,
  pumped beside `session_open`, result claimed once or expired after 60 s,
  bridge destroyed only after EOF). `session_domain.resolve` /
  `inheritedDomain` / `validSessionId` are shared by open, attach and queries.
  Lua `list_sessions`/`kill_session` reuse the job-request bridge
  (`term_session_request`, `invokeJobCallback`, Lua flattens `payload`).
  Command kinds `session_list`/`session_kill` return `{query, revision}`;
  `session_result` polls; `session_attach` is queued. Native CLI waits with
  `wait_revision` over socket, else 50 ms polls, for max(--timeout, 10 s).
  Real-owner Windows->WSL App test lists the reattached session (open,
  attached, saved name, three panes) and gets `rejected` for an unknown kill.
  Not yet done: actionable dead/missing-session UX, host identity storage,
  a GUI picker; manual GUI smoke of the CLI against a running instance.

## Architecture / invariants

- One persistent workspace = one host session; per-workspace connector.
- `session serve` owns PTYs and authoritative headless VT; client never replays
  an uncertain create/spawn. Explicit pane close kills; view/app teardown detaches.
- Socket `/tmp/hollow-session-$UID` (0700); `HOLLOW_SESSION_DIR` absolute override
  for fixtures. Do not use XDG runtime dir (deleted at last logout).
- GUI/agent share pinned ghostty package identity. Foreign identity gets VT
  fallback, same identity binary snapshot.
- Snapshot job decodes network-backed READY on worker, then only buffers raw
  history. GUI owns terminal after READY and decodes history records after EOF.
  No concurrent worker/render mutation; no network waits on GUI thread.
- Live bytes wait until READY installation. Credit is granted on receipt within
  bounded receive-ahead (4 MiB/pane, 16 MiB/connection), else after parsing.
- SessionPty borrows connection. Workspace controller must keep connection alive
  through explicit close replies/failure. `deinit` must not issue remote close.
- Terminal replacement allocates helpers first. Controller-owned search/etc.
  borrowers must be released with `session_before_replace` before freeing old VT.
- SSH trust remains user-managed. Windows owner/WSL keepalive remain Phase 3.

## Validation

- Zig 0.17.0. Always use explicit build file/options if configure-cache selection
  appears stale (`-Dagent-only=false` for GUI graph).
- `zig build --build-file build-agent.zig test-session-transport test-agent-loop test-agent-pty`
- `HOLLOW_TEST_AGENT=$PWD/zig-out/agents/linux-x86_64/hollow-agent zig build --build-file build.zig test-session-pane test-session-snapshot test-session-client test-background test-search -Dagent-only=false`
- Repeat pane/snapshot/client suites with `-Doptimize=ReleaseSafe|ReleaseSmall`.
- Windows tests through WSL interop:
  `zig build --build-file build.zig test-session-pane test-session-snapshot test-session-client -Dtarget=x86_64-windows-gnu -Dsession-test-wsl="$WSL_DISTRO_NAME" -Dsession-test-agent=/tmp/opencode/hollow-session-agent-next`
  That guest binary was copied from `zig-out/agents/linux-x86_64/hollow-agent`;
  rebuild/copy again if owner/protocol changes.
- Windows GUI cross-build passes. Linux GUI/full-test linking is blocked by
  missing X11/Xi/Xcursor/GL/ALSA dev libraries; isolated headless tests work.
- Current validation: Debug session/pane/snapshot/client/background/search suites
  pass; pane/snapshot/client repeat in ReleaseSafe and ReleaseSmall. Windows
  WSL-interoperated session pane/snapshot/client tests pass, as does
   `test-session-borrowers` and the Windows GUI cross-build.
- Real-pane fixture checks binary snapshot after full view/connector destruction,
  input to original process, retained screen/exit 7, then explicit close.
- Latest mutation validation: Windows App/GUI plus real Windows-to-WSL three-shell
  detach/restore test passed; Linux pane/snapshot/client suites passed in Debug,
  ReleaseSafe and ReleaseSmall; agent loop/transport/PTY regressions passed.
  All 940 Lua tests passed; Zig formatting and `git diff --check` passed.
  Markdown lint could not run: local `npx --no-install markdownlint` has no executable.

## Runtime / delegation

User approved cheaper-model delegation. All delegated work and reviews completed.
Review findings for background-pane scrolling and unsaved workspace rename were
fixed and covered by regression tests.

Current entry map: `newWorkspace` branches after domain/cwd inheritance into
`session_domain.begin`; explicit `attach_session` input calls `session_domain.attach`.
Strict host resolution is `Runtime.sessionHost` / `hollow._session_host`, never
the ordinary PTY resolver's nullable/fallback path.
Configured persistent startup skips `mux.bootstrapSingle`, publishes empty mux,
installs callbacks/renderer, then admits `session_open.beginStartup`.
Keep pending operations separate from attached controllers.
Never replay uncertain create or fall back to native spawn.
Keep callback refs generation-guarded and copy request data before network work.
Normal GUI startup now remains a regression check; persistent connecting/error
cards can be tested by the opt-in domain recipe in the guide.

No reliable account-quota / 5-hour-window telemetry is available. Wall-clock
checkpoint began at 2026-11-04 13:44:47 -05:00; that is NOT the account window's
start. Refresh this handoff at milestones rather than relying on a final message
being possible after a quota interruption.
