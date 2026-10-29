# Themes

A Hollow theme is two coordinated tables: a terminal palette and a UI
palette.
The runtime ships a small set of named themes; you can also write an
inline theme spec or load a custom module.

For the API see [`hollow.theme`](reference/lua/theme.md).
For UI colors used by widgets see
[Custom UI → Widget theming](custom-ui.md#widget-theming).
The full default widget-token list and bar-token sources are in the
[`hollow.ui` styles reference](reference/lua/ui.md#styles).

Widget palettes supply colors; internal component recipes decide when to use
them. Override `theme.ui.widgets.all` for shared values and a widget-kind table
for that kind. Per-instance styles are applied afterwards. The concrete
`button_emphasis_bg` token defaults to the existing dialog-button emphasis,
derived after widget overrides; explicit values win. Bar close-button part
colors accept the same widget/bar token namespace as ordinary bar paint.
Runtime theme changes invalidate cached palettes; component results are
recomputed from the current palette. Already-open built-in widgets refresh their
palette and default chrome while keeping explicit instance theme overrides.

Native component-part paints can be overridden through
`theme.ui.widgets.all.parts` or a widget-kind `parts` table. Sidebar surfaces,
raw tab fallback colors/selection stripes, list accents and scrollbars consume
these defaults. Their bundled values preserve the previous native appearance;
colors can also bind to existing tokens. Explicit instance styles remain final.
See [surface and native part paint](reference/lua/ui.md#surface-and-native-part-paint).

### Token and override ownership

- `theme.ui` owns application chrome and bar colors. Bar styles additionally
  expose these through their documented bar tokens.
- `theme.ui.widgets.all` supplies shared widget defaults; widget-kind palettes
  override those values. Existing tokens such as `panel_bg`, `selected_bg` and
  `primary_bg` describe colors, not component behavior.
- Recipes privately select colors for supported component states. Use public
  button variants/sizes and explicit row `selected`, not private recipe helpers.
- `parts` customizes separate paint parts without changing placement or hit
  targets. For example, `parts.list_row = { accent = "primary_bg" }` binds row
  accents to the palette's primary color. Inline styles and legacy paint aliases
  retain their documented final precedence.

- `styles` overrides built-in component slots, keyed by stylesheet then slot.
  It merges like `parts` (`widgets.all.styles`, then the widget kind):

  ```lua
  widgets = {
    all = { styles = { button = { root = { radius = 6 } } } },
    select = {
      styles = {
        select = { label = { fg = "title", selected = { bold = true } } },
        list_row = { paint = { selected = { fill_bg = "primary_bg" } } },
      },
    },
  }
  ```

  A slot layer may nest `variants`, `sizes` and the states `hovered`,
  `selected`, `pressed`, `focus_visible` and `disabled`. Each step applies the
  sheet's rule first, then the theme's, so a themed base color does not mask
  state colors. Call-site paint (status colors, workspace hashes, explicit
  `style` options) stays final. Unknown sheets, slots, variants and tokens raise.
  Sheets and slots are listed in `src/lua/hollow/ui/styles/`; the workspace
  switcher and bottom bar resolve against their derived palettes and read
  `widgets.select.styles` and `widgets.all.styles` respectively.

`selection_bg` / `selection_fg` color tabs and selectable-row recipes.
`selected_bg` / `selected_fg` are distinct tokens used by dialog-button emphasis;
they are not aliases. Set the pair appropriate to the control you are restyling.

For plugin-local reuse, compose plain style constants with `ui.style` or
`ui.styled`. No global recipe registration API is required. The
[styling example](../examples/ui-styling.lua) shows public composition and live
theme switching without copying theme-derivation code.

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
`theme.ui.widgets.all` and per-widget sections, and can be overridden per
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
