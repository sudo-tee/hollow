# Responsiveness work — September 2026

This pass addresses blocking work, memory growth, and pane scheduling. It is not
a claim that all terminal workloads or platform interactions are now optimized.

## Changes

- Resolved the renderer's AltGr merge conflicts, keeping right-Alt recovery on
  Windows focus/restore and using the same state for character handling.
- Added bounded FIFO caches for shaped text and prepared glyph runs. Each cache
  has an 8 MiB accounting budget for owned glyphs and conservative key-storage
  overhead. FIFO eviction avoids repeated hash-table scans; eviction invalidates
  borrowed recent-cache pointers. GPU atlas limits remain separate.
- Added a POSIX writer worker with a 4 MiB input queue, partial writes, and
  nonblocking descriptor handling. Queue admission is all-or-nothing. Closing
  wakes workers and joins them before closing the shared descriptor. Windows
  already had a queued writer.
- Separated visible and hidden pane parsing budgets. Visible unfocused panes may
  consume 256 KiB per tick; hidden panes may consume 256 KiB when interaction is
  idle. During recent input, resize, or slow frames, hidden output retains a
  conservative alternate-frame budget. Each class shares a bounded time budget;
  active-pane parsing cannot consume it before the class gets a turn. Idle panes
  donate their unused allowance.
- Added up to eight concurrent IPC connections with total socket deadlines on
  Linux and Windows, while keeping mutations serialized on the frame thread.
  Shutdown rejects queued commands before joining connection workers. The native
  client applies a connection timeout, too. Non-loopback binds are rejected.
- Implemented asynchronous process jobs and Lua `process.spawn` / `process.exec`:
  cancellation, completion callbacks, coroutine waits, promises, working directory,
  environment overrides, deadlines, bounded output, and cleanup on runtime teardown.
  See [the process API](reference/lua/process.md) for supported behavior and limits.
- Enabled previously unimported native test modules and updated stale Zig 0.16
  assertions exposed by that coverage. New regression cases cover cache pressure,
  a blocked PTY writer, an idle IPC client, incomplete frames, process output and
  cancellation, native Lua argument ownership, and shutdown waiting on dispatch.

## Renderer comparison

Compared an isolated snapshot of commit `c57efeb` with this working tree using the
same locally patched dependencies and embedded fonts. ReleaseFast, 120 × 40 grid,
1,000 frames, 393,216-byte chunks, 3 warmups, 10 iterations per invocation. Each
scenario was run three times per variant, alternating order. Values below are the
median of the three reported medians, in milliseconds.

| Scenario | CPU render before | CPU render after | Pipeline before | Pipeline after |
| --- | ---: | ---: | ---: | ---: |
| Repaint | 3.063 | 3.044 | 53.805 | 51.632 |
| Scroll | 2.190 | 2.122 | 151.613 | 151.339 |
| Styled | 3.433 | 3.438 | 116.846 | 139.046 |

CPU render time stayed close to baseline. Pipeline measurements were noisy in
parsing: styled parse medians ranged from 110–143 ms across individual invocations,
while rendering stayed around 3.4 ms. The styled pipeline aggregate is slower in
this sample, so these measurements do **not** establish an overall throughput win.
The headless benchmark excludes PTYs, Lua, window scheduling, and GPU execution;
it does not quantify the input-latency improvements from removing blocking paths.

Reproduce an individual measurement with:

```sh
zig build run-renderer-bench -Doptimize=ReleaseFast -- \
  --scenario repaint --frames 1000 --iterations 10 --warmup 3 --json
```

## Validation and remaining work

Linux and Windows ReleaseFast executables were cross/native built successfully.
The Lua suite passes 213 tests. The native suite passes 250 tests, including
headless rendering, real local IPC/process tests, and command shutdown.
Formatting and whitespace checks pass.

Interactive Windows/WSL behavior and real GPU latency still need validation on
those platforms. IPC remains unauthenticated between local users; loopback-only
binding reduces network exposure but does not replace per-user authentication.
Process output is collected at completion; streaming output, stdin writers, and
process-tree termination are not implemented. Synchronous process helpers remain
for compatibility, so existing plugins must opt into the asynchronous API.

Further work should prioritize native Windows runtime CI, input-latency and
multi-pane PTY benchmarks, authenticated IPC, and measured cache/scheduler telemetry.
