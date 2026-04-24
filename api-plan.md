# Hollow Lua API Reference

Hollow is a terminal emulator written in Zig. Its behaviour is configured and extended entirely via Lua. This document is the authoritative reference for the Lua API surface.

## Conventions

- **Namespace pattern:** `hollow.<namespace>.<verb>(...)`.
- **Constructors, mutators, and config entry points take an `opts` table.** Required fields are noted. Optional fields are marked `?`.
- **Small targeting helpers may use positional arguments** when the target is obvious, e.g. `get(key)` or `focus_tab(id)`.
- **Handlers registered through `hollow.events.*` always receive a single `e` table.** Other callbacks use the signature documented by that surface.
- **Returned objects are snapshots.** Treat `HollowTab`, `HollowPane`, and similar values as read-only; mutate state through Hollow APIs.
- **Lua arrays are 1-indexed.** Any `Foo[]` type in this document follows normal Lua sequence rules.
- **All renderable surfaces share the same widget protocol.** Learning one means knowing all.

## Typings

Hollow should ship a LuaLS / EmmyLua definition file alongside the runtime API.

- The canonical stub lives at `types/hollow.lua`.
- `require("hollow")` users get module completions from that stub.
- Embedded configs that rely on the injected global `hollow` should add `types/` to `workspace.library` and mark `hollow` as a known global.
- During migration, the stub can keep deprecated aliases for the current flat API so existing configs remain editor-friendly.
- The bundled `.luarc.json` in this repo does that for local development.

---

## Primitives

These types are used throughout the API.

```
HollowColor  — string: "#rrggbb" | "#rrggbbaa" | CSS color name

HollowKeyChord — string using Vim-style notation, e.g. `j`, `<C-t>`, `<leader>e`, `<C-w>o`

HollowEventHandle — integer

HollowStyle
  fg?            HollowColor
  bg?            HollowColor
  bold?          boolean
  italic?        boolean
  underline?     boolean
  strikethrough? boolean
  dim?           boolean

HollowSize
  rows    integer
  cols    integer
  width   integer   -- pixels
  height  integer   -- pixels
```

---

## hollow.config

Runtime configuration. `set()` can be called multiple times; options are merged.

```lua
hollow.config.set(opts: HollowConfig)
hollow.config.get(key: string) → value
hollow.config.snapshot() → HollowConfig
hollow.config.reload()          -- reload from disk, fires "config:reloaded"
```

**HollowConfig fields:**

```
font?
  family   string
  size     number
  weight?  "thin"|"extralight"|"light"|"regular"|"medium"|"semibold"|"bold"|"extrabold"|"black"
  style?   "normal"|"italic"|"oblique"
  features? table<string, boolean>   -- OpenType features e.g. { ss01 = true }

theme?      string
opacity?    number                   -- 0.0–1.0
padding?    { x: integer, y: integer }
scrollback? integer
cursor?
  style?      "block"|"bar"|"underline"
  blink?      boolean
  blink_rate? integer                -- ms
scrollbar?
  enabled? boolean
  width?   integer                   -- pixels
shell?      string | string[]
env?        table<string, string>
```

**Example:**

```lua
hollow.config.set({
  font      = { family = "Zed Mono", size = 13 },
  theme     = "hollow-dark",
  scrollback = 10000,
  cursor    = { style = "block", blink = false },
})
```

---

## hollow.term

Read and manipulate terminal state: tabs, panes, titles.

```lua
hollow.term.current_tab()  → HollowTab
hollow.term.current_pane() → HollowPane
hollow.term.tabs()         → HollowTab[]
hollow.term.tab_by_id(id)  → HollowTab?

hollow.term.new_tab(opts?)  → HollowTab
hollow.term.focus_tab(id)
hollow.term.close_tab(id)
hollow.term.set_title(title, tab_id?)   -- tab_id defaults to current tab
hollow.term.send_text(text, pane_id?)
```

**HollowTab:**

```
id        integer
title     string
index     integer
is_active boolean
panes     HollowPane[]
pane      HollowPane    -- active pane in this tab
```

**HollowPane:**

```
id         integer
pid        integer    -- foreground process pid
cwd        string
title      string
is_focused boolean
size       HollowSize
```

**new_tab opts:**

```
cmd?   string | string[]
cwd?   string
env?   table<string, string>
title? string
```

---

## hollow.events

Pub/sub. Handlers always receive a single `e` payload table.

```lua
handle = hollow.events.on(name, handler)   -- returns integer handle
hollow.events.off(handle)
hollow.events.once(name, handler)          -- auto-unsubscribes after first fire
hollow.events.emit(name, payload?)         -- emit custom events
```

**Built-in event names and their payload shapes:**

| Event name           | Payload fields                               |
| -------------------- | -------------------------------------------- |
| `config:reloaded`    | _(none)_                                     |
| `term:title_changed` | `pane: HollowPane`, `old_title`, `new_title` |
| `term:tab_activated` | `tab: HollowTab`                             |
| `term:tab_closed`    | `tab_id: integer`                            |
| `term:pane_focused`  | `pane: HollowPane`                           |
| `term:cwd_changed`   | `pane: HollowPane`, `old_cwd`, `new_cwd`     |
| `key:unhandled`      | `key: string`, `mods: string`                |
| `window:resized`     | `size: HollowSize`                           |
| `window:focused`     | _(none)_                                     |
| `window:blurred`     | _(none)_                                     |

Custom events can be any string. Built-in events cannot be emitted from Lua; calling `hollow.events.emit()` with a built-in event name should raise an error.

**Example:**

```lua
local h = hollow.events.on("term:cwd_changed", function(e)
  print(e.pane.id, e.old_cwd, e.new_cwd)
end)

hollow.events.off(h)
```

---

## hollow.keymap

Register key bindings with Vim-style chord strings only.

```lua
hollow.keymap.set(chord: HollowKeyChord, action, opts?)
hollow.keymap.del(chord: HollowKeyChord)
hollow.keymap.get(chord: HollowKeyChord) -> action?
hollow.keymap.set_leader(chord: HollowKeyChord, opts?)
hollow.keymap.clear_leader()
hollow.keymap.is_leader_active() -> boolean
hollow.keymap.get_leader_state() -> HollowLeaderState?
```

**Accepted chord forms:**

```
"x"            -- plain character
"<C-t>"        -- modified chord
"<C-S-Tab>"    -- special key with modifiers
"<leader>e"    -- leader sequence
"<C-w>o"       -- non-leader multi-step sequence
```

Legacy `ctrl+...`, `leader+...`, and split `mods`/`key` forms should be rejected.

**Example:**

```lua
hollow.keymap.set("<C-S-p>", function()
  hollow.ui.select.open({
    items = hollow.term.tabs(),
    label = function(t) return t.title end,
    prompt = "Switch tab",
    actions = {
      { name = "focus", fn = function(t) hollow.term.focus_tab(t.id) end, key = "<CR>" },
    },
  })
end)

hollow.keymap.set("<C-S-n>", hollow.term.new_tab)
```

---

## hollow.ui — Rendering Primitives

All widgets are composed from these span nodes.

```lua
hollow.ui.span(text, style?)         → HollowSpan
hollow.ui.spacer()                   → HollowSpacerSpan   -- fills remaining row space
hollow.ui.icon(name, style?)         → HollowIconSpan     -- nerdfont icon by logical name
hollow.ui.group(children, style?)    → HollowGroupSpan    -- children inherit style
```

In the Phase 4 topbar MVP, `icon(name)` is rendered as plain text using `name` directly. A real icon registry can come later without changing the widget contract.

**HollowSpanNode** is a union of: `HollowSpan | HollowSpacerSpan | HollowIconSpan | HollowGroupSpan`

Each node carries a `_type` discriminant: `"span"`, `"spacer"`, `"icon"`, `"group"`.

```
HollowSpan
  _type  "span"
  text    string
  style?  HollowStyle

HollowSpacerSpan
  _type  "spacer"

HollowIconSpan
  _type  "icon"
  name    string
  style?  HollowStyle

HollowGroupSpan
  _type    "group"
  children HollowSpanNode[]
  style?   HollowStyle
```

`hollow.ui.group()` merges its own `style` into each child at render time; child fields win when both specify the same style key.

---

## hollow.ui — Widget Protocol

Every surface (topbar, sidebar, overlay) is a `HollowWidget`. They all share the same shape and the same render context.

```
HollowWidget
  render(ctx: HollowWidgetCtx) → HollowSpanNode[]   -- required; return `{}` for empty output
  on_event?(name, e)                                 -- optional, receives all events
  on_mount?()
  on_unmount?()

HollowOverlayOpts
  align?  "center"|"top_left"|"top_center"|"top_right"|"left_center"|"right_center"|"bottom_left"|"bottom_center"|"bottom_right"
  backdrop? boolean|"#rrggbb"|{ color?: "#rrggbb", alpha?: 0..255 }

HollowWidgetCtx
  term
    tab    HollowTab
    pane   HollowPane
    tabs   HollowTab[]
  size   HollowSize
  time
    epoch_ms  integer
    iso       string
```

---

## hollow.ui.topbar

A persistent one-row bar at the top of the window.

```lua
widget = hollow.ui.topbar.new(opts)
hollow.ui.topbar.mount(widget)
hollow.ui.topbar.unmount()
hollow.ui.topbar.invalidate()   -- mark dirty, triggers re-render next frame
```

Current MVP behavior: topbar widgets are adapted onto the existing left/right status segment renderer. A single `hollow.ui.spacer()` splits left content from right content.

**opts:**

```
height?   integer   -- rows, default 1
render    fun(ctx) → HollowSpanNode[]
on_event? fun(name, e)
on_mount? fun()
on_unmount? fun()
```

**Example:**

```lua
hollow.ui.topbar.mount(hollow.ui.topbar.new({
  render = function(ctx)
    return {
      hollow.ui.span(ctx.term.pane.cwd, { fg = "#cdd6f4" }),
      hollow.ui.spacer(),
      hollow.ui.span(ctx.time.iso, { fg = "#6c7086" }),
    }
  end,
}))
```

---

## hollow.ui.sidebar

A persistent vertical panel, collapsible.

```lua
widget = hollow.ui.sidebar.new(opts)
hollow.ui.sidebar.mount(widget)
hollow.ui.sidebar.unmount()
hollow.ui.sidebar.toggle()
hollow.ui.sidebar.invalidate()
```

**opts:**

```
side?     "left"|"right"   -- default "left"
width?    integer           -- cols
render    fun(ctx) → HollowSpanNode[]
on_event? fun(name, e)
on_mount? fun()
on_unmount? fun()
```

Phase 5 note: the shared widget runtime exists, but sidebar rendering is not yet drawn by the Zig renderer. Mounting a sidebar gives lifecycle + event participation now; visible panel rendering is still a follow-up.
Updated: sidebar rendering is now optional and real. If no sidebar is mounted, or if it is toggled hidden, no space is reserved and nothing is drawn.

---

## hollow.ui.overlay

A fullscreen overlay. Multiple overlays stack; `pop()` removes the topmost.

```lua
widget = hollow.ui.overlay.new(opts)
hollow.ui.overlay.push(widget)
hollow.ui.overlay.pop()
hollow.ui.overlay.clear()
hollow.ui.overlay.depth() → integer
```

**opts:**

```
render      fun(ctx) → HollowSpanNode[]
on_key?     fun(key, mods): boolean   -- return true to consume the key
on_mount?   fun()
on_unmount? fun()
chrome?     { bg?: "#rrggbb", border?: "#rrggbb" }
```

`on_key` receives canonical key names and a Vim-style modifier prefix string like `""`, `<C>`, or `<C-S>`.
Built-in `input` and `select` helpers also treat printable keys such as digits and punctuation as text input.

Phase 5 note: overlays are currently a Lua-side runtime with keyboard handling and simple multi-line text rendering through existing top-level drawing hooks. This is enough to power prompts, pickers, and notifications before a dedicated Zig overlay compositor lands.
Updated: overlays are now visually rendered by the Zig renderer as stacked optional panels. If no overlays are pushed, nothing is drawn.

---

## hollow.ui.notify

Transient or sticky notification toasts.

```lua
hollow.ui.notify.show(message, opts?)
hollow.ui.notify.clear()

-- Shorthands:
hollow.ui.notify.info(message, opts?)
hollow.ui.notify.warn(message, opts?)
hollow.ui.notify.error(message, opts?)
```

**opts:**

```
level?   "info"|"warn"|"error"|"success"   -- default "info"
title?   string
ttl?     integer                           -- ms; nil = sticky until dismissed
align?   HollowOverlayAlign                -- default "center"; accepts shortcuts like "right" or "bottom_right"
backdrop? boolean                          -- default false; dim content behind the toast when true
chrome?  { bg?: "#rrggbb", border?: "#rrggbb" }
theme?   HollowWidgetTheme                 -- overrides resolved widget theme tokens for this call
action?
  label  string
  fn     fun()    -- invoked when the user activates the toast action
```

**Example:**

```lua
hollow.ui.notify.error("Build failed", {
  title = "Zig",
  ttl   = 5000,
  action = { label = "View log", fn = function()
    hollow.term.new_tab({ cmd = "cat /tmp/build.log" })
  end },
})
```

---

## hollow.ui.input

A single-line prompt, rendered inline.

```lua
hollow.ui.input.open(opts)
hollow.ui.input.close()
```

**opts:**

```
prompt?    string
default?   string
backdrop?  boolean|"#rrggbb"|{ color?: "#rrggbb", alpha?: 0..255 }
width?     integer                 -- overlay width in cols
height?    integer                 -- overlay height in rows
chrome?    { bg?: "#rrggbb", border?: "#rrggbb" }
theme?     HollowWidgetTheme
on_confirm fun(value: string)
on_cancel? fun()
```

`on_confirm` receives the final string value. Returning from the callback closes the prompt.

**Example:**

```lua
hollow.ui.input.open({
  prompt     = "Rename tab: ",
  default    = hollow.term.current_tab().title,
  on_confirm = function(v) hollow.term.set_title(v) end,
})
```

---

## hollow.ui.select

A fuzzy-filtered list picker with named multi-action support.

```lua
hollow.ui.select.open(opts)
hollow.ui.select.close()
```

**opts:**

```
items      T[]
label?     fun(item: T): string|HollowSpanNode|{ string, ...style }|Array<string|HollowSpanNode|{ string, ...style }>    -- display text; default tostring
detail?    fun(item: T): string|HollowSpanNode|{ string, ...style }|Array<string|HollowSpanNode|{ string, ...style }>    -- second column / preview line
prompt?    string
fuzzy?     boolean                 -- default true
query?     string                  -- initial filter text
backdrop?  boolean|"#rrggbb"|{ color?: "#rrggbb", alpha?: 0..255 } -- default true
width?     integer                 -- overlay width in cols
height?    integer                 -- overlay height in rows; list scrolls when needed
chrome?    { bg?: "#rrggbb", border?: "#rrggbb" }
theme?     HollowWidgetTheme
actions    HollowSelectAction[]    -- first = default (<CR>); rest = alternates
on_cancel? fun()
```

**HollowSelectAction:**

```
name   string    -- e.g. "open", "open_split", "delete"
fn     fun(item: T)
key?   string    -- key hint shown in footer, e.g. "<CR>", "<C-d>"
desc?  string    -- tooltip shown in footer
```

The select always renders a filter input row. When `fuzzy ~= false`, typed input uses fuzzy subsequence matching and ranks closer matches first; otherwise it falls back to plain substring filtering.

Arrow navigation wraps from last to first and first to last. When the result list exceeds the available height, the visible window scrolls around the active item.

Built-in widgets resolve colors from `theme.widgets.all` plus `theme.widgets.notify`, `theme.widgets.input`, and `theme.widgets.select`. Per-call `opts.theme` overrides those tokens.

`label` and `detail` may return formatted span nodes, so select items can include custom colors/styles while fuzzy matching still uses the flattened plain text.

For lighter-weight formatting, a text shorthand like `{ "warn", fg = "#e0af68", bold = true }` is accepted anywhere a formatted select label/detail node is expected.

There are also lighter helpers for this style of composition: `hollow.ui.text(value, style?)` and `hollow.ui.row(...)`.

For a more React-ish composition style without JSX, `hollow.ui.h(tag, props?, ...)` / `hollow.ui.el(...)` provide a tiny hyperscript helper.

Component functions receive `props.children`, `props.children_row`, and `props.children_rows`. There is also `hollow.ui.fragment(...)` plus `hollow.ui.tags.row(...)` / `hollow.ui.tags.text(...)` style tag factories.

The **first** action is always the default, executed on plain `<CR>`. Alternate action keys are shown as hints in the widget footer and matched against `action.key` when provided.

**Example:**

```lua
hollow.ui.select.open({
  items   = hollow.term.tabs(),
  label   = function(t) return t.title end,
  prompt  = "Switch tab",
  actions = {
    {
      name = "focus",
      fn   = function(t) hollow.term.focus_tab(t.id) end,
      key  = "<CR>",
    },
    {
      name = "close",
      fn   = function(t) hollow.term.close_tab(t.id) end,
      key  = "<C-d>",
      desc = "Close tab",
    },
    {
      name = "rename",
      key  = "<C-r>",
      desc = "Rename tab",
      fn   = function(t)
        hollow.ui.input.open({
          prompt     = "Rename: ",
          default    = t.title,
          on_confirm = function(v) hollow.term.set_title(v, t.id) end,
        })
      end,
    },
  },
})
```

> **Composition note:** Calling `hollow.ui.input.open()` from inside a select action does not close the underlying select. Both layers remain on the overlay stack.

---

## hollow.htp

Host-side handlers for the Hollow Terminal Protocol. HTP allows guest shells to query or emit events to the Zig host over OSC escape sequences.

```lua
hollow.htp.on_query(channel, handler)   -- handler(ctx) must return a value
hollow.htp.on_emit(channel, handler)    -- handler(ctx) side-effect only, no return
hollow.htp.off_query(channel)
hollow.htp.off_emit(channel)
```

Query handlers should return Lua values that Hollow can serialize across HTP: `nil`, `boolean`, `number`, `string`, or tables composed recursively from those value types.

**HtpQueryContext:**

```
pane    HollowPane
params  table<string, any>
```

**HtpEmitContext:**

```
pane    HollowPane
payload any
```

**Example:**

```lua
hollow.htp.on_query("theme", function(ctx)
  return hollow.config.get("theme")
end)

hollow.htp.on_emit("shell:cwd_changed", function(ctx)
  hollow.ui.topbar.invalidate()
end)
```

---

## hollow.process

Spawn and manage child processes.

```lua
proc = hollow.process.spawn(opts)   → HollowProcess
result = hollow.process.exec(opts)  → HollowExecResult  -- blocking
```

**opts:**

```
cmd   string | string[]
cwd?  string
env?  table<string, string>
```

**HollowProcess:**

```
pid     integer
stdin   { write(data: string) }
stdout  { read(): string? }
stderr  { read(): string? }
wait()  → integer    -- exit code
kill()
```

**HollowExecResult:**

```
exit_code integer
stdout    string
stderr    string
```

`stdout.read()` and `stderr.read()` return the next available chunk, or `nil` on EOF.

---

## Full Config Example

```lua
local hollow = require("hollow")

-- Config
hollow.config.set({
  font      = { family = "Zed Mono", size = 13, features = { ss01 = true } },
  theme     = "hollow-dark",
  scrollback = 20000,
  cursor    = { style = "bar", blink = true, blink_rate = 500 },
  padding   = { x = 8, y = 4 },
})

-- Topbar
hollow.ui.topbar.mount(hollow.ui.topbar.new({
  render = function(ctx)
    return {
      hollow.ui.icon("nf-fa-terminal", { fg = "#cba6f7" }),
      hollow.ui.span(" " .. ctx.term.tab.title, { fg = "#cdd6f4", bold = true }),
      hollow.ui.spacer(),
      hollow.ui.span(ctx.term.pane.cwd, { fg = "#6c7086" }),
      hollow.ui.span("  " .. ctx.time.iso, { fg = "#45475a" }),
    }
  end,
}))

-- Keybinds
hollow.keymap.set("<C-S-p>", function()
  hollow.ui.select.open({
    items  = hollow.term.tabs(),
    label  = function(t) return t.title end,
    prompt = "Switch tab",
    actions = {
      { name = "focus", fn = function(t) hollow.term.focus_tab(t.id) end, key = "<CR>" },
      { name = "close", fn = function(t) hollow.term.close_tab(t.id) end, key = "<C-d>" },
    },
  })
end)

hollow.keymap.set("<C-S-n>", hollow.term.new_tab)
hollow.keymap.set("<C-S-r>", function()
  hollow.ui.input.open({
    prompt     = "Rename tab: ",
    default    = hollow.term.current_tab().title,
    on_confirm = function(v) hollow.term.set_title(v) end,
  })
end)

-- Events
hollow.events.on("term:cwd_changed", function(e)
  hollow.ui.topbar.invalidate()
end)

hollow.events.on("config:reloaded", function()
  hollow.ui.notify.info("Config reloaded", { ttl = 2000 })
end)

-- HTP
hollow.htp.on_query("theme", function(ctx)
  return hollow.config.get("theme")
end)
```

## Implementation Notes

Yes — I’d implement this as a staged migration, not a big-bang rewrite.

- The contract in  `hollow-lua-api.md` is ahead of the current runtime in  `src/lua/luajit.zig` and  `src/lua/core.lua`.
- So the safest path is: first make the shape real, then fill in host capabilities, then build the richer UI/runtime pieces on top.

**Phase 1**

- Expose the namespaced surface in `src/lua/core.lua`:
  - `hollow.config`
  -  `hollow.term`
  - `hollow.events`
  -  `hollow.keymap`
  -  `hollow.ui`
  -  `hollow.htp`
  - `hollow.process`
- Keep legacy flat APIs as deprecated aliases so existing configs still work.
- Make `require("hollow")` return the same table as the injected global.
- Goal: contract shape exists, even if some methods are marked `error("not implemented")` temporarily.

**Phase 2**

- Add the missing host query APIs in `src/lua/luajit.zig` and app state plumbing:
  - `current_tab()`, `current_pane()`, `tabs()`, `tab_by_id()`
  - pane/tab snapshot tables
  - `set_title()`, `send_text()`
- Add snapshot builders in Zig so Lua gets read-only structured objects.
- Goal: `hollow.term.*` becomes real and type-safe.

**Phase 3**

- Add the event system contract:
  - `hollow.events.on/off/once/emit`
  - built-in host events emitted from Zig
  - custom events emitted from Lua only
- Wire events from app lifecycle and mux changes:
  - tab activated/closed
  - pane focused
  - cwd/title changes
  - window resize/focus
  - config reload
- Goal: Lua can react to terminal state instead of polling.

**Phase 4**

- Implement UI primitives + one real surface first:
  - `hollow.ui.span/spacer/icon/group`
  - generic node parsing in Zig
  - `hollow.ui.topbar` as the first widget host
- Keep topbar as the MVP renderer for the widget protocol before sidebar/overlay.
- Goal: prove the node model and rendering contract with one surface.

**Phase 5**

- Build the generic widget runtime:
  - shared `HollowWidget` protocol
  - invalidation/mount/unmount lifecycle
  - event fanout to mounted widgets
- Then add:
  - `hollow.ui.sidebar`
  - `hollow.ui.overlay`
- Goal: one internal engine, multiple surfaces.

**Phase 6**

- Add higher-level built-in widgets on top of overlay:
  - `hollow.ui.notify`
  -  `hollow.ui.input`
  - `hollow.ui.select`
- These should be pure Lua-facing APIs backed by Zig overlay/input handling.
- Goal: ergonomic user features without exposing renderer internals.

**Phase 7**

- Add host integration APIs:
  - `hollow.htp.*`
  - `hollow.process.spawn/exec`
- Reuse the same event and serialization machinery from earlier phases.
- Goal: shell/host extensibility and scripting power.

**Phase 8**

- Lock the contract:
  - align  `types/hollow.lua` with runtime behavior
  - add examples and migration notes
  - add contract tests for docs/examples
  - mark old flat APIs deprecated in docs
- Goal: docs, typings, and behavior all match.

**Implementation rule**

- Don’t make the docs lie. For each phase, either:
  - implement the function, or
  - mark it `experimental` / `not yet available`.
- Avoid documenting `ui.sidebar`, `ui.overlay`, `process`, or `htp` as fully shipped until they really are.

**Recommended order**

1. Phase 1: namespace adapter
2. Phase 2: term snapshots
3. Phase 3: events
4. Phase 4: topbar widget MVP
5. Phase 5-6: generic widget stack + built-ins
6. Phase 7: HTP/process
7. Phase 8: stabilization

If you want, I can start Phase 1 now and implement the namespaced compatibility layer in `src/lua/core.lua`, then wire the first missing term APIs in `src/lua/luajit.zig`.
