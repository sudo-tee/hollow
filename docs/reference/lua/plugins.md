# `hollow.plugins`

Declare, autoload, and update plugins.

For the conceptual model see [Plugins](../../plugins.md).
For a working example see
[`examples/plugins/hollow-spirit`](../../../examples/plugins/hollow-spirit).

## Functions

```lua
hollow.plugins.setup(config?)   -- install + autoload + call setup()
hollow.plugins.sync()           -- git pull --ff-only for all git plugins
```

## `setup`

```lua
hollow.plugins.setup({
  plugins = {
    "user/repo",                                                -- github short form
    { "user/repo", opts = { ... } },                            -- with opts
    "https://gitlab.com/user/repo",                             -- any git URL
    "~/my-local-plugin",                                        -- local path (~)
    { "/absolute/path/to/plugin", opts = { ... } },             -- local absolute
  },
})
```

For each entry, the loader:

1. Normalizes the spec (path, source, opts, url).
2. For git specs: clones into `data_dir()/plugins/<repo>` if missing.
3. Prepends the plugin's `lua/` to `package.path`.
4. Sources every `hollow_plugin/*.lua` file.
5. Calls `M.setup(opts)` on the module named by the last path
   component, if it exists.

A failed clone or autoload file never aborts startup; the loader
logs and continues.

## `sync`

```lua
hollow.plugins.sync()
```

For each plugin with a `.git` directory, runs
`git pull --ff-only --recurse-submodules` and logs the result.
Restart Hollow to pick up new code.

## Plugin layout

```text
my-plugin/
  lua/                       -- added to package.path
    my-plugin/
      init.lua               -- exposes M.setup(opts) if configurable
  hollow_plugin/             -- autoloaded
    my-plugin.lua            -- or hollow_plugin/my-plugin/init.lua
```

- `lua/` is for on-demand `require()`.
- `hollow_plugin/` is for keymaps, event listeners, command
  registration. Sourced unconditionally in alphabetical order.
- `setup()` is optional.

## Errors and recovery

| Situation | Behaviour |
| --- | --- |
| Git clone fails | Logged, plugin skipped, others continue |
| `hollow_plugin/*.lua` errors | Logged, loader continues with the next file |
| `require()` of the module fails | Silently skipped (plugin may be autoload-only) |
| `setup()` throws | Logged with traceback, loader continues |
| Local path missing | Logged, plugin skipped |

## Out of scope (v1)

- Package manager UI
- Plugin-to-plugin dependency declarations
- Lazy loading
- Version pinning (`tag`, `commit`)
- Lockfiles

## See also

- [Plugins](../../plugins.md) — guide
- [Plugin authoring](../../examples/plugin-authoring.md) — a complete walkthrough
- [`hollow.fs`](fs.md) — `data_dir`, `glob`, `mkdir_p`
