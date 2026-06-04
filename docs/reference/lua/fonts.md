# `hollow.fonts`

Discover installed fonts and pick the first available family from a
preference list.

For the LuaLS schema see
[`types/hollow.lua`](../../../types/hollow.lua) (`HollowFontsNamespace`,
`HollowFontInfo`).

## Functions

```lua
hollow.fonts.list()                              -- all families
hollow.fonts.find(query)                         -- filtered by substring
hollow.fonts.has(family, style?)                 -- boolean
hollow.fonts.pick(candidates, style?)            -- first available or nil
```

## Examples

List everything:

```lua
for _, f in ipairs(hollow.fonts.list()) do
  print(f.family, table.concat(f.styles, ", "))
end
```

Filter by name:

```lua
for _, f in ipairs(hollow.fonts.find("mono")) do
  print(f.family)
end
```

Check a specific family:

```lua
if hollow.fonts.has("Cascadia Mono", "Bold") then
  -- ...
end
```

Pick the first available from a list:

```lua
local preferred = hollow.fonts.pick({
  "Cascadia Mono",
  "Consolas",
  "DejaVu Sans Mono",
})

if preferred then
  hollow.config.set({ fonts = { family = preferred } })
end
```

`pick` returns the first family that exists on the host, or `nil` if
none match.

## CLI equivalent

`hollow.exe` exposes the same inventory:

```bash
hollow.exe --list-fonts
hollow.exe --match-font mono
hollow.exe --list-fonts --json
```

## See also

- [Configuration](../../configuration.md#fonts) — font config schema
- [Troubleshooting](../../troubleshooting.md#missing-glyphs)
