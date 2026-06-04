# HTP protocol

HTP (Hollow Terminal Protocol) is a small OSC-based protocol shells use
to talk to the running Hollow host.
This page is the wire-level reference.
For a higher-level overview see
[Shell integration](shell-integration.md).
For per-shell usage see
[Shell integration recipes](shell-integration-recipes.md).

## Transport

- HTP runs over the tty (via OSC 1337) or via the host's command socket
  (the path used by [`hollow cli …`](reference/cli/native.md)).
- OSC frame shape: `ESC ] 1337 ; Hollow ; <json> ESC \`.
- Reply frames are written to the same tty.
- Shells can force OSC with `HOLLOW_TRANSPORT=osc`.

## Frame format

Frames are JSON objects wrapped in the OSC envelope.
A frame has the following shape:

```json
{
  "kind":   "query" | "event" | "result" | "error" | "chunk" | "ready",
  "id":     "string",
  "name":   "channel-name",
  "params": { ... } | null,
  "payload": { ... } | null,
  "ok":     true | false,
  "error":  { "code": "string", "message": "string" } | null,
  "index":  0,
  "total":  1
}
```

- `kind` is the discriminator
- `id` correlates the request with the reply; both sides use the same
  value
- `query` and `event` travel shell → host
- `result` and `error` travel host → shell
- `chunk` is a piece of a larger reply (used when the reply does not
  fit in a single frame)
- `ready` is sent once on connect

## Chunked framing

Large replies (over roughly 1 KB) are split into chunks.
Each `chunk` carries an `index` and `total`; the runtime reassembles
them by id, then emits a single `result` to the consumer.

```json
{ "kind": "chunk", "id": "abc", "index": 0, "total": 3, "payload": "..." }
{ "kind": "chunk", "id": "abc", "index": 1, "total": 3, "payload": "..." }
{ "kind": "chunk", "id": "abc", "index": 2, "total": 3, "payload": "..." }
```

## Channels

### Built-in query channels

Shell → host, returns a single `result` payload.

| Channel | Params | Returns |
| --- | --- | --- |
| `pane` | `{ id }` | `HollowPane` snapshot |
| `current_pane` | `{}` | `HollowPane` snapshot |
| `tab` | `{ id }` | `HollowTab` snapshot |
| `current_tab` | `{}` | `HollowTab` snapshot |
| `tabs` | `{}` | `HollowTab[]` |
| `panes` | `{ tag? }` | `HollowPane[]` |
| `workspace` | `{ id? }` or `{ index? }` | `HollowWorkspace` snapshot |
| `current_workspace` | `{}` | `HollowWorkspace` snapshot |
| `workspaces` | `{}` | `HollowWorkspace[]` |
| `current_domain` | `{}` | `HollowDomain` snapshot |
| `echo` | `{}` | the params, unchanged (useful for debugging) |

### Built-in emit channels

Shell → host, fire-and-forget or checked. The host replies with a
single `result` or `error` when checked.

| Channel | Payload |
| --- | --- |
| `close_pane` | `{ id? }` or `{ tag? }` |
| `focus_pane` | `{ id? }` or `{ direction }` |
| `resize_pane` | `{ id? }`, `{ axis }`, `{ delta }` |
| `send_text` | `{ id? }`, `{ text }` |
| `split_pane` | `HollowSplitPaneOpts` |
| `new_tab` | `HollowNewTabOpts` |
| `close_tab` | `{ id? }` or `{ index? }` |
| `focus_tab` | `{ id? }` or `{ index? }` |
| `next_tab` | `{}` |
| `prev_tab` | `{}` |
| `set_tab_title` | `{ id? }`, `{ title }` |
| `new_workspace` | `HollowNewWorkspaceOpts` |
| `close_workspace` | `{ id? }` or `{ index? }` |
| `next_workspace` | `{}` |
| `prev_workspace` | `{}` |
| `switch_workspace` | `{ index? }` or `{ id? }` |
| `set_workspace_name` | `{ name }` |
| `toggle_pane_maximized` | `{ id? }`, `{ show_background? }` |
| `set_pane_floating` | `{ id? }`, `{ floating }` |
| `set_floating_pane_bounds` | `{ id? }`, `{ x }`, `{ y }`, `{ width }`, `{ height }` |
| `move_pane` | `{ id? }`, `{ direction }`, `{ amount? }` |
| `reload_config` | `{}` |
| `set_theme` | `{ name }` |
| `scroll` | `{ where }` |

### Custom channels

Register your own channels from Lua:

```lua
hollow.htp.on_query("build_status", function(ctx)
  return { running = true, target = "release" }
end)

hollow.htp.on_emit("notify", function(ctx)
  hollow.ui.notify.show(ctx.payload.text, { ttl = ctx.payload.ttl or 1500 })
end)
```

Handlers are called on the host thread. Query handlers must return a
JSON-serializable value; emit handlers return nothing.

## WSL environment propagation

Hollow injects `HOLLOW_PANE_ID` and `HOLLOW_TRANSPORT` into every guest.
For WSL domains, `WSLENV` is configured so these variables cross the
Windows/WSL boundary with `/u` (UTF-8 propagation).

Inside a WSL distro the shell sees, e.g.:

```bash
$ echo "$HOLLOW_PANE_ID $HOLLOW_TRANSPORT"
7 osc
```

## See also

- [Shell integration](shell-integration.md) — higher-level overview
- [Shell integration recipes](shell-integration-recipes.md) — bash/zsh/fish/PowerShell
- [`hollow.htp`](reference/lua/htp.md) — Lua handler API
- [Native CLI](reference/cli/native.md) — the recommended host-side path
