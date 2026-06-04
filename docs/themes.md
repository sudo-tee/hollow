# Themes

A Hollow theme is two coordinated tables: a terminal palette and a UI
palette.
The runtime ships a small set of named themes; you can also write an
inline theme spec or load a custom module.

For the API see [`hollow.theme`](reference/lua/theme.md).
For UI colors used by widgets see
[Custom UI → Widget theming](custom-ui.md#widget-theming).

## Built-in themes

Hollow ships with the following themes, all under
`src/lua/hollow/themes/`:

| Name | Style |
| --- | --- |
| `hollow` | The default dark theme |
| `catppuccin-mocha` | Catppuccin Mocha |
| `dracula` | Dracula |
| `gruvbox-dark` | Gruvbox Dark |
| `kanagawa-wave` | Kanagawa Wave |
| `nord` | Nord |
| `onedark` | One Dark |
| `rose-pine` | Rosé Pine |
| `solarized-dark` | Solarized Dark |
| `tokyonight` | Tokyo Night |

Apply a theme by name:

```lua
hollow.config.set({ theme = "kanagawa-wave" })
```

Switch at runtime:

```lua
hollow.term.set_theme("rose-pine")
```

## Theme shape

A theme spec has three parts: `terminal`, `ui`, and optionally `palette`.

```lua
hollow.config.set({
  theme = {
    terminal = {
      foreground = "#dcd7ba",
      background = "#1f1f28",
      cursor_bg  = "#dcd7ba",
      cursor_fg  = "#1f1f28",
      selection_bg = "#2d4f67",
      selection_fg = "#c8c093",
      ansi    = { "#090618", "#c34043", "#76946a", "#c0a36e",
                  "#7e9cd8", "#957fb8", "#6a9589", "#c8c093" },
      brights = { "#a6a69c", "#e8242c", "#98bb6c", "#e6c384",
                  "#7fb4ca", "#ad8ee6", "#7aa89f", "#dcd7ba" },
    },
    ui = {
      top_bar  = { height = 24, background = "#1f1f28" },
      tab_bar  = { ... },
      scrollbar = { ... },
      split_active   = "#3a3a52",
      split_inactive = "#2a2a40",
      floating_active   = "#3a3a52",
      floating_inactive = "#2a2a40",
      accent = "#7e9cd8",
      warm   = "#ffa066",
      status = { bg = "#1f1f28", fg = "#dcd7ba" },
      widgets = { all = { ... } },
    },
    palette = { ... }, -- optional override for any ANSI/bright key
  },
})
```

Each sub-table is merged into the matching default, so you can override
just the keys you care about.

## Loading a theme from a module

`hollow.theme.get(name)` looks up a theme by name using
`require("hollow.themes." .. name)`.
A custom theme plugin can therefore drop a Lua file under
`<plugin>/lua/hollow/themes/<name>.lua` and apply it by name.

The module should return a `HollowThemeSpec` table.

## Resolving the active theme

```lua
local theme = hollow.theme.current()
-- theme.terminal, theme.ui, theme.palette
```

`hollow.theme.resolve_widget(kind)` returns the resolved widget palette
for `kind` (e.g. `"notify"`, `"input"`, `"select"`, `"workspace"`).
The shipped notify, input, and select helpers resolve their colors from
`theme.widgets.all` and per-widget sections, and can be overridden per
call with `opts.theme` or `opts.chrome`.

## Hot tips

- The base config keeps a commented `theme = "kanagawa-wave"` line at
  the top of `hollow.config.set({...})`. Uncomment it to switch.
- Some theme fields (top bar height, scrollbar width) double as runtime
  config; the values resolved into the theme win after the base config
  applies.
- Use `hollow.theme.create({...})` to validate and resolve a spec into a
  full `HollowResolvedTheme` without applying it.

## See also

- [`hollow.theme`](reference/lua/theme.md) — full API
- [Custom UI → Widget theming](custom-ui.md#widget-theming) — how widgets
  read theme tokens
- [Configuration](configuration.md) — the `theme` key in the config schema
