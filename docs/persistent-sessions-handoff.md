# Persistent sessions handoff

Updated 2026-11-10 after Windows-owned WSL keepalive integration qualification.
Working branch: `feat/persistent-sessions`, nothing pushed.
Primary plan/status: [persistent-sessions.md](persistent-sessions.md).
User guide: [persistent-sessions-guide.md](persistent-sessions-guide.md).

## Start here

Feature state: persistence is opt-in per domain (`domains.<name>.persist = true`) for native Linux, WSL, SSH-to-Linux, and now experimental native Windows x86_64 local domains.
A user can create a persistent workspace, close the GUI, and get the same processes, screens, tabs, and splits back.
Startup reattaches remembered sessions automatically (slice 3).
The workspace switcher lists, attaches, kills, and creates sessions (slice 4).
`hollow-cli session list|attach|kill` and Lua `hollow.term.list_sessions|kill_session|attach_session|restore_sessions` exist.

Hard rules from the user and project:

- Never touch, stage, or commit the dirty submodules `third_party/{lua-zluajit,luajit-upstream,nightwatch,sokol}`; stage paths explicitly.
- Never replay an uncertain create, spawn, kill, or respawn; report `uncertain` and let the user re-list.
- Bound every queue, payload, and job; overflow is `error.ResourceExhausted`.
- "Commit and continue": commit each finished sub-slice with tests, Conventional Commits scoped `feat(sessions): …`.
- Ship Lua API changes with `types/hollow.lua` and docs (`docs/reference/lua/term.md`, `events.md`, `workspace.md`, `docs/reference/actions.md`, the guide).
- Refresh this handoff and the plan's "Next implementation slices" at milestones.
- Workspace and discovery policy stays in Lua; Zig provides mechanisms.

Commit map (current IDs, oldest first):

| Commit | Content |
| --- | --- |
| `931d872` | Linux owner (`session serve`) and connect bridge |
| `9e3d9f9` | Session socket kept out of `XDG_RUNTIME_DIR` |
| `f28f4ae` | GUI snapshot decoder |
| `b3e7413` | Asynchronous client transport |
| `d771ec3` | Session-backed panes and READY handoff |
| `ca6e05b` | Workspace controllers and acknowledged closes |
| `1961dfc` | Versioned layout codec and revision-checked saves |
| `41fb661` | Async create/attach admission |
| `65158da` | Native status notices, startup-command targeting |
| `cef7219` | Opt-in domain creation, explicit attach |
| `8538661` | Owner-backed tabs/splits, layout autosave |
| `7beae1e` | Stale layout reconciliation, quit flush, receive-ahead |
| `496f032` | Slice 2: list/kill from Lua and CLI |
| `b8f9d39` | Persistent owner host identity |
| `e611a81` | Respawn exited panes, native dead-pane footer |
| `82cab71` | Slice 3: remembered sessions and startup restore |
| `8a33cea` | Slice 4: sessions in the workspace switcher |
| `494178d` | Auto-close exited interactive shells |
| `e274c74` | Dedicated rejected-respawn notice |
| `f93d9b8` | Explicit recovery by reserved create ID |
| `b409297` | Coalesce output frames within GUI parser reads |
| `e2b95ee` | Windows owner-side ConPTY process-tree lifetime |
| `6d6adca` | Secured Windows session-owner bootstrap |
| `06c923a` | Bounded raw Windows connect bridge |
| `13b1b46` | Shared owner metadata and mutation admission |
| `643ae0a` | Shared attachment and bounded stream delivery state |
| `6597ca2` | Windows owner ConPTY/headless-VT pane adapter |
| `e5f7670` | Bounded live single-pane Windows owner |
| `f6d92ca` | Secured, persisted Windows session host identity |
| `764b10a` | Bounded Windows multi-pane spawn/close/respawn |
| `8c359c2` | Preserve PowerShell integration in owner shells |
| `62c9013` | Native Windows persistent domain/App integration |
| `53b5317` | Bounded read-only WSL guest lifetime watcher |

Commit IDs inside the notes below may predate a rebase; trust the table and `git log`.

Open work, in suggested order:

1. User reports GUI behavior works; dedicated checks of switcher confirmations, SSH loading, and startup restore remain unrecorded.
2. Placeholder workspaces for missing sessions, only if the user wants them (slice 3 forgets them silently by design).
3. Phase 3: live-window native Windows smoke, otherwise-idle spare-distro WSL survival, and live-owner upgrade qualification; keepalive admission/lifetime management is implemented below.

Windows-owned WSL keepalive integration:

- Explicit WSL session descriptors now carry copied distro/user/launcher metadata from Lua through strict host resolution into `session/transport.zig`; mismatched connectors fail closed.
- Before spawning a guest bridge, the transport obtains a capability-gated `hold_wsl` pin through a native Windows transport; bridge/I/O teardown precedes pin release.
- `session_keepalive_windows.zig` owns eight bounded host records with at most sixteen client pins; `session_keepalive_process_windows.zig` launches suspended, handle-whitelisted children into unnamed per-keeper kill-on-close jobs.
- The parent uses overlapped pipes and fixed five-byte controls, with coalesced pin updates and generation-checked ACKs before admitting a new create/attach.
- Internal Linux `session wait --hold` retains a WSL connection across observation errors, never starts or takes over an owner, and acknowledges an explicit empty state only after the last pin's 30-second drain grace.
- An admitted helper crash, including status zero without the empty control, retains its host record and repairs only read-only observation; uncertain mutations are never replayed.
- Real private Windows-to-WSL fixtures verify create, copied host identity, original owner PID and shell-variable continuity after all GUI/native guard connections close, re-pin/reattach, explicit kill, and automatic Windows-owner exit after empty collection.
- A missing guest helper rejects before a queued create is submitted; old native owners are also capability-fenced before submission.
- Fixture namespaces, helper paths, and private guest runtime/state paths never come from Lua configuration and never touch production cache, host identity, or owners.
- Conditional Windows argv quoting is essential for WSL's `--exec` tail; always quoting option words caused guest exit 127 during qualification, and a regression now covers it.
- Real fixtures include spaces and apostrophes in the guest agent path and spaces in private guest state paths.
- Updated full agent bundles are required: a GUI-only development rebuild can leave an old Linux helper without `--hold`; existing Linux owners need no restart.
- Windows native owners already running without `wsl-keepalive` fail visibly rather than being replaced automatically.
- This qualifies private Windows/WSL integration, not the idle-stop timer of an otherwise-unused distro; the coding distro stayed running and no GUI or production owner was restarted.
- CI runs the standalone keeper mechanism suite; real WSL fixture tests require explicit distro and agent build options and skip without them.

Validation commands for this slice:

```sh
zig build --build-file build-agent.zig test-session-windows-keepalive -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe --summary all
zig build --build-file build-agent.zig test-session-wsl-keepalive -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe -Dkeepalive-test-agent=/absolute/guest/agent -Dkeepalive-test-distro=Ubuntu --summary all
```

Use a freshly rebuilt guest binary and a private fixture, never the production session directory.
Logs for the final matrix are `/tmp/opencode/wsl-keeper-*-final-20261110.log`; full Lua and bundled syntax checks also passed.

Verified results for this slice:

- Windows keeper mechanism: 23 passed each in Debug, ReleaseSafe, and ReleaseFast.
- Private Windows-to-WSL fixtures: 2 passed in each of those three modes.
- Full native transport/Open/cache: 93 passed, 2 POSIX-only skips each in ReleaseSafe and ReleaseFast, with the WSL fixtures enabled.
- Windows owner Debug: 89 passed, 2 restrictive-job startup/survival skips after fail-closed checks.
- Windows App/borrowers: 53 passed, 1 optional guest-fixture skip each in ReleaseSafe and ReleaseFast; bundled LuaJIT syntax passed.
- Linux Debug transport/owner/PTY: 175 passed; ReleaseSafe graph passed 100 executed tests plus the cached 75-test owner-loop result, and ReleaseSmall owner-loop passed 75.
- Full Lua: 983 successes, no failures or errors; Windows GUI cross-build passed.
- Remaining qualification: actual user windows, otherwise-idle spare-distro survival, and live-owner upgrade behavior; CI was registered but not run locally.

WSL keepalive guest foundation checkpoint (`53b5317`, superseded by integration above):

- `src/agent/session_wait.zig` implements Linux `hollow-agent session wait` using only existing hello/list requests; no Linux wire change or owner restart is needed.
- Startup tolerates a missing owner or empty list for 30 seconds without starting an owner; observing sessions removes that startup limit, and the first subsequent empty list ends the watcher successfully.
- Queries run once per second, with nonblocking I/O, absolute 5-second exchange deadlines, bounded control buffering, and a fixed 512-byte outbound frame buffer.
- It never attaches, takes over, starts processes, or replays mutations; GUI detach does not stop it.
- Established-owner EOF, protocol errors, and timeouts fail rather than reconnect; these failures are not evidence that sessions ended.
- Real-owner regression coverage creates a shell, checks the original client still owns its attachment and unchanged membership revision, destroys that client, observes the retained session past startup expiry, then explicitly kills it and observes completion.
- Additional tests cover missing endpoints, startup boundary races, oversized and foreign frames, malformed replies, absolute deadlines, EOF, SIGPIPE avoidance, query-ID exhaustion, and allocation cleanup.
- Next: add bounded Windows-owner-held WSL process admission keyed by explicit host identity, integrate it before uncertain create/attach can escape GUI lifetime, and qualify real WSL idle survival in an isolated distro/fixture.
- The current GUI and Windows owner do not invoke the watcher; automatic WSL keepalive is still outstanding.
- Validation: 164 Linux Debug transport/owner-loop/PTY tests and 73 owner-loop tests each in ReleaseSafe and ReleaseSmall pass without skips; formatting and diff checks pass.
- A separate private actual-CLI smoke fixture confirms view-detach survival, no takeover, silent successful completion after explicit kill, normal private-owner exit, and extra-argument rejection.
- Logs: `/tmp/opencode/session-wait-{debug,safe,small,cli-smoke}-20261110.log`.
- No Windows code or wire protocol changed, so Windows GUI/owner suites were not rerun for this guest-only slice; no GUI or production owner was restarted.

Native-local Windows admission now resolves the existing explicit local host descriptor and Windows-native agent paths, never implicit/fallback hosts or WSL launchers under the native owner.
`persist` remains false by default, and Linux-local/WSL/SSH deployment and ordinary nonpersistent PTY paths are unchanged.
`session/native_windows.zig` locates an explicit owner or `agents/windows-x86_64/hollow-agent.exe` beside the GUI (including `bin/../agents`) without a Linux probe.
Missing bundles fail visibly and never create disposable panes.
The Windows helper is included in default installs and `gui` developer builds, and launcher preflight checks it before closing an installed GUI.
Managed bundles are copied into an immutable per-user SHA-256 cache before execution; existing mismatched entries fail closed, and old versions remain available to resident owners.
Explicit preinstalled paths remain caller-managed; private namespaces bypass production cache and host state.
Configured interactive PowerShell argv now shares ordinary GUI integration preparation; its profile accepts OSC transport without GUI IDs, while command/file launches and opt-out remain literal.
PowerShell profile paths containing apostrophes are quoted literally.
The internal transport namespace option is copied and validated, never read from Lua/user config, and is used only by isolated Windows fixtures.
The full headless App fixture resolves a native domain, creates three interactive panes through the async opener/controller, flushes layout, destroys the App, and restores matching variables, shell PID, layout, host identity, and owner PID in another App.
No actual user window or production owner was restarted during qualification.

Final native integration validation:

- Native transport/Open/cache suite: 85 passed, 2 POSIX-only skips in Debug, ReleaseSafe, and ReleaseFast.
- Windows owner suite: 85 passed in ReleaseSafe, including configured PowerShell cwd integration.
- Full Windows App/controller borrower suite: 52 passed, 1 guest-fixture skip in ReleaseSafe and ReleaseFast.
- Real cached-owner fixture preserved owner PID, host identity, and interactive state after replacing its private bundle source; old cached bytes stayed unchanged and replacement selected a different cache path.
- Full Lua suite: 982 passed, zero failures or errors.
- Launcher installation tests, Windows GUI cross-build, and Linux transport/agent-loop/PTY regressions passed.
- Native Linux full borrower build remains unavailable here because `xproto.pc` is missing and the compiler aborted; Linux pane/headless suites passed.
- Live-window smoke and otherwise-idle spare-distro WSL qualification remain outstanding.

Windows host identity is now persisted as 32 lowercase hexadecimal bytes at `%LOCALAPPDATA%\hollow\sessions\host-id`.
Production loads it after singleton endpoint admission; fixture namespaces generate ephemeral owner-local identities without touching production state.
Creation uses a current-SID-only protected file DACL, an exclusive random temporary file, flush, and atomic no-replacement publication.
Concurrent creators accept only a validated persisted winner, never an unpublished candidate.
Reads reject malformed bytes, wrong owner, inherited/broad DACLs, directories, and final-component reparse points; existing invalid identity files are not silently replaced.
Persistence failure fails owner startup rather than advertising a different ephemeral production host on every restart.
Eighteen standalone Windows identity/pipe/protocol tests pass in Debug, ReleaseSafe, and ReleaseFast, including reload, corruption preservation, inherited ACL rejection, and concurrent creation.
Filesystem fixtures use unique native Windows temporary directories because the WSL shared repository does not implement Windows file ACLs.

Windows owner multi-pane mutations are now implemented with heap-stable per-pane process/VT/delivery state.
Admission limits are 16 sessions, 16 panes per session, and 64 published panes across the owner, checked before child execution.
Spawn advances pane identity and membership revision only after successful backend creation; close preflights revision before killing, retains layout, and acknowledges the final close before session-end notification.
Respawn uses retained owned launch data, prepares a replacement before changing old state, preserves pane identity/revision/layout/VT, and leaves the old pane untouched on rejection.
An already-running pane rejects respawn with `PaneAlive`, matching Linux wire behavior.
Input, resize, credit, snapshots, foreground sync, and exit status route by the actual pane stream; late frames for closed/exited panes do not disconnect live siblings.
Owner-wide rotating pane visitation with bounded per-pane work prevents a blocked pane from starving siblings.
Respawn that drops unsent output or overlaps an immutable snapshot waits for old credit and emits resync before recapturing, rather than silently diverging or splicing snapshots.
Attach validates every pane size and preallocates its reply before takeover; a later VT resize allocation failure preserves controller bindings but can leave earlier valid sizes applied.
Fatal VT/read failures retain the existing session-fatal policy; per-pane input failure alone does not terminate siblings.
Validation passes 81 owner tests each in Debug, ReleaseSafe, and ReleaseFast; the combined ReleaseSafe owner/pane/ConPTY suite executes 122 tests with no skips on the main runner.
Five real-process multi-pane regressions cover stream routing and fairness, monotonic IDs/revisions/layout retention, takeover, successful/rejected respawn, descendant isolation, and final-close ordering.
Numeric exhaustion/capacity preflight and respawn backlog/snapshot resync are covered by targeted runtime tests.
Linux transport/owner/PTY suites, Windows GUI cross-build, formatting, and diff checks pass; existing user owners were not restarted.

The first live Windows owner now uses `session_runtime_windows.zig` with the shared metadata, attachment, and stream helpers plus owner-side ConPTY/VT.
It supports at most 16 single-pane sessions with 1 MiB scrollback per pane and 4 MiB pending application input per session.
Create/list, attach/detach/takeover, input/resize/credit, layout CAS, session kill, and kill-server are wired; pane spawn/close/respawn remain `Unsupported`.
Welcome negotiates the real Ghostty build identity and binary/VT snapshots, advertises `create-id`, and does not advertise `respawn`.
Snapshots stream incrementally through the existing 1 MiB per-client transport bound; completed writes trigger another runtime turn so retained output cannot be stranded after capacity returns.
Disconnect drops only view delivery state, and last-client disconnect no longer exits an owner that retains sessions.
Process/output/writer events wake the transport loop; exit linger permits exit delivery without stopping later output from updating the authoritative VT.
Post-create attachment allocation failure closes the connection as uncertain while preserving the published reserved identity, never as a definitive rejection.
Writer failure disables input but continues output draining and does not fabricate process exit or kill an otherwise live session.
The existing signed exit wire format saturates Windows codes above `maxInt(i32)` rather than treating their high bits as Unix signals; the pane adapter still exposes raw `u32` status.
Native command mapping handles literal argv and PowerShell/cmd command launches, rejects unsupported command shells, and does not translate Unix argv or file-URI cwd values.
Multi-pane mutations, native GUI enablement, and WSL keepalive remain deferred at the first live-owner checkpoint; stable Windows host identity is now implemented above.
Live-owner validation passes 70 tests in each of Debug, ReleaseSafe, and ReleaseFast on real Windows through WSL, with no skips in this main runner.
Coverage includes last-client reconnect with identical in-process state, takeover, collision rejection, invalid launch rollback, layout CAS, credit, binary restore, snapshots larger than the transport queue, and descendant kill/kill-server ACK retention.
Runtime regressions cover published-create OOM uncertainty, read-side query failure without process loss, capacity preflight, native shell exit policy, and high-bit exit status encoding.
The combined ReleaseSafe owner/pane/ConPTY suite passes 111 tests; Linux transport/owner/PTY suites and Windows GUI cross-build also pass.
Production detached startup now has a successful permissive-job qualification: concurrent starters converge on one owner, and closing a known kill-on-close launcher job kills the actual CLI bridge/launcher while the independent owner remains reachable at the same PID.
The test checks independence from that specific launcher job, not the stronger and incorrect assumption that the owner must belong to no job whatsoever.
Restrictive subagent runners still explicitly skip successful startup/survival paths after checking fail-closed denial; production flags and no-fallback policy are unchanged.

Shared attachment and stream state now live in `session_attachment.zig` and `session_stream.zig`, integrated into the Linux owner.
Typed non-owning links enforce takeover and identity-checked detach without another registry.
Portable delivery state owns bounded backlog, credit, snapshot/resync barriers, and exit-delivery admission; runtime code retains VT encoding and process drain/linger policy.
Queue admission checks bounds before allocation, and failed output-frame admission returns before consuming backlog or credit.
This fixes a concrete synchronous send failure that detached the client, cleared its backlog, then consumed the cleared queue.
Targeted regressions cover header/payload OOM, stale detach after takeover, detached terminal queries, overflow/resync, and exit barriers.
Validation passes: Linux ReleaseSafe transport/owner/PTY suites execute 152 tests; owner-loop also passes Debug and ReleaseSmall, and portable stream/attachment tests pass natively and on Windows.
The pre-existing attach-info OOM edge after spawn/takeover remains explicitly deferred.

`session_pane_windows.zig` now provides a separately tested owner-side ConPTY/headless-VT adapter, not a live Windows session implementation.
It accepts prepared native options/launch commands; mapping session protocol requests and wiring shared authority into `session_windows.zig` remain next.
The adapter keeps VT state after process exit, exposes raw Windows exit status separately from drained output EOF, and supports binary and VT-fallback snapshots.
Latest resize is one pending value; input flushes pending replies/resize before application bytes, and accepted reply prefixes are never replayed.
Output continues draining under input backpressure to avoid circular stdout/stdin blocking, while pending replies remain capped at 4 MiB.
Reply exhaustion is explicit, and binary/VT snapshot output streams through a 64 MiB bounded sink.
Process-exit notification is registered before child resume and drained before freeing callback state; writer completion/failure wakes the owner too.
The caller's wake context must outlive pane destruction.
Session-only environment filtering removes inherited/custom GUI pane/workspace/command identifiers case-insensitively and forces `HOLLOW_TRANSPORT=osc`.
Normal GUI spawning keeps its environment behavior.
The Windows executable root facade moves imports under `src/` and initializes shared I/O; the subsequent live-owner slice links headless VT without enabling native GUI persistence.
Adapter validation passes 30 tests in Debug, ReleaseSafe, and ReleaseFast on real Windows through WSL, including process/variable continuity after view destruction, snapshot/fallback parity, resize, DSR replies, raw exit retention, environment isolation, idle exit wake, and descendant teardown.
A deterministic full-input regression also verifies continued output draining, retained reply suffix, buffered-EOF handling, and liveness independent of writer failure.
Existing Windows owner/bridge and ConPTY suites pass 42 tests with one known restrictive-job startup skip; Windows GUI cross-build passes.
Linux pane/snapshot tests execute 93 tests with client tests cached, and Windows-to-WSL pane/snapshot/borrower tests execute 143 with client tests cached.
The adapter target is registered in native Windows CI; CI itself was not run locally.

Phase 3 foundation: `WindowsPty.spawnSession` creates an unnamed, noninheritable kill-on-close Job Object for each owner pane.
The child starts suspended, joins its job before executing, and resumes only after both bounded I/O workers exist.
Unlike ordinary GUI spawning, session children inherit no arbitrary owner handles and explicitly clear redirected standard handles so output stays inside ConPTY rather than leaking into an owner's framed transport.
They can receive input before their first output.
Owner-side destruction kills descendants too; GUI detach must never destroy this owner-side PTY.
Session input overflow rejects admission atomically with `ResourceExhausted`, without marking the pane dead.
The ordinary GUI pre-output input buffer is now bounded to the same 1 MiB input limit.
At this foundation checkpoint native Windows persistence remained unsupported; the native domain milestone above now wires it through the existing GUI path.
This foundation does not change Linux owners or require restarting existing sessions.
Foundation validation: real Windows ConPTY/job tests pass (11 tests each in Debug, ReleaseSafe, and ReleaseFast), Linux ReleaseSafe transport/agent-loop/PTY suites pass (138 tests), Windows borrower/App tests pass (49 tests, one optional fixture skipped), and the ReleaseFast Windows GUI cross-build passes.
The standalone target is registered in Windows CI; final read-only review found no actionable issues.
Windows owner: `src/agent/session_main_windows.zig` builds a separate session-only `hollow-agent.exe` linked to headless VT, without GUI dependencies.
Its `serve|connect|list|kill-server` commands use the SID/version-scoped named-pipe endpoint in `session_pipe_windows.zig`; protocol support is described in the live-owner milestone above.
`session_windows.zig` implements a bounded overlapped loop, discovery, explicit shutdown, and an owner-only detached launcher that never submits or replays a create/spawn request.
The protected user-only DACL and pipe owner are checked by clients, remote clients are rejected, and the first pipe instance remains alive across disconnect/reaccept.
Fixture-only `--namespace <token>` suffixes are bounded and cannot change the SID or escape the pipe name.
The owner has 16 client slots, 1 MiB/client output bounds, 5-second hello/partial/write deadlines, a 2-second shutdown deadline, and a 10-second unused-startup grace.
When no sessions remain, the last client disconnect ends the owner.
Detached launch fails visibly if `CREATE_BREAKAWAY_FROM_JOB` is denied; never retry without that flag.
Some WSL test runners have an enclosing `KILL_ON_JOB_CLOSE` job without breakaway permission; successful detached-launch/survival qualification is conditional on a permissive parent job.
Protocol fixtures launch their own isolated child owners without claiming to qualify production detached startup.
Production-namespace serve failures leave a bounded last-error record at `%LOCALAPPDATA%\hollow\session-owner-error.log`; fixture/CLI errors do not overwrite it.
Bootstrap validation: 25 tests pass with one explicit auto-start skip in each of Debug, ReleaseSafe, and ReleaseFast on Windows through WSL.
The skipped path first verifies restrictive-job startup fails and creates no endpoint; the original bootstrap run did not qualify successful launch or launcher-exit survival.
The lifecycle suite verifies singleton rejection, malformed-frame isolation, last-client exit, idle connections, CLI empty discovery, and kill-server ACK retention even when read only after owner exit.
Source audit caught unread-ACK loss from `DisconnectNamedPipe` during final destruction; final teardown now closes without disconnect, while slot reuse still disconnects.
Linux transport and PTY suites pass (91 tests executed; the unchanged 47-test agent-loop result was cached), Windows ConPTY tests pass (11), and the Windows GUI cross-build passes.
The new bootstrap target is registered alongside the ConPTY target in native Windows CI; CI itself was not run locally.
The raw `session connect` bridge is implemented in `session_bridge_windows.zig` and opens or starts the secured owner without submitting any protocol request itself.
It forwards arbitrary bytes unchanged with two workers, two 64 KiB buffers, and no growing queues.
Pipe writes and blocked stdout writes have 3-second deadlines; healthy idle stdin/owner reads wait without polling.
Either EOF or failure stops the peer direction, cancels both overlapped and synchronous I/O, and joins workers before freeing buffers or closing the owned pipe.
Stdio handles are borrowed, never closed by the bridge; shutdown never emits a remote close or retries bytes after possible transmission.
As with Linux `connect`, stdin EOF detaches immediately and does not promise to drain a pending response afterward.
After relay admission, failures use exit status without a final stderr write, because stderr may share the blocked stdout pipe.
Bridge validation passes in Debug, ReleaseSafe, and ReleaseFast: 31 tests passed and the same restrictive-job auto-start check explicitly skipped in each run.
Six real-process regressions cover protocol-only forwarding, stdin/owner/stdout EOF cancellation, merged blocked stdout/stderr, unread-owner backpressure, and 512 KiB of exact arbitrary-byte transfer without replay or synthetic close frames.
Windows pipe-closing codes 109, 232, and 233 are treated as normal EOF rather than transport failure.
The Windows GUI cross-build also passes; existing user owners and sessions were not restarted.
Shared metadata/admission now lives in `src/agent/session_core.zig` and is used by the Linux owner, without introducing a second session registry or a generic full owner.
It owns session identity, opaque layout, pane-ID cursor, revision, and ended metadata; platform code still owns process/PTY/VT resources, transports, persistence, and attachment transitions.
Reserved/random ID construction and borrowed-array lookup/collision rules are shared; ended IDs reserve identity only until collection removes their entries, not for the owner's lifetime.
Layout CAS preserves current bytes and revision on conflict, missing revision, OOM, oversize, or revision exhaustion.
Initial layout copies before fork, so layout allocation rejection cannot launch a process first.
Pane/revision admission checks happen before fork or explicit-close side effects; commit allocates nothing and cannot fail.
The final nonzero `u32` pane ID remains usable via a wider cursor, then further admission returns `ResourceExhausted` rather than wrapping.
Initial creation remains revision 0, ordinary spawn/close advances once, and membership changes retain geometry for reconciliation.
Whole-session termination and owner teardown bypass revision admission so they still kill children at numeric exhaustion.
This extraction preserves existing session/pane count policy and does not claim the Linux owner is globally bounded; explicit count/aggregate admission limits remain a separate hardening task.
The first live Windows owner now also uses this metadata; the earlier bootstrap checkpoint rejected all session mutations.
Metadata validation passes: 53 agent-loop tests in Debug, ReleaseSafe, and ReleaseSmall; 14 portable core/protocol tests on Linux and real Windows; 144 Linux transport/agent-loop/PTY tests; 105 Linux pane/snapshot/client tests; and 155 Windows-to-WSL pane/snapshot/client/borrower tests with isolated real owners.
The Windows GUI cross-build and formatting/diff checks pass, and the portable core target is now registered in Windows CI.
Source audit found no new core-extraction bugs; an existing `attach()` info-allocation failure can still reject after create has spawned, and remains a separate recovery-hardening edge.
Next concrete slice: manual native-window smoke, otherwise-idle spare-distro WSL survival, and the Phase 4 promise/upgrade audit.

Workspace-picker follow-up: open workspaces now appear above domain categories, sharing reusable collapsible rows with the command palette.
Enter/click toggles headings; search temporarily reveals matches without changing saved collapse choices.
Domain headings use pill colors, and compact rows place work indicators beside current/attention markers in the leading column.
Domain headings are keyboard-focusable and offer a trailing **+** plus `<C-n>` creation in the captured domain.
SSH sessions and configured SSH project sources load only on explicit demand, including after reopening the picker.
Loading has elapsed feedback, a configurable 15-second default deadline, and generation-guarded late replies; empty/error states remain visible.
The SSH project scanner is independent of local scans and bounded to 256-entry pages, four concurrent stats, 4096 entries per load, and 64 domain states.
Row columns reserve pill/badge widths before truncating names/paths.
Guide: [workspace-picker.md](workspace-picker.md); implementation plan: [workspace-picker-plan.md](workspace-picker-plan.md).
Manual GUI verification of category creation, narrow widths, and SSH empty/error states is still required.
Collapse/layout refinement validation passes: 977 Lua tests, bundled LuaJIT syntax checks, and the ReleaseFast Windows GUI cross-build.
Restart the rebuilt GUI for the newly embedded category modules; owner processes and persistent sessions can stay running.

Repaint visual recheck completed: user reports persistence now feels on par after output-read coalescing.
No further repaint-lag work is currently needed; investigate with pipeline measurements only if it returns, before changing the 64 KiB credit window.

Repaint lag investigation (2026-11-06): user reports equal producer/DSR timings but visually 1.5–2x longer to finish with persistence.
Confirmed a GUI-side throughput cap independent of credit-window negotiation: `SessionPty.read` returned one transport frame, while App polls at most 16 reads per pane.
With 4 KiB frames, that limited parsing to 64 KiB per tick despite 128/384 KiB parse chunks and a 2 MiB byte limit.
`SessionPty.read` now combines queued frames into the caller's bounded buffer without waiting, allocating, or increasing time/byte budgets.
A concrete regression queues 262,162 bytes ending in a repaint-completion marker: before, one poll parsed only 65,536 bytes; after, it parses all bytes and reaches the marker.
Additional coverage checks partial frame tails, credit accounting, and draining output before EOF.
User visually rechecked the rebuilt GUI on 2026-11-06 and reports repaint now feels on par with non-persistent panes.
This is subjective confirmation, not a measured GUI speedup; no credit-window change is currently needed.
Owner DSR replies explain why both reported benchmark timings and shell `time` can miss GUI backlog.
No owner/protocol changes are needed for this fix; rebuild/relaunch the GUI while keeping existing owner sessions.
Validation passes: Linux pane/client/snapshot suites in Debug, ReleaseSafe, and ReleaseSmall; pane regressions also pass ReleaseFast.
Windows pane/client/borrower suites with real Windows-to-WSL owner fixtures, Windows GUI cross-build, Zig formatting, and `git diff --check` pass.

Lost-create recovery is now explicit and identity-based.
`Open.prepare` reserves a random 32-hex ID before connecting; it is sent as `Request.create_id` only to owners advertising `create-id`.
Owner collisions reject with `SessionExists`, never implicitly attach or replay spawn.
An uncertain create puts its exact ID in the native warning, log (with domain), and Lua failure callback's optional `session_id`.
List the original domain, then explicitly attach; the session may not exist, and CLI attach can take over another client.
No automatic retry, takeover, or startup-command resend occurs.
Old owners keep the generic warning; recovery notices are not saved across GUI restarts, so use logs/session list then.
Regression tests cover exact-ID ownership, legacy fallback, lost replies, collision rejection, process recovery, callback payload, and notice lifetime after opener teardown.
Validation: Linux pane/snapshot/client suites pass with the real agent (103 tests) in Debug, and also in ReleaseSafe and ReleaseSmall.
Agent protocol/loop/transport/PTY suites, Windows pane/client/borrower suites, Windows-to-WSL real-owner suites, and the Windows GUI cross-build pass.
Shell lifecycle and respawn-notice regression names were corrected to match the headless target's filter; those previously excluded tests now execute and pass.

Respawn rejections now show "Pane respawn failed: <owner reason>" and explain that the existing screen was kept, with no automatic retry.
Notice unit tests and a Windows App regression verify wording, retained exit status, and absence of replay.
Linux pane tests, Windows borrower/App tests, and the Windows GUI cross-build pass.

Latest follow-up: interactive-shell exits (Ctrl+D or `exit`) now schedule
owner-acknowledged pane removal rather than leaving the respawn footer.
Direct applications, scripts, and one-shot commands retain their screen unless
explicitly marked `close_on_exit`.
Owner pane metadata carries the policy across reattachment; old owners default
to retaining panes, so existing owners need restarting after their sessions end.
Detached shell exits are cleaned up when next attached, not while detached.
Regression coverage includes a real `/bin/sh -i` PTY receiving Ctrl+D,
reattachment metadata, shell/app close admission, and take-over safety.
Linux pane/client, agent transport/PTY/loop, Windows pane/client tests and
`./launch.sh --build-only` pass; GUI behavior still needs manual verification.

Gotchas that cost time before:

- Native Linux `zig build test` cannot link GUI deps (X11/GL/ALSA missing); use `-Dtarget=x86_64-windows-gnu` or the headless steps in Validation.
- App tests with a Lua runtime must use `Runtime.initForTests`; `Runtime.init` starts platform discovery and crashed intermittently ("switch on corrupt value"). Any `std.log.err` in a test fails it.
- Headless pane tests filter names by `session pane`; borrower/App tests filter by `session borrowers`.
  Regression names must include the matching prefix or the target silently excludes them.
- The 7 Windows `session_transport_test` FileNotFound failures are expected; judge by "Build Summary".
- Lua tests emit built-in events with `hollow._emit_builtin_event(name, payload)`; `hollow.events.emit` rejects built-ins. `harness.boot()` clears `package.loaded`, so module state resets per boot.
- When stubbing `hollow.ui.select.open` in switcher tests, call the captured `opts.on_mount()` or item refreshes never fire.
- `stylua --check src/lua` reports pre-existing diffs; format only the files you changed, and never reformat `src/lua/hollow/ui/workspace/source.lua` wholesale.
- `npx markdownlint` is unavailable locally; keep docs one sentence per line by hand.
- `docs/reference/lua/workspace.md` says the default close key is `<C-w>` but code uses `<C-x>`; pre-existing, not fixed.

## Implementation notes (chronological)

- Phase 1 complete: Linux owner/connect; local, WSL and manual SSH checks pass.
- GUI workspace/controller wiring publishes an already-attached session.
  App owns controller/connection, pumps bounded frames around pane parsing,
  retries backpressure, and removes panes only after close ACK. App borrower
  invalidation and aggregate snapshot budgeting are wired.
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
  Startup reattach is now Lua policy (slice 3, below).
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
  initially suspected to be the 64 KiB window / WSL RTT; the later GUI adapter
  read-boundary cap above was fixed, and the user now reports visual parity.
  Window negotiation has not started.
- `7beae1e`: stale layout reconciliation, quit flush and receive-ahead.
- `496f032` discovery (slice 2): `session/query.zig` (single-use
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
  Not yet done: manual GUI smoke of the CLI against a running instance.
- Host identity: owner `loadHost` persists `<state dir>/host-id` and sends
  optional `Welcome.host` (old clients ignore it, old owners send none).
  `Client.host()`/`Connection.host(buf)`, `Controller.host`,
  `workspace.session_host`, list/kill `host`, host-aware `open`. Real-owner
  App test checks the host survives reattach and matches the list result.
  Remembering attached sessions client-side is slice 3 (Lua policy), below.
- Dead/missing-session UX: owner `Op.respawn` re-forks an exited pane from its
  saved spawn at the current size, keeping VT and screen (`PaneAlive` if live).
  Owners advertise `Welcome.features = ["respawn"]`; clients never send it
  otherwise (unknown ops close the connection) and return `Unsupported`.
  `Controller.requestRespawn`/`finishRespawn` (one pending per pane, never
  replayed); an ok reply clears exit status in `route` before new output.
  App revives the pane and emits `term:pane_respawned`; Lua
  `hollow.term.respawn_pane(pane_id?)` and action `respawn_pane`.
  `src/session/dead_pane.zig` drives a native footer (exit code, Enter respawn
  when advertised, Ctrl+D close) intercepted first in `App.sendKey`.
  A `SessionNotFound` rejection shows "Session not found on host" with
  `hollow-cli session list` guidance; new_workspace/attach `on_complete`
  failures carry `status`, `error`, `outcome`, `remote?`.
  Respawn rejection uses a dedicated "Pane respawn failed: …" notice and preserves the existing screen without retry.
- Remembered sessions (slice 3): `src/lua/hollow/session_restore.lua` keeps
  `{version=1, sessions=[{domain,id,host?}]}` in `<data dir>/sessions.json`
  (max 64, oldest dropped, corrupt file reads empty). Recorded on
  `workspace:new` for domains with `persist` and `restore ~= false`; forgotten
  on `workspace:closed` with `session_ended`, on a successful wrapped
  `kill_session`, and when a reachable list lacks the id. `Mux.last_removed_session`
  computes `ended = !detached and connection not ended` at removal.
  `Runtime.sessionStartup` calls `hollow._session_startup`; App skips its own
  startup create when Lua returns true for the default domain (no startup
  command). Lua lists local/WSL domains, attaches unattached entries, queues a
  confirm for entries attached elsewhere, and creates at most one fresh default
  session only after a successful list with nothing restored, no prompt
  pending, and no uncertain attach. SSH: deferred notice with a Restore action.
  Tests: `src/lua/tests/test_session_restore.lua`, lua_bridge
  "workspace close reports session identity", and the session_controller
  ack/takeover tests assert `session_ended`.
  App Lua runtimes in tests must use `Runtime.initForTests`: `init` starts
  platform discovery and crashed intermittently in an App test.
- Switcher sessions (slice 4): `src/lua/hollow/ui/workspace/sessions.lua`
  feeds `source = "session"` / `"session_load"` rows, merged by `source.lua`
  after open workspaces. `open_switcher` calls `refresh_on_open` (local/WSL
  persist domains plus SSH domains already loaded); per-domain status is
  idle/loading/ready/failed and changes emit `workspace:items_changed`.
  Switcher actions dispatch on `item.source`: Enter attaches (take-over
  confirm), load rows list without closing; `<C-x>` kill with confirm; `<C-n>`
  new session in the row's domain; `<C-l>` refresh (only when a persist
  domain exists, so existing hint snapshots are unchanged).
  Tests: `src/lua/tests/test_ui_workspace_sessions.lua`.

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
- SSH trust remains user-managed; Windows ownership and WSL keepalives are implemented, with manual qualification still open.

## Validation

- Zig 0.17.0. Always use explicit build file/options if configure-cache selection
  appears stale (`-Dagent-only=false` for GUI graph).
- Lua: `./scripts/test-lua.sh` (single file: `./scripts/test-lua.sh src/lua/tests/<file>.lua`);
  bundled LuaJIT syntax: `zig build test-luajit -Dagent-only=false`.
- `zig build --build-file build-agent.zig test-session-transport test-agent-loop test-agent-pty`
- `HOLLOW_TEST_AGENT=$PWD/zig-out/agents/linux-x86_64/hollow-agent zig build --build-file build.zig test-session-pane test-session-snapshot test-session-client test-background test-search test-command test-lua test-luajit -Dagent-only=false --summary all`
- Windows GUI cross-build: `./launch.sh --build-only`.
- Windows owner-side ConPTY foundation (no GUI dependencies): `zig build --build-file build-agent.zig test-session-windows-pty -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe --summary all`.
  Run on Windows or through WSL executable interop; this target creates isolated test processes, never connects to existing owners.
- Windows bootstrap: `zig build --build-file build-agent.zig session-owner-windows test-session-windows-owner -Dtarget=x86_64-windows-gnu -Doptimize=Debug --summary all`.
  Its protocol fixtures use unique private namespaces; successful detached startup is separately qualified only when the enclosing Windows job permits breakaway.
  Run the same target in ReleaseSafe and ReleaseFast, and report skipped startup checks rather than treating them as passes.
- Portable metadata/admission: `zig test src/agent/session_core.zig`; Windows: add `-target x86_64-windows-gnu -lc -OReleaseSafe`.
- Repeat pane/snapshot/client suites with `-Doptimize=ReleaseSafe|ReleaseSmall`.
- Windows tests through WSL interop:
  `zig build --build-file build.zig test test-session-pane test-session-snapshot test-session-client test-session-borrowers -Dagent-only=false -Dtarget=x86_64-windows-gnu -Dsession-test-wsl="$WSL_DISTRO_NAME" -Dsession-test-agent=/tmp/opencode/hollow-session-agent-next --summary all`
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
  Zig formatting and `git diff --check` passed.
  Markdown lint could not run: local `npx --no-install markdownlint` has no executable.
- Slice 3 validation: Lua, Linux headless, Windows suites, `./launch.sh --build-only`.
- Slice 4 validation (Lua-only change): `zig build test-luajit test-lua -Dagent-only=false`
  passes with 965 Lua tests. Zig suites were not rerun because no Zig changed.

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
