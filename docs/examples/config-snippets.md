# Config snippets

Drop-in `hollow.config.set(...)` calls for common tweaks.
Each snippet is safe to paste into your personal
`%APPDATA%\hollow\init.lua` (Windows) or
`$XDG_CONFIG_HOME/hollow/init.lua` (other).

For the schema see [`hollow.config`](../reference/lua/config.md).
For the higher-level model see
[Configuration](../configuration.md).

## Font size shortcuts

Wire `<C-S-minus>`, `<C-S-equal>`, and `<C-0>` to adjust font size
on the fly.

```lua
local hollow = require("hollow")

local default_font_size = 14

local function set_font_size(size)
  hollow.config.set({ fonts = { size = size } })
  hollow.ui.notify.info("Font size: " .. tostring(size), { ttl = 1200 })
end

local function adjust_font_size(delta)
  local fonts = hollow.config.get("fonts") or {}
  local size = tonumber(fonts.size) or default_font_size
  set_font_size(math.max(6, size + delta))
end

hollow.keymap.set("<C-S-minus>", function() adjust_font_size(-0.5) end,
  { desc = "decrease font size" })
hollow.keymap.set("<C-S-equal>", function() adjust_font_size(0.5) end,
  { desc = "increase font size" })
hollow.keymap.set("<C-0>", function() set_font_size(default_font_size) end,
  { desc = "reset font size" })
```

## Renaming a tab

Wire a leader key to a small rename prompt.

```lua
hollow.keymap.set("<leader>r", function()
  local tab = hollow.term.current_tab()
  if not tab then return end

  hollow.ui.input.open({
    prompt = "Rename tab",
    default = tab.title,
    on_confirm = function(new_title)
      hollow.term.set_title(new_title, tab.id)
    end,
  })
end, { desc = "rename tab" })
```

## Reload config

```lua
hollow.keymap.set("<leader>uu", function()
  hollow.config.reload()
  hollow.ui.notify.info("Config reloaded", { ttl = 1200 })
end, { desc = "reload config" })
```

## Custom WSL domain

Address a specific WSL distro and pin the default cwd.

```lua
hollow.config.set({
  domains = {
    wsl = {
      shell = "C:\\Windows\\System32\\wsl.exe",
      default_cwd = "/home/me",
    },
  },
})
```

For per-distro domains, leave the call to
`hollow.config.populate_wsl_domains()` in place; the shipped base
config calls it on Windows and it adds one `{distro}WSL` domain per
installed distro.

## SSH-backed devbox

```lua
hollow.config.set({
  domains = {
    devbox = {
      ssh = {
        alias = "devbox",
        backend = "wsl",
        reuse = "auto",
      },
    },
  },
})
```

`backend = "wsl"` launches the SSH client through `wsl.exe`.
`reuse = "auto"` enables OpenSSH multiplexing flags for
WSL/Linux-backed SSH.

## Pick the first available font

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

## Hide the scrollbar

```lua
hollow.config.set({
  scrollbar = { enabled = false },
})
```

## Hyperlinks: open on plain click

The default is `shift_click_only = true`. To open on plain click:

```lua
hollow.config.set({
  hyperlinks = { shift_click_only = false },
})
```

## Disable the top bar

```lua
hollow.config.set({ top_bar_mode = "tabs" })
```

`"tabs"` shows the top bar only when more than one tab is open.
`"always"` keeps it on screen all the time.

## Bell with a custom color

```lua
hollow.config.set({
  bell = {
    visual = true,
    visual_color = "#ffcc66",
    visual_duration_ms = 200,
    visual_alpha = 96,
  },
})
```

## Notify on bell

```lua
hollow.events.on("term:bell", function(e)
  hollow.ui.notify.warn("bell in " .. (e.pane.title or "<pane>"))
end)
```

`pane.has_bell` stays `true` until the pane receives focus, so the
shipped top bar keeps its attention marker visible.

## Auto-bootstrap workspaces

```lua
hollow.config.set({
  workspace = {
    auto_bootstrap = "always",
    default_layout = "default",
  },
})
```

`auto_bootstrap = "always"` checks for
`.hollow/workspace.json` rooted at the active pane cwd first, then
falls back to `~/.config/hollow/layouts/default.json`.

## Disable default keymaps

```lua
hollow.config.set({ load_default_keymaps = false })

-- Now define only what you need
hollow.keymap.set("<C-t>", "new_tab")
hollow.keymap.set("<C-S-x>", "close_tab")
hollow.keymap.set("<C-\\>", "split_vertical")
```

## Custom env per domain

```lua
hollow.config.set({
  domains = {
    wsl = {
      shell = "wsl.exe",
      env = {
        HOLLOW_THEME = "kanagawa-wave",
      },
    },
  },
})
```

The shipped `env` table under `hollow.config` is merged into every
guest session; domain-level `env` is per-domain.

## See also

- [Configuration](../configuration.md) — guide
- [`hollow.config`](../reference/lua/config.md) — full schema
- [UI recipes](ui-recipes.md)
