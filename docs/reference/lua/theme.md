# `hollow.theme`

Theme resolution and palette helpers.
A theme is two coordinated tables — a terminal palette and a UI
palette — with an optional explicit `palette` override.

For the conceptual model see [Themes](../../themes.md).
For the LuaLS schema see
[`types/hollow.lua`](../../../types/hollow.lua) (`HollowThemeSpec`,
`HollowResolvedTheme`, `HollowTerminalTheme`, `HollowAppTheme`,
`HollowPalette`).

## Functions

```lua
hollow.theme.create(spec)             -- build a HollowResolvedTheme from a spec
hollow.theme.get(name)                -- load a named theme
hollow.theme.current()                -- the active theme
hollow.theme.resolve_widget(kind)     -- resolve a widget theme palette
```

### `create`

```lua
local theme = hollow.theme.create({
  terminal = { ... },
  ui = { ... },
  palette = { ... },
})
```

Returns a fully resolved `HollowResolvedTheme`. Useful for inspecting
or for passing a custom spec to a widget call.

### `get`

```lua
local theme = hollow.theme.get("kanagawa-wave")
```

`get(name)` resolves the name through `require("hollow.themes." .. name)`.
Built-in themes are listed in [Themes](../../themes.md#built-in-themes).
A custom theme plugin can therefore drop a Lua file at
`<plugin>/lua/hollow/themes/<name>.lua` and apply it by name.

### `current`

```lua
local theme = hollow.theme.current()
print(theme.ui.top_bar.background, theme.terminal.foreground)
```

The active theme. Resolves from `hollow.config.get("theme")` (either
a name or an inline spec).

### `resolve_widget`

```lua
local notify_palette = hollow.theme.resolve_widget("notify")
```

Returns the resolved widget theme for `kind`. Widgets that ship
`notify`, `input`, `select`, and `workspace` all read from
`theme.widgets.<kind>` (or `theme.widgets.all` as a fallback).

## Resolved theme shape

```lua
HollowResolvedTheme = {
  terminal = HollowTerminalTheme,
  ui       = HollowAppTheme,
  palette  = HollowPalette,
}

HollowTerminalTheme = {
  foreground, background, cursor_bg, cursor_fg, selection_bg, selection_fg,
  ansi    = HollowColor[8],
  brights = HollowColor[8],
}

HollowAppTheme = {
  widgets  = table,         -- per-widget palette
  top_bar  = { height, background },
  tab_bar  = table,
  scrollbar = HollowScrollbarConfig,
  split_active, split_inactive,
  floating_active, floating_inactive,
  accent, warm,
  status = { bg, fg },
}
```

## Switching themes at runtime

```lua
hollow.term.set_theme("rose-pine")
```

Or via the config (merged on next reload):

```lua
hollow.config.set({ theme = "kanagawa-wave" })
hollow.config.reload()
```

## See also

- [Themes](../../themes.md) — guide
- [Configuration](../../configuration.md) — the `theme` key
- [Custom UI](../../custom-ui.md#widget-theming) — widget theme tokens
