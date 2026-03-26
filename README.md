# Hollow

<div align="center">
  <img src="assets/banner.png" alt="Opencode logo" width="30%" />
</div>

A **Love2D / LuaJIT** terminal emulator frontend powered by **libghostty-VT** for VT parsing,
with a **WezTerm-inspired scriptable Lua API**, full split panes, tabs, workspaces, and a
customisable status bar.

This is a proof-of-concept / playground this is not intended for production.

---

## Architecture

```
ghostty-love/
├── main.lua                  # Love2D entry point; wires events → App
├── conf.lua                  # Love2D window config
├── conf/
│   └── init.lua              # Example user config (copy to ~/.config/ghostty-love/)
└── src/
    ├── core/
    │   ├── ghostty_ffi.lua   # LuaJIT FFI bindings for libghostty-VT
    │   ├── pty.lua           # POSIX forkpty / ConPTY abstraction
    │   ├── pane.lua          # Terminal pane (surface + PTY)
    │   ├── split.lua         # Recursive binary split tree
    │   ├── tab.lua           # Tab (owns a split tree)
    │   ├── workspace.lua     # Workspace (owns tabs)
    │   ├── app.lua           # Top-level orchestrator
    │   ├── config.lua        # Config loader / store
    │   ├── keymap.lua        # Key binding matcher + VT encoder
    │   └── event_bus.lua     # Pub/sub event system
    ├── renderer/
    │   └── terminal.lua      # Love2D glyph/cell renderer
    ├── ui/
    │   ├── tab_bar.lua       # Tab bar (click-to-switch, bell indicator)
    │   └── status_bar.lua    # Scriptable status bar (left/right segments)
    └── api/
        └── init.lua          # `hollow` global - public scripting API
```

### Object hierarchy

```
App
└── Workspace[]       (switchable like i3 workspaces)
    └── Tab[]         (own a split tree each)
        └── SplitNode (recursive binary tree)
            └── Leaf  (wraps one Pane)
                └── Pane  (one libghostty-VT surface + one PTY child)
```

---

## Dependencies

| Dependency                          | Purpose                                             |
| ----------------------------------- | --------------------------------------------------- |
| [Love2D](https://love2d.org) ≥ 11.4 | Window, graphics, input, LuaJIT                     |
| **libghostty-VT**                   | VT / ANSI / kitty protocol parsing & terminal state |

### Getting libghostty-VT

Build from the [ghostty](https://github.com/ghostty-org/ghostty) source tree with the
`libghostty` target, then copy the resulting `.so` / `.dylib` / `.dll` next to `main.lua`:

```bash
# Example (adjust paths to your ghostty checkout)
cd ghostty
zig build libghostty -Doptimize=ReleaseFast
cp zig-out/lib/libghostty-VT.so /path/to/ghostty-love/
```

---

## Running

```bash
love /path/to/ghostty-love
# or on Linux if love is in PATH:
cd ghostty-love && love .
```

---

## User Configuration

Copy `conf/init.lua` to `~/.config/ghostty-love/init.lua` and edit it.
The `hollow` global is available before the file runs.

### Font

```lua
hollow.set_config({
    font_path = "fonts/JetBrainsMonoNerdFont-Regular.ttf",
    font_size = 15,
})
```

### Colours

```lua
local c = hollow.color
hollow.set_config({
    colors = {
        background = c.from_hex("#1e1e2e"),
        cursor     = c.from_hex("#f5e0dc"),
        -- ... see conf/init.lua for full schema
    }
})
```

### Key bindings

```lua
-- Bind to a built-in action
hollow.keys.bind({ ctrl=true, shift=true }, "h", "split_h")
hollow.keys.bind({ ctrl=true, shift=true }, "v", "split_v")

-- Bind to a Lua callback
hollow.keys.bind({ super=true }, "k", function()
    hollow.actions.new_tab()
end)
```

Available built-in actions: `new_tab`, `close_tab`, `next_tab`, `prev_tab`,
`split_h`, `split_v`, `close_pane`, `focus_next`, `focus_prev`,
`new_workspace`, `next_workspace`, `prev_workspace`.

### Status bar

```lua
hollow.status_bar.set_left(function(workspace, tab, pane)
    return {
        { text = "  " .. workspace.name .. "  ", fg={1,1,1,1}, bg={0.4,0.2,0.8,1} },
        { text = "  " .. (pane and pane.title or "") .. "  " },
    }
end)

hollow.status_bar.set_right(function(ws, tab, pane)
    return {
        { text = "  " .. os.date("%H:%M") .. "  ", bg={0.1,0.1,0.15,1} },
    }
end)
```

Each segment: `{ text = "...", fg = {r,g,b,a}, bg = {r,g,b,a} }` (all optional except `text`).

### Event hooks

```lua
hollow.on("app:ready",        function() end)
hollow.on("app:update",       function(dt) end)
hollow.on("app:resize",       function(w, h) end)
hollow.on("app:quit",         function() end)
hollow.on("pane:focus",       function(pane) end)
hollow.on("workspace:switch", function(idx) end)
-- action:NAME fires for any unhandled dispatch action
hollow.on("action:my_action", function() end)
```

---

## Default Key Bindings

| Binding          | Action              |
| ---------------- | ------------------- |
| `Ctrl+Shift+T`   | New tab             |
| `Ctrl+Shift+W`   | Close tab           |
| `Ctrl+Tab`       | Next tab            |
| `Ctrl+Shift+Tab` | Previous tab        |
| `Ctrl+Shift+D`   | Split horizontal    |
| `Ctrl+Shift+E`   | Split vertical      |
| `Ctrl+Shift+Q`   | Close pane          |
| `Ctrl+]`         | Focus next pane     |
| `Ctrl+[`         | Focus previous pane |
| `Ctrl+Shift+N`   | New workspace       |
| `Ctrl+Shift+→`   | Next workspace      |
| `Ctrl+Shift+←`   | Previous workspace  |

---

## Roadmap / TODO

- [ ] Windows ConPTY support (winpty binding)
- [ ] Kitty keyboard protocol full implementation
- [ ] GPU-accelerated glyph atlas (Love2D SpriteBatch)
- [ ] Ligature support via HarfBuzz FFI
- [ ] True-colour image / sixel rendering via iTerm2 protocol
- [ ] Mouse reporting passthrough to apps
- [ ] Search / find-in-scrollback
- [ ] Copy-on-select / OSC 52 clipboard
- [ ] Session persistence (serialize pane layout)
- [ ] Multiplexer mode (multiple windows share one server process)
- [ ] Plugin system (load additional `.lua` files from a plugins/ dir)

---

## License

MIT — see `LICENSE`.
