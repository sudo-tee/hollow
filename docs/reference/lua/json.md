# `hollow.json`

Encode and decode JSON.
Used for workspace bootstrap specs and any other small data files you
want to round-trip.

## Functions

```lua
hollow.json.encode(value)        -- value -> string
hollow.json.decode(text)         -- string -> value
```

Both directions accept and return plain Lua values:
strings, numbers, booleans, `nil`, arrays, and tables with string
keys. Object-like tables must have string keys; arrays must be
1-indexed and dense.

## Examples

```lua
local s = hollow.json.encode({ name = "repo", tabs = { "editor", "backend" } })
-- s == '{"name":"repo","tabs":["editor","backend"]}'

local t = hollow.json.decode(s)
print(t.name)        -- "repo"
print(t.tabs[1])     -- "editor"
```

Inspect a snapshot for debugging:

```lua
print(hollow.json.encode(hollow.config.snapshot(), { indent = true }))
```

`encode` accepts an optional `opts` table; `indent` (number or
boolean) pretty-prints.

## Use cases

- Workspace bootstrap specs ([`hollow.workspace`](workspace-api.md))
- Round-tripping small config blobs
- Logging structured data to `hollow.log`

For large payloads use chunked HTP frames; see
[HTP protocol](../../htp-protocol.md#chunked-framing).

## See also

- [`hollow.workspace`](workspace-api.md)
- [Configuration](../../configuration.md)
