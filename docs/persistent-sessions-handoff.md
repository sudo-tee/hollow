# Persistent sessions handoff

Updated 2026-11-05. Working branch: `feat/persistent-sessions`. Nothing pushed.
Primary plan/status: [persistent-sessions.md](persistent-sessions.md).

## Current checkpoint

- Phase 1 complete: Linux owner/connect; local, WSL and manual SSH checks pass.
- `6b6548c`: GUI snapshot decoder foundation.
- `ab6924a`: asynchronous session transport.
- `3c6157d`: session-backed panes and READY handoff.
- GUI workspace/controller wiring now supports publishing an already-attached
  session. App owns controller/connection, pumps bounded frames around pane
  parsing, retries backpressure, and removes panes only after close ACK. App
  borrower invalidation and aggregate snapshot budgeting are wired. `domains.<name>.persist`
  is NOT enabled; no config-driven create/attach, host-bound layout, or startup
  reattach yet. Next: dead/missing-session UX, domain config/layout, then reattach.
- Leave dirty `third_party/{lua-zluajit,luajit-upstream,nightwatch,sokol}` alone.
- Review hardening: disconnected/taken-over views close locally; new tabs/splits
  and cross-workspace moves involving session workspaces are rejected until
  owner-backed spawn/layout exists. Workspace count decrements on removal.
  Bounded frame batches request another wake when work remains. Deferred borrower
  cleanup compares activation/pointer identity before validating pane liveness;
  no freed-pane dereferences or selection save/restore across Lua callbacks.

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
   `test-session-borrowers` (12 tests) and the Windows GUI cross-build.
- Real-pane fixture checks binary snapshot after full view/connector destruction,
  input to original process, retained screen/exit 7, then explicit close.

## Runtime / delegation

User approved cheaper-model delegation. Read-only mapping/review were launched
at start of current work; incorporate their results when available.

No reliable account-quota / 5-hour-window telemetry is available. Wall-clock
checkpoint began at 2026-11-04 13:44:47 -05:00; that is NOT the account window's
start. Refresh this handoff at milestones rather than relying on a final message
being possible after a quota interruption.
