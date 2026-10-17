# Tern Analysis: Ideas Worth Bringing to Hollow

Source: Tern docs (https://docs.stencil.so/tern/) and the Tern binary, compared
against Hollow `main`. HTML/CSS styling, browser, notebook, board, database and
the Carly assistant are deliberately out of scope: Hollow stays terminal-rooted.

## Overlap

Both are terminal + mux with Lua scripting, an in-band protocol (Tern's TSP vs
Hollow's HTP), workspaces and a control socket. Tern's lead is in four areas:

1. Command lifecycle as first-class data (status, duration, output ranges).
2. Plugin isolation (VM per plugin, time budgets, error attribution).
3. Hook points into built-in behavior (overrides, link routing, spawn filter).
4. Lua-drawn panes and views (blocks, lenses).

## Tier 1 — High value, fits current architecture

### 1. Command lifecycle events (top pick)

Hollow already parses OSC 133 and the shell scripts emit HTP `command_ended`,
but `src/lua/hollow/htp.lua:491` only clears the foreground process; exit
status and timing are dropped.

Add events:

| Event                   | Payload                         |
| ----------------------- | ------------------------------- |
| `term:command_started`  | `{pane, line, cwd}`             |
| `term:command_finished` | `{pane, line, status, took_ms}` |
| `term:pane_exited`      | `{pane, status}`                |
| `term:pane_created`     | `{pane}`                        |
| `term:pane_closed`      | `{pane}`                        |

Extend pane snapshots with `busy`, `at_prompt`, `running = {line, ms}` and
`last = {line, status, took_ms}`.

Unlocks: "notify when a long command fails", status segments, attention inbox.
Most items below build on this.

### 2. Action overrides

```lua
hollow.action.override("new_tab", function(ctx)
  -- return true to skip the built-in
end)
```

First truthy return stops the chain and skips the built-in. Adopt Tern's
recursion guard: while a plugin handler runs, built-ins invoked from it run
raw (no overrides), so an override can call its own action without looping.
Cheap given the registry in `src/lua/hollow/actions.lua`.

### 3. Link routing

```lua
hollow.route.link(function(req) -- {url, pane, mods}
  return { handled = true } | { url = "..." } | { split = "right", command = "..." } | nil
end)
```

Hook into `src/app/hyperlinks.zig` and the quick-select `.open` path in
`src/app/quick_select.zig`. Enables custom schemes (`jira://X-1`) and opening
`file:line` in `$EDITOR` in a split.

### 4. Spawn filter

Synchronous hook before every PTY spawn:

```lua
hollow.events.on("pane:spawn", function(spec) -- {program, args, cwd, env, domain}
  spec.env.EDITOR = "nvim"
  return spec
end)
```

Strict time cap (Tern uses 50 ms; late answers are ignored). Fits Hollow's
domains. Use cases: per-project env (direnv-like), forced env vars,
nix-shell wrapping.

### 5. Run and settle

```lua
hollow.term.run(pane, "cargo test\r")
hollow.term.settle(pane, 30000):next(function(output) ... end)
```

`settle` resolves on OSC 133 D or timeout with the last output lines. Built on
`hollow.async`. Major win for scripting, workspace bootstrap and agent driving.

### 6. Shared stdlib gaps

- `hollow.kv.get/set`: per-plugin JSON store under the data dir.
- `hollow.fs.read/write/list/exists/remove`: host functions exist
  (`read_file`, `write_file`, `path_exists`) but are not wrapped.
- `hollow.fetch`: async HTTP.
- `hollow.timer(ms, fn)` returning a handle with `:cancel()`; `hollow.sleep(ms)`
  returning a promise.

### 7. Contextual actions

Add to `hollow.action.register`:

- `available(ctx) -> boolean` (tight budget) — palette hides unavailable rows.
- `keys = { "<C-S-h>" }` — default chords registered with the action.

## Tier 2 — Bigger, high payoff

### 8. Command records, then lenses

Tern's lens: a glob-matched command line has its output fed line-by-line to
Lua, which renders a native view in place of the output. Replacing output is
awkward in a cell terminal, so go one layer lower first:

**Step 1 — command records.** Store per-pane command output ranges
(OSC 133 C → D). Enables:

- fold/unfold command output
- copy last command output
- jump between commands
- rerun a command
- `hollow.term.get_command_output(pane, n)`

**Step 2 — terminal-flavored lenses.** Glob claims on the command line plus a
Lua reducer (`open`/`line`/`finish`) whose result renders as an overlay or
sidebar summary (e.g. failing tests from `cargo test`) without touching the
grid.

### 9. Lua panes

A pane whose program is Lua:

| Handler                            | Called                    |
| ---------------------------------- | ------------------------- |
| `init(ctx, args, saved) -> state`  | Start and restore         |
| `view(state, ctx) -> node`         | After every handler       |
| `key(state, key, ctx) -> boolean?` | Key press while focused   |
| `event(state, ev, ctx)`            | Clicks on view nodes      |
| `resize(state, cols, rows, ctx)`   | Size change               |
| `save(state) -> any`               | After handlers; persisted |

`view` returns existing `hollow.ui` widgets rendered into the pane rect instead
of an overlay. State persists through workspace JSON
(`{lua_pane = "plugin.kind", args = {...}}`). Gives native dashboards, git
status, log viewers and pickers that live in the layout.

### 10. Plugin manifest and lifecycle

Today: synchronous `git clone` at startup, no versions, no status.

- Manifest (`plugin.toml`): id, name, version, entry.
- CLI: `hollow plugin install|link|list|reload|remove`.
- Per-plugin status (Ready / Failed / Disabled) surfaced in the UI.
- Async clone, lockfile with pinned revisions, per-plugin reload without
  restarting Hollow.

### 11. Isolation and budgets

Today every plugin shares one LuaJIT VM with full `io`, `os` and `ffi`.

- Per-plugin environment via `setfenv` so globals don't collide.
- Wrap every callback; report failures as "Plugin X: <hook> failed" toasts.
- Time budgets via `debug.sethook`; a hook that trips is disabled until reload.
  Caveat: JIT-compiled loops skip hooks unless JIT is off for that code.
- Tern's scheduling rule: effects queued during a handler apply after it
  returns, and events a handler causes are delivered in the next batch. No
  re-entrant handlers.

### 12. Script runner and headless mode

Script files driven against `hollow serve` (headless) or a live window:

```text
size 1280 800
ready
split right
run "git status"
expect "On branch"
shot split-status
```

`src/native_cli.zig` already has `get screen` and `wait`; adding `expect`,
`run --wait` and a file runner is small. Gives regression tests and
deterministic documentation screenshots.

Also: add a token to the IPC socket (`src/ipc.zig`). Today any local process
can use `run` and `send-keys`.

### 13. Layout API

- `hollow.term.layout(tab)` returning the split tree.
- In-memory `snapshot()` / `restore()`.
- `equalize`, `swap`, float/dock, tab color and order.
- `resolve("@focused" | title | program)` pane finder.
- Inline tree spec for building a tab (today only via JSON files).

### 14. Attention inbox

One list combining bells, non-zero or long commands, exited panes and
`program_status` blocked/done, with go-to-pane. Hollow already has
`attention_navigator` and OSC 7501; with item 1 this is mostly wiring. Add OS
notifications when the window is unfocused.

### 15. Programs requesting native UI over HTP

Terminal-rooted take on Tern's Surface Protocol: let shell programs request
Hollow's `select`, `confirm`, `input` and `notify` over HTP and receive the
answer (e.g. `hollow-cli pick < files` prints the choice). In-band, so it
works over ssh. Add a handshake/feature query so programs fall back cleanly.

## Tier 3 — Strategic or nice-to-have

- **Session daemon / remote hosts.** Tern's headline: panes live in a daemon,
  windows attach/detach, plugins split into host and window halves. Large
  architectural decision; scope separately.
- **Native foreground-process detection** (`tcgetpgrp` + `/proc`) instead of
  relying on HTP; then process `list` / `children` / `signal` APIs.
- **Small actions:** `open_scrollback` in `$EDITOR`, `restart` shell, `clear`
  (screen + scrollback), `goto_directory`, `insert_path` (fuzzy path picker
  that types the path), `equalize`, `move_tab_left/right`, previous-tab toggle.
- **Cached chrome formatters:** pure `tab_title` / `window_title` / `status`
  functions cached per input, with `refresh()`. Only worthwhile if bars re-run
  Lua every frame today (not checked).
- **`hollow.config.describe(key)`** schema (type, enum, default, doc) for a
  settings palette and typed validation.

## Bugs found during analysis

1. `hollow.on_file_drop` always errors: `l_on_file_drop`
   (`src/lua_bridge.zig:6695`) is defined but never registered, so
   `src/lua/core.lua:169` calls nil.
2. `hollow.term.send_key` without a pane id errors:
   `src/lua/hollow/term.lua:620` calls `host_api.get_current_pane_id()`, which
   does not exist (should be `current_pane_id`).

## Suggested order

1. Item 1 (command events) — makes 5, 8, 14 and status segments trivial.
2. Items 2, 3, 4 — cheap hooks, large flexibility.
3. Items 11, 10 — plugin robustness before the ecosystem grows.
4. Item 12 — tests and documentation screenshots.
5. Items 8, 9, 13, 14, 15 — bigger features on top.
6. Tier 3 as capacity allows; daemon as its own project.
