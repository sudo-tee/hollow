# Shared UI styling

The styling unification lives in one PR against `feat/declarative-ui`.
`ui.styled` is the canonical public merge/token helper; `ui.themed_style` is a
compatibility alias. There is no public recipe registry or variants DSL.

## Flat computed style

The initial nested `text`/`box`/`layout` prototype added copying and allocation
cost. The implementation instead uses a flat internal visual contract matching
the existing span protocol: `fg`, `bg`, `bold`, `border`, `border_size`, `radius`,
`background_extend`, and normalized `padding`. Pure snapshots can also contain
`margin`; the span adapter omits that field because spans have no margin.

`shared.compute_style(palette, ...)` merges explicit layers and returns a fresh
visual snapshot. It reuses the same normalization function as live
`style_to_segment`; that serializer writes directly into its final output, with
no intermediate snapshot. Identity and callbacks stay on nodes, outside paint.
`computed_style_to_segment` copies snapshots before attaching text and identity.
These are private helpers, also useful for inspecting styles in Lua tests.

Colors use the existing strict token resolver, including dotted paths and typo
hints. A supplied partial palette is authoritative: explicit unknown tokens
error. Recipe defaults read optional palette fields directly so missing optional
colors preserve legacy behavior. `nil` means absent, never clear; false color
overrides suppress earlier colors. False boxes reset spacing to zero. Absent
boxes stay absent. Constants, palettes and caller style tables are not mutated.

Span padding retains fractions. Bar/chrome pixel dimensions floor values and
clamp negative or non-finite input through one shared surface normalizer.
Their existing sizing units, hit geometry and truncation rules are unchanged.

## Recipes and states

Private `shared.resolve_component_style` owns button, tab, list-row and panel
recipes. Dialog buttons and action buttons use the same button recipe with
legacy presentation defaults; their existing colors and geometry are retained.
Select, palette and mux-navigator rows share the list-row recipe. Panel chrome
uses the panel recipe. Presets remain plain constants where that is simpler.

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
selection accents remain separate parts. Sidebar rows share text normalization;
their existing text-only host representation does not gain overlay row boxes.

Overlay `style` supplies surface values; explicitly present `chrome` fields
win, replacing whole padding/margin boxes as before. Bars and overlays share
surface pixel normalization and token rules. Bar close-button part colors also
accept tokens. Auto-generated bar IDs copy node styles before writing identity,
so shared styles cannot leak IDs or hover mutations between siblings.

## Native boundary and fallback inventory

The host schema is retained, with one additive optional row field: `hover_bg`.
Lua supplies widget-palette hover paint; native code uses it and keeps the old
fallback for older or incomplete producers. Native placement and hit-region
math are untouched.

Intentional remaining UI fallbacks in `src/render/sokol_runtime.zig`:

| Area | Fallback ownership |
| --- | --- |
| `OVERLAY_HOVER_BG` | Old producers without row `hover_bg`; new Lua rows supply palette paint |
| Overlay panel background, border, alpha and geometry | Raw overlays without chrome; built-in modal/notification/picker chrome is supplied by Lua recipes |
| Tab active/inactive colors and selection stripe | Raw bar tabs without explicit paint; existing configured bars retain their supplied theme styles |
| Segment/sidebar default foreground | Spans that omit foreground; explicit colors/tokens win |
| Scrollbar track/thumb colors | Incomplete rows; built-in list rows supply palette colors |

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
