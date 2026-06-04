# `hollow.util`

Path, color, table, and misc utilities.
A grab-bag; reach for it when you need a small helper and want to
avoid re-implementing it.

## Path helpers

```lua
hollow.util.path_separator(path?)         -- "/" or "\\" depending on path
hollow.util.normalize_path(path, sep?)    -- convert to platform-native form
hollow.util.join_path(...)                -- concatenate path parts
hollow.util.basepath(path)                -- dirname; nil for empty
hollow.util.basename(path)                -- basename; nil for empty
```

`path_separator(path?)` picks `\` when the path contains a backslash,
`/` otherwise. `normalize_path` rewrites `/` to `\` on Windows and
vice versa.

## Color helpers

```lua
hollow.util.is_hex_color(value)                        -- boolean
hollow.util.normalize_hex_color(value, fallback?)      -- "#rrggbb" or fallback
hollow.util.adjust_hex_color(value, amount, fallback?) -- shift lightness
hollow.util.brighten_hex_color(value, amount, fallback?)
hollow.util.darken_hex_color(value, amount, fallback?)
```

`amount` can be a fraction (0..1) or a percentage string like `"+10%"`.
`fallback` is returned when `value` is not a hex color.

## Table helpers

```lua
hollow.util.clone_value(value, seen?)     -- deep clone with cycle protection
hollow.util.merge_tables(dst, src)        -- merge src into dst, in place
hollow.util.has_any_key(t, keys)          -- boolean
```

`clone_value` returns a deep copy of the input. `merge_tables`
overwrites scalar values in `dst` with `src`'s values, and recurses
into nested tables.

## Misc

```lua
hollow.util.unsupported(name)             -- raise a controlled error
hollow.util.host_now_ms(host_api?)        -- integer; same as host_api.now_ms()
```

`unsupported(name)` is the conventional way to mark features in the
API surface that exist for shape but are not yet implemented in this
build (e.g. `hollow.process.spawn`).

## Examples

```lua
local p = hollow.util.join_path("/tmp", "foo", "bar.txt")
-- "/tmp/foo/bar.txt"

local copy = hollow.util.clone_value({ a = { b = 1 } })
copy.a.b = 2
-- original.a.b is still 1

hollow.util.merge_tables(config.fonts, { size = 16 })

if hollow.util.is_hex_color("#ff8800") then
  local lighter = hollow.util.brighten_hex_color("#ff8800", 0.2)
end
```

## See also

- [Configuration](../../configuration.md) — the `merge_tables` model
- [Themes](../../themes.md) — color helpers
