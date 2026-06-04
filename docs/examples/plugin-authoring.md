# Plugin authoring

A complete walkthrough that turns a "hello world" plugin into
something useful. The full plugin system reference is
[`hollow.plugins`](../reference/lua/plugins.md) and the guide is
[Plugins](../plugins.md). A working example lives at
[`examples/plugins/hollow-spirit`](../../examples/plugins/hollow-spirit).

## The smallest possible plugin

A plugin is just a directory.
Create it anywhere stable — `~/code/hollow-hello` is fine.

```text
hollow-hello/
  hollow_plugin/
    hello.lua
```

```lua
-- hollow-hello/hollow_plugin/hello.lua
local hollow = require("hollow")

hollow.keymap.set("<leader>hi", function()
  hollow.ui.notify.info("hello from a plugin", { ttl = 1500 })
end, { desc = "say hi" })
```

Register it from your personal config:

```lua
hollow.plugins.setup({
  plugins = { "~/code/hollow-hello" },
})
```

On the next startup (or after `<leader>uu`), `<leader>hi` shows a
toast.

## Adding a module with `setup`

Add a `lua/` directory and a module file:

```text
hollow-hello/
  hollow_plugin/
    hello.lua
  lua/
    hollow-hello/
      init.lua
```

```lua
-- hollow-hello/lua/hollow-hello/init.lua
local M = {}

function M.setup(opts)
  hollow.log("hollow-hello loaded with", opts and opts.message or "<no message>")
  M._opts = opts or {}
end

function M.greet()
  return M._opts.message or "hello from a plugin"
end

return M
```

`setup` is called once at startup with the `opts` table from the
plugin declaration. The module is then reachable via
`require("hollow-hello")` from any other Lua code in the same
Hollow process.

Pass opts from the loader:

```lua
hollow.plugins.setup({
  plugins = {
    { "~/code/hollow-hello", opts = { message = "hi, hollow" } },
  },
})
```

## Using the module from autoload

```lua
-- hollow-hello/hollow_plugin/hello.lua
local hollow = require("hollow")
local hello = require("hollow-hello")

hollow.keymap.set("<leader>hi", function()
  hollow.ui.notify.info(hello.greet(), { ttl = 1500 })
end, { desc = "say hi" })
```

## Reacting to events

`hollow-hello` could react to terminal events:

```lua
-- hollow-hello/hollow_plugin/events.lua
local hollow = require("hollow")

hollow.events.on("term:bell", function(e)
  hollow.ui.notify.warn("bell in " .. (e.pane.title or "<pane>"),
    { ttl = 1500 })
end)

hollow.events.on("workspace:new", function(e)
  hollow.log("new workspace:", e.workspace.name)
end)
```

The shipped `hollow-spirit` example uses this pattern: an
autoloaded event listener, a module with `setup(opts)`, and a small
toast notifier.

## Distributing via git

Put the directory in a git repo and reference it with the
`user/repo` shorthand or a full URL:

```lua
hollow.plugins.setup({
  plugins = {
    "your-user/hollow-hello",
    "https://gitlab.com/your-user/hollow-hello",
  },
})
```

Hollow clones the repo into
`hollow.fs.data_dir() .. "/plugins/hollow-hello"` on first run.

Update with:

```lua
hollow.plugins.sync()
```

`sync` runs `git pull --ff-only --recurse-submodules` for each git
plugin; restart Hollow to pick up new code.

## Layout reference

```text
my-plugin/
  lua/                    -- prepended to package.path
    my-plugin/
      init.lua            -- M.setup(opts) lives here
  hollow_plugin/          -- autoloaded
    *.lua                 -- or: hollow_plugin/my-plugin/init.lua
```

A plugin can be autoload-only with no `lua/` directory.
A plugin can be module-only with no `hollow_plugin/` directory.
The two halves are independent.

## Error handling

The loader is forgiving.
A failed clone, a missing module, a throwing `setup`, and a broken
`hollow_plugin/*.lua` file all log a warning and let startup
continue. The runtime never aborts because of a plugin.

## See also

- [Plugins](../plugins.md) — guide
- [`hollow.plugins`](../reference/lua/plugins.md) — full API
- [`hollow-spirit`](../../examples/plugins/hollow-spirit) — working example
- [`hollow.fs`](../reference/lua/fs.md) — `data_dir` and friends
- [Editor support (LuaLS)](../development.md#editor-support-luals) — `.luarc.json` setup for type hints
