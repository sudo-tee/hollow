# Plugins

A Hollow plugin is a directory of Lua files.
The runtime clones git-based plugins, autoloads any `hollow_plugin/*.lua`
files, and calls `setup(opts)` on the module if it provides one.

For the API see [`hollow.plugins`](reference/lua/plugins.md).
For a working example see
[`examples/plugins/hollow-spirit`](../examples/plugins/hollow-spirit).

## Declaring plugins

Plugins are declared in your personal config:

```lua
local hollow = require("hollow")

hollow.plugins.setup({
  plugins = {
    -- short form: resolved to https://github.com/{user}/{repo}.git
    "user/repo",

    -- with opts passed to M.setup(opts)
    { "user/repo", opts = { key = "value" } },

    -- explicit git URL (any host: GitLab, Codeberg, SourceHut, ...)
    "https://gitlab.com/user/repo",

    -- local path (starts with ~ or /)
    "~/hollow-spirit",
    { "/absolute/path/to/plugin", opts = { ... } },
  },
})
```

A failed clone never aborts startup — it logs a warning and Hollow
continues with the rest of the config.

## Plugin layout

```text
my-plugin/
  lua/                    -- prepended to package.path
    my-plugin/
      init.lua            -- should expose M.setup(opts) if configurable
  hollow_plugin/          -- all .lua files are autoloaded
    my-plugin.lua         --   or: hollow_plugin/my-plugin/init.lua
```

- `lua/` is for on-demand `require()`. The runtime prepends each
  plugin's `lua/` to `package.path` before loading autoload files.
- `hollow_plugin/` is sourced unconditionally in alphabetical order at
  startup. Use it for keymaps, event listeners, and command registration.
- A plugin may be autoload-only; `setup()` is optional.

## Authoring a plugin

Minimal plugin (`hollow-hello/`):

```lua
-- hollow-hello/hollow_plugin/hello.lua
local hollow = require("hollow")

hollow.keymap.set("<leader>hi", function()
  hollow.ui.notify.info("hello from a plugin", { ttl = 1500 })
end, { desc = "say hi" })
```

```lua
-- hollow-hello/lua/hollow-hello/init.lua
local M = {}

function M.setup(opts)
  print("hollow-hello loaded with", vim and vim.inspect(opts) or "")
end

return M
```

Drop the directory somewhere stable and register it:

```lua
hollow.plugins.setup({ plugins = { "~/code/hollow-hello" } })
```

On the next startup, `<leader>hi` shows the toast, and `M.setup({})` runs.

A more complete example is
[`examples/plugins/hollow-spirit`](../examples/plugins/hollow-spirit);
it demonstrates a module with `setup(opts)`, an autoloaded event
listener, and a UI notifier.

## Updating plugins

```lua
hollow.plugins.sync()
```

`sync()` walks all declared plugins. For each one with a `.git`
directory, it runs `git pull --ff-only --recurse-submodules` and logs
the result. Restart Hollow to pick up new code.

You can bind this to a key for convenience:

```lua
hollow.keymap.set("<leader>us", function()
  hollow.plugins.sync()
  hollow.ui.notify.info("Plugins synced — restart Hollow", { ttl = 2000 })
end, { desc = "sync plugins" })
```

## Where plugins live

- Git plugins are cloned into `hollow.fs.data_dir() .. "/plugins"`.
- `data_dir()` resolves to:
  - Windows: `%APPDATA%\hollow`
  - Linux/macOS/WSL: `$XDG_DATA_HOME/hollow` or `~/.local/share/hollow`

Local plugins stay where they are; the loader reads from the path you
give it.

## Errors and recovery

| Situation | Behaviour |
| --- | --- |
| Git clone fails | Logged, plugin skipped, others continue |
| `hollow_plugin/*.lua` errors | Logged, loader continues with the next file |
| `require()` of the module fails | Silently skipped (plugin may be autoload-only) |
| `setup()` throws | Logged with traceback, loader continues |
| Local path missing | Logged, plugin skipped |

The loader never panics. Errors are visible in `hollow.log` next to
the executable.

## See also

- [`hollow.plugins`](reference/lua/plugins.md) — full API
- [`hollow.fs`](reference/lua/fs.md) — `data_dir`, `glob`, `mkdir_p`
- [`hollow.process`](reference/lua/process.md) — process runner used by
  the loader
- [Plugin authoring](examples/plugin-authoring.md) — a complete walkthrough
