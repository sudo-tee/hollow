# Persistent sessions handoff

Updated 2026-11-05. Working branch: `feat/persistent-sessions`. Nothing pushed.
Primary plan/status: [persistent-sessions.md](persistent-sessions.md).

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
   is NOT enabled; no config-driven create/attach, host binding, or startup
   reattach yet. Next: dead/missing-session UX, domain config, automatic layout
   saves/reconciliation, then reattach.
- Leave dirty `third_party/{lua-zluajit,luajit-upstream,nightwatch,sokol}` alone.
- Review hardening: disconnected/taken-over views close locally; new tabs/splits
  and cross-workspace moves involving session workspaces are rejected until
  owner-backed spawn/layout exists. Workspace count decrements on removal.
  Bounded frame batches request another wake when work remains. Deferred borrower
  cleanup compares activation/pointer identity before validating pane liveness;
  no freed-pane dereferences or selection save/restore across Lua callbacks.
- Layout codec/restore checkpoint: `src/session/layout.zig` validates a strict
  version-1 JSON blob (flat indexed split trees, owner pane IDs, bounded to 256
  KiB, depth 32, 64 panes/tab, 1024 panes/workspace). `src/mux/session_layout.zig`
  captures/restores tabs, splits, floating geometry/anchors, focus, maximization,
  and workspace name. Factory validates before allocating/publishing views.
  Controller layout requests carry current revision, advance only after ACK,
  and fence further writes on revision conflict. No automatic layout saves yet.
- Owner spawn/close clears opaque geometry and increments/returns revision;
  otherwise strict pane membership would make reattach fail after pane mutation.
  Safe fallback is one tab per pane until the next explicit layout save.
  Real-owner fixture now saves geometry before detach and restores it on attach.
- Layout validation passed Linux Debug/ReleaseSafe/ReleaseSmall and native
  Windows through WSL. Codec tests cover invalid graphs, limits, geometry,
  identities, and allocator failures; mux tests inject allocation failure across
  multi-pane split/floating restore and capture and assert bindings roll back.
  Owner tests cover layout invalidation on spawn/close and revision advancement.
- Async-open foundation: `src/session/open.zig` prepares a deep-copied request
  before any transport starts, submits once on readiness, stops at reply barrier,
  and distinguishes not-sent/uncertain/rejected failures without replay.
  Owned attachment replies outlive the opener. `src/app/session_open.zig:begin`
  admits at most 16 operations, owns captured domain/name and callback generation,
  and publishes successful views with connection ownership transferred to App's
  controller. Cancellation/failure retires bridges only after EOF; shutdown joins.
  Zero pending opens take a fast path. No Lua/config API exposed yet.
- Async-open tests: copied nested spawn arguments, outcome/cancel/reply barriers,
  independent attachment lifetime, allocator rollback, App publication/cancel,
  capacity rejection, captured name/domain, and real-owner create/attach pass.
  Linux Debug/ReleaseSafe/ReleaseSmall, Windows->WSL pane tests, Windows App tests,
  Windows GUI cross-build pass. Empty-mux startup guards landed, but startup still
  unconditionally boots the ordinary shell until config/UI wiring is ready.
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
- Live bytes wait until READY installation; credit returned after parsing.
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

## Runtime / delegation

User approved cheaper-model delegation. Read-only mapping/review were launched
at start of current work; incorporate their results when available.

Next domain-create integration map (read-only exploration): branch in
`src/app/session_controller.zig:newWorkspace` after domain/cwd inheritance;
snapshot all arguments into an app-owned pending operation and use
`session_open.begin` with captured request/options; it now handles ready ->
create/attach request -> matching reply -> named workspace publication. Pending
operations are separate from attached controllers.
Never replay uncertain create, never fallback to native spawn. Guard callback
refs with originating Lua runtime generation across config reload. Domain bool
parsing lives in `lua_bridge.zig:applyDomainTable`; it must precede the string-only
guard and register domains even if no shell field exists. Host resolution is
`Runtime.ptyHost` / `hollow._pty_host`; errors/null must fail closed, not imply
local transport. Guest argv/env helpers are currently private in `pty/agent.zig`.
Startup still unconditionally calls `mux.bootstrapSingle`. Empty-mux audit found
ordinary render/input loops safe; domainValue and startup-command/no-pane handling
are now guarded. Pane-independent native Connecting/failure UI and startup-command
target binding now exist, but still need a real GUI smoke check. Use
`session_open.beginStartup` rather than plain `begin` for startup so command target
cannot drift to another pane.
Publish empty mux, install callbacks/renderer, then admit async startup. Do not
enable persistence only for later workspaces and silently leave an opted-in
default domain's startup pane nonpersistent.

No reliable account-quota / 5-hour-window telemetry is available. Wall-clock
checkpoint began at 2026-11-04 13:44:47 -05:00; that is NOT the account window's
start. Refresh this handoff at milestones rather than relying on a final message
being possible after a quota interruption.
