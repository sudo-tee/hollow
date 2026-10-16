# `hollow.route`

Route clicked terminal hyperlinks and quick-select opens through synchronous
Lua handlers. Handlers are unrestricted: they can send a target to an existing
Neovim pane, call another Hollow API, perform IPC, rewrite the target, or leave
opening to Hollow's configured external opener.

## Registering handlers

```lua
local remove_link_route = hollow.route.link(function(req)
  if req.url:match("^jira://") then
    -- Dispatch through your own plugin, IPC bridge, or editor integration.
    my_jira_opener(req.url, req.pane)
    return { handled = true }
  end
end)

-- Remove handler when no longer needed.
remove_link_route()
```

Multiple handlers run in registration order. Return `nil` (or `false`) to let
next handler inspect request. First other result decides route.
Existing configured quick-select actions take precedence; routing runs only
when selected quick-select action resolves to `open`. Copy actions bypass it.

## Request

| Field | Meaning |
| --- | --- |
| `url` | Effective default target; may be URL or quick-select path |
| `text` | Original matched text; OSC 8 links use their embedded URI here |
| `pane` | Origin pane snapshot, or `nil` if pane no longer exists |
| `pane_id` | Origin pane ID |
| `mods` | Modifier chord such as `"<S>"`; empty string when unmodified |
| `source` | `"click"` or `"quick_select"` |
| `kind` | Quick-select kind: `url`, `ip`, `quote`, `filename`, or `custom`; clicked links use `url` |
| `pattern_index` | Custom quick-select pattern index, otherwise `nil` |

For quick-select filenames, `url` is the open target even though it may be a
path such as `src/main.zig:42`. Use `kind`, `source`, and `text` to distinguish
that from a web URL.

## Handler result

- `nil` or `false`: try next handler; if none handles request, use normal opener.
- `{ handled = true }`: handler owns action; suppress normal opener. Handler may
  perform any synchronous Lua action before returning.
- `{ url = "https://..." }`: rewrite target, then use normal opener.

Handlers run synchronously on link activation, not during hover rendering. If
a handler errors or returns an invalid result, Hollow logs failure and cancels
that open rather than unexpectedly passing it to another application.

To recognize custom schemes in plain terminal text, add them to
`hyperlinks.prefixes` in configuration. For example, include `jira://` in the
prefix list. OSC 8 hyperlinks already carry their URI explicitly.
