# `hollow.fs`

Filesystem helpers exposed to Lua.
Used by the plugin loader and by the workspace switcher's local
resolver.

## Functions

```lua
hollow.fs.data_dir()                  -- user data dir
hollow.fs.glob(pattern)               -- expand a glob
hollow.fs.is_dir(path)                -- boolean
hollow.fs.mkdir_p(path)               -- mkdir -p
hollow.fs.read_file(path)             -- string
hollow.fs.write_file(path, contents)  -- boolean
hollow.fs.path_exists(path)           -- boolean
```

`glob` supports at least `*` as a wildcard.
`read_file` and `write_file` are simple bulk reads/writes; they are
not designed for huge files.

## `data_dir()`

| Platform | Path |
| --- | --- |
| Windows | `%APPDATA%\hollow` |
| Linux / macOS / WSL | `$XDG_DATA_HOME/hollow` or `~/.local/share/hollow` |

Used as the root for cloned plugins, layouts, and runtime state.

## Examples

```lua
local root = hollow.fs.data_dir()         -- e.g. "C:\\Users\\me\\AppData\\Roaming\\hollow"

hollow.fs.mkdir_p(root .. "/plugins")

for _, path in ipairs(hollow.fs.glob(root .. "/plugins/*")) do
  print(path)
end

if hollow.fs.is_dir("/etc") then
  print("/etc exists")
end

if hollow.fs.path_exists("/etc/hosts") then
  print((hollow.fs.read_file("/etc/hosts")):sub(1, 80))
end

hollow.fs.write_file("/tmp/hello.txt", "hi from lua\n")
```

## See also

- [`hollow.util`](util.md) — path and color utilities
- [Plugins](../../plugins.md) — uses `data_dir` and `glob`
