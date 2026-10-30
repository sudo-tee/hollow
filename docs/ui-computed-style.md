# Shared UI styling

The styling unification lives in one PR against `feat/declarative-ui`.
`ui.style` / `ui.styled` are the public merge/token helpers. There is no public
recipe registry or variants DSL.

## Style core

The style core lives in `src/lua/hollow/ui/style/`:

| Module | Owns |
| --- | --- |
| `box.lua` | One CSS-like box parser (`parse`, `normalize`, `px`). Spans keep fractions; surfaces pass `integer = true`. |
| `tokens.lua` | The single color-field list, dotted-token lookup, typo hints. |
| `sheet.lua` | Layer merging (`merge`, behind `ui.style`) and per-component stylesheets. |

Spans serialize through `shared.style_to_segment` with the flat span protocol:
`fg`, `bg`, `bold`, `border`, `border_size`, `radius`, `background_extend` and
normalized `padding`. Identity and callbacks stay on nodes, outside paint.

Colors use the strict token resolver, including dotted paths and typo hints.
`nil` means absent, never clear; false color overrides suppress earlier colors.
False boxes reset spacing to zero. Absent boxes stay absent. Constants,
palettes and caller style tables are not mutated.

## Stylesheets

A component's visual policy lives in a plain Lua table of named slots under
`src/lua/hollow/ui/styles/<component>.lua`. Slot colors are palette tokens.
Slots can nest state layers (`hovered`, `selected`, `pressed`,
`focus_visible`, `disabled`), `variants` and `sizes`:

```lua
local common = require("hollow.ui.styles.common")
local sheet = require("hollow.ui.style.sheet")

return sheet.define("select", {
  title = common.title,
  label = {
    fg = "fg",
    hovered = { fg = "hover_fg" },
    selected = { fg = "selection_fg" },
  },
})
```

Components bind a palette and props, then read slots:

```lua
local s = styles(theme, { selected = is_selected, hovered = is_hovered })
ui.text(label, s.label)                         -- memoized for this view
ui.span(name, ui.style(s.pill, { bg = colors.bg }))  -- dynamic hex color
```

Resolution order is base, variant, size, then each state in the order above
(base/variant/size layer of that state). Sheet tokens missing from a partial
palette resolve to nil, matching old optional-field reads. A palette is
required. `sheet:check(palette)` strictly validates every token; tests run it
against the bundled themes. `hollow.ui.styles` exposes the shared presets from
`styles/common.lua`.

Sheets hold tokens; call sites only layer concrete hex colors. Keep layout
math, node construction, dynamic colors (workspace hashes, program status) and
event handling in the component, and layer dynamic colors with
`ui.style(s.slot, { fg = hex })`. A token-based choice that depends on state
belongs in the sheet as a variant. `ui.styled(theme, ...)` is for plugins and
user-supplied styles that may carry tokens (e.g. `ui.button`'s `style`). Tokens accept `"a|b"` fallbacks for optional palette fields
(`"muted|fg"`), ending in a literal if needed (`"parts.scrollbar.track|#5a6375"`).
Palette values that are themselves tokens resolve again, so theme `parts` work
as tokens (`"parts.list_row.accent|panel_border"`); a `false` part suppresses
the color.

| Sheet | Used by |
| --- | --- |
| `button` | `ui.button` variants/sizes, `ui.action_button` (`root`), dialog buttons (`dialog`) |
| `tab` | `ui.tab` (`badged` variant) |
| `list_row` | built-in list rows (`paint` options, `indicator`, `section_indicator`), raw row `variant`s (`root`), shared `row_gap`/`section_gap` |
| `panel` | overlay chrome from `shared.theme_overlay_chrome` |
| `select`, `palette`, `mux_navigator`, `activity` | the matching widgets |
| `workspace`, `bottombar` | widgets resolving against their derived palettes |
| `topbar` | top-bar divider, new-tab button and attention button (bar palette; `attention` label against the select palette, `variant` = level) |
| `notify` | notification text (`variant` = level) |

Themes override slots through `palette.styles.<sheet>.<slot>` (from
`theme.ui.widgets.<kind>.styles`, see [themes](themes.md)). At each step
(base, variant, size, each state) the theme layer follows the sheet's; call-site
layers follow both. Theme sections are validated strictly the first time a
sheet resolves against a palette.

Partial dialog palettes lacking `button_emphasis_bg` get it derived in
`builder/components/dialog.lua` before resolving. Sheets compose through
`other.slots.<slot>` (e.g. `list_row.slots.section_gap`).

## Recipes and states

The `button`, `tab`, `list_row` and `panel` sheets own the shared component
recipes. Dialog buttons use the `dialog` slot; their existing colors and
geometry are retained. Select, palette, activity and mux-navigator rows share
`list_row`. Presets remain plain constants where that is simpler.

State order is base/variant/size, hovered, selected, pressed, focus-visible,
disabled, then explicit instance override. State comes from existing event or
model owners. Selection is never inferred from hover. Pressed/focus paint can
be resolved internally but no input states or public behavior are fabricated.
Disabled public buttons suppress callbacks and hover paint, including callbacks
registered by a previous enabled overlay render.

New `ui.button` variant/size options opt into the themed recipe; ordinary raw
buttons retain their original style behavior. `ui.action_button` always uses
the recipe and preserves legacy whole-padding-box replacement and
`hover_style` precedence. Tabs retain badge padding and background extension.

A selectable overlay row accepts explicit `selected` and a small `style`
contract: foreground, background, bold, radius and hover. Only foreground/bold
inherit into text. Row padding, border and other unsupported fields error rather
than silently promising geometry support. Existing segment padding remains the
way to size list-row content. Legacy `fill_bg`/`fill_radius` are final overrides;
selection accents remain separate parts. Sidebar rows now consume the same row
paint metadata for backgrounds, radii, accents and dividers. Their original
segment arrays and fixed row positioning are retained; hover routing and
scrollbar interaction remain owned by their existing surfaces.

Overlay `style` supplies surface values; explicitly present `chrome` fields
win, replacing whole padding/margin boxes as before. Bars and overlays share
surface pixel normalization and token rules. Bar close-button part colors also
accept tokens. Auto-generated bar IDs copy node styles before writing identity,
so shared styles cannot leak IDs or hover mutations between siblings.

## Native boundary and fallback inventory

The existing host records are retained and extended with optional paint data:

- Bar tab `fallback_style`: foreground/background and selection-accent colors.
  These remain separate from explicit style and segment paint, so a fallback
  background does not suppress the existing active selection stripe or alter
  padding, margins, radius, fitting or hit targets. Native cache resets clear
  fallback paint independently.
- Sidebar `style`: background, foreground, border and background alpha.
- Sidebar `row_styles`: row-paint records alongside the original `rows` segment
  arrays. Older consumers still read those original arrays. The same native row
  painter handles fill/radius/accent/divider for overlays and sidebars, using each
  surface's original row geometry.
- Overlay row `hover_bg` and explicit scrollbar colors: paint supplied by Lua.
  Native scroll/hit-region calculations are unchanged.

`normalize_surface_style` is the common flat surface boundary. Bar and chrome
adapters project their existing supported fields from it: chrome keeps alpha
and border size; bars keep text identity and close-button part fields. This
preserves their distinct host contracts without separate color/box rules.
`overlay_surface_style` owns compatibility precedence, including whole-box
replacement by explicit chrome, before projecting the normalized surface.

Palette `parts` holds concrete defaults that previously lived in native drawing:

```lua
theme = { ui = { widgets = { all = { parts = {
  sidebar = { bg = "panel_bg", fg = "fg", border = "panel_border", alpha = 235 },
  tab = {
    active = { bg = "tab_active_bg", fg = "tab_active_fg" },
    inactive = { bg = "tab_inactive_bg", fg = "tab_inactive_fg" },
    selection_accent = "accent",
  },
  scrollbar = { track = "scrollbar_track", thumb = "scrollbar_thumb" },
  list_row = { accent = "panel_border" },
} } } } }
```

These optional bindings opt into theme-derived colors. The bundled default
part values exactly match the old native paints across all four tested themes.
A widget-kind `parts` table overrides `widgets.all.parts`; explicit instance
paint and legacy row aliases win last. Parts and output snapshots are never
mutated by adapters. Theme changes invalidate palettes and therefore part paint.
Sidebar surface style exposes `fg`, `bg`, `border`, `alpha`; unsupported geometry
fields error. Sidebar width/reserve/side retain their existing units and behavior.

Built-in list recipes and selectable raw rows share part-color resolution.
`list_row.accent` also colors the built-in selection indicator; `false` disables
that accent. Scrollbar part overrides apply to both raw rows and built-in lists.
Without overrides, built-in lists retain their semantic `scrollbar_track` /
`scrollbar_thumb` colors. Raw rows retain the old literal track color and native
panel-border thumb fallback (including explicit chrome borders). This distinction
preserves existing visuals rather than imposing a new theme on either producer.

Intentional remaining UI fallbacks in `src/render/sokol_runtime.zig`:

| Area | Fallback ownership |
| --- | --- |
| `OVERLAY_HOVER_BG` | Old producers without row `hover_bg` |
| Overlay panel background, border, alpha and geometry | Raw overlays without chrome; built-in chrome comes from Lua recipes |
| Tab active/inactive colors and selection stripe | Old producers without `fallback_style`; new Lua sends palette part paint |
| Sidebar surface paint | Old producers without `style`; new Lua sends palette part paint |
| Segment default foreground | Unstyled spans; sidebar surface foreground can now supply it |
| Scrollbar track/thumb colors | Old/incomplete rows; new raw tracks get part paint and explicit aliases win |

Keeping these fallbacks preserves custom configs and older producers. Removing
all native defaults or replacing the protocol/layout engine is outside this
compatibility migration. Terminal VT styling remains separate.

## Verification and performance

Run with LuaJIT/Busted dependencies installed:

```sh
scripts/test-lua.sh
luajit scripts/bench-ui-style.lua
luajit scripts/bench-ui-style.lua --components
luajit scripts/bench-ui-style.lua --overlay
zig fmt --check src/render/sokol_runtime.zig
zig build test-lua
zig build test
```

Tests cover state precedence, input immutability, missing partial-theme fields,
button variants/sizes, disabled activation, row text/box separation, chrome
precedence, shared bar styles, runtime theme changes, and bar part tokens.
Presentation fixtures compare bar/chrome normalization, sidebar/overlay row
paint, component-part defaults, output immutability and theme invalidation. A
native test covers tab paint precedence, layout isolation and cache resets.
Additional fixtures cover explicit tab-close spans across bar/overlay hover and
leave, shared list accent/scrollbar overrides, partial palettes, and whole-box
chrome precedence. Close spans retain their existing IDs, text and padding.
Existing serialized fixtures cover tabs/dialogs/lists and action paint in both
bars and overlays. Four-theme parity fixtures cover Hollow, Kanagawa Wave,
Nord and Rose Pine.

The benchmark warms each path, reports the median of seven timed batches with
ordinary GC, and separately measures allocations with GC briefly stopped.
`--components` repeatedly builds an action, a badged tab and a list-row recipe,
and serializes their spans. It can run unchanged at pre-unification commit
`68709b3`. These are homogeneous Lua workloads, not native frame or input latency
measurements. No generic style cache was added; theme palettes already cache and
invalidate on theme changes. Open built-in widget palettes and default chrome
refresh in place through weakly held references, retaining explicit instance
overrides and allowing closed widgets to be collected.

`--overlay` measures actual Lua render plus overlay serialization for rows that
contain an action and a badged tab, with list-row paint and panel chrome. A
Linux x86-64 LuaJIT sample compared with `68709b3`:

| Rows | Baseline ms | Unified ms | Baseline bytes/row | Unified bytes/row |
| --- | ---: | ---: | ---: | ---: |
| 25 | 0.953 | 0.896 | 16336 | 16850 |
| 100 | 3.813 | 3.509 | 15895 | 16363 |
| 500 | 25.380 | 24.408 | 15770 | 16238 |

This sample shows similar render/serialization timings, with roughly 3% more
allocated bytes per row. Component-only groups used 13636 bytes before and
13720 after (about 0.6% more). Host scheduling and GC vary; these values do not
establish a universal tolerance or native frame-time claim.

Phase 4 adapter comparison against the preceding head (`75c083f`), using the
same `--overlay` workload sequentially on the same host:

| Rows | Before ms | Phase 4 ms | Before bytes/row | Phase 4 bytes/row |
| --- | ---: | ---: | ---: | ---: |
| 25 | 0.727 | 0.730 | 16802 | 16961 |
| 100 | 2.904 | 2.682 | 16363 | 16505 |
| 500 | 14.280 | 14.054 | 16238 | 16375 |

Allocation growth is under 1% per row in this sample. The same timing/GC caveats
apply. Native tests for Phase 4 code commit `01592d6` passed
[CI](https://github.com/sudo-tee/hollow/actions/runs/40853968458), including the tab
paint/layout/cache regression test. Release builds and agent checks are tracked
on the same PR; desktop visual acceptance remains separate.

GitHub CI for implementation commit `f898a9c` passed native/Lua tests
(`zig build test-all`), Linux and Windows builds, and agent conformance:
[Test](https://github.com/sudo-tee/hollow/actions/runs/40777176646),
[Build](https://github.com/sudo-tee/hollow/actions/runs/40777176397),
[Agent conformance](https://github.com/sudo-tee/hollow/actions/runs/40777176440).
This supersedes the local dependency-download blocker. Subsequent Lua-only
compatibility fixes have regression tests and run through the same PR checks.
Native screenshots/DPI/hit-region acceptance and complete native timing still
require a running desktop session.

The follow-up compatibility pass covers explicit `backdrop = false`, removing
and restoring theme-owned backdrops on open dialogs, retaining instance-owned
backdrops, and resolving child text tokens with a row's own partial palette on
both overlay and sidebar surfaces.

## Public customization handoff

The public authoring surface is existing `ui.style` / `ui.styled`, plain presets,
button variants/sizes/disabled, explicit row selection, palette tokens and
documented paint parts. Recipes, computed-style snapshots and host adapters stay
private; no registration API or general variants DSL is needed for built-in use.

See [Custom UI](custom-ui.md#customization-contract) for ownership and partial
palette rules, [Themes](themes.md#token-and-override-ownership) for token scope,
and the runnable [`examples/ui-styling.lua`](../examples/ui-styling.lua).
The example has regression tests for rendering, callbacks, theme refresh and
closing. Desktop visual behavior was confirmed by the maintainer; automated
native/DPI/performance acceptance remains separate from this documentation pass.

## Built-in authoring cleanup

Presentation normalization and widget-source migration are separate milestones.
The follow-up authoring pass covers workspace columns/domain pills and its bar
button, select detail rows, palette and mux rows, activity text/padding,
notifications, attention/new-tab buttons, special-mode bar chips, dialog titles,
and text-input/text-view rendering.

Conditional children use `ui.when`, repeated render lists use `ui.each`, and
repeated paint/geometry lives in module-level style constants or small named
style functions. State-dependent colors remain explicit conditional layers;
dynamic workspace/program colors are not forced into a new token vocabulary.
Optional colors on partial palettes are read directly where token lookup would
turn an existing native fallback into an error. Render-time resolution is kept
for live themes; extracted constants never capture a concrete theme at load time.

This is not a rule to replace every `if` or table. Data discovery, filtering,
tree flattening, viewport/column math, lifecycle/interaction branching and host
serialization retain ordinary algorithms. Local one-off color overrides passed
to `ui.style` / `ui.styled` are still supported and intentional. No public recipe
registry, new variants DSL, or native geometry rewrite is part of this pass.

## Typed component style boundaries

The project uses EmmyLua Rust for analysis. Workspace's palette, named style
slots, color callbacks and top-bar options now have explicit input/output types;
shared recipe/state/paint helpers also declare their contracts. Partial widget
overrides use `HollowUiTheme`; resolved defaults use `HollowUiResolvedTheme`.
`HollowStyleLayer` describes conditional layers, and `HollowStyleColor` includes
the supported false override. Spacing annotations include fractional pixels,
CSS-order arrays and false resets. Token completions list built-in names while
still allowing custom palette keys.

Per-component stylesheets are described in [Stylesheets](#stylesheets).
`attention` and `notify` keep one-line dynamic color helpers. Lua files under
`src/lua/hollow` are embedded automatically; see `src/lua_bridge.zig`.

Run `emmylua_check scripts/typecheck --warnings-as-errors` for focused authoring
fixtures. Repository-wide analysis still has unrelated existing diagnostics.
