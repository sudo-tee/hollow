# Hollow UI styling architecture — implementation plan

> Target: `feat/declarative-ui`
> Status: proposal / review first; this document changes no application code.
> Relationship: follow-up to `ui-styles-plan.md`, `ui-composition-plan.md`, and `ui-master-plan.md`. Do **not** redo the token/merge/hover work those plans already implemented.

## 0. Decision and objective

**Recommendation:** keep Hollow's declarative Lua widget API, build a small, centralized **computed-style + component-recipe layer** on top of the primitives already present, and have all widget surfaces consume the same resolved style contract. Avoid adding a CSS parser, selector engine, RmlUi, or a new layout engine as a prerequisite.

The goal is **fewer independently styled components and fewer inconsistent styling pipelines**—not more style syntax.

Desired developer experience:

```lua
ui.button({
  id = "run",
  text = "Run",
  variant = "primary",
  size = "sm",
  disabled = running,
  on_click = run,
})

ui.row({
  ui.text("Build results"),
}, {
  id = "result-row",
  selected = selected,
  variant = "selectable",
})
```

These are **proposed additions**, not current APIs. Raw `style = { ... }` remains supported for custom widgets and backwards compatibility.

### Explicit non-goals

- Do not touch `src/mux/layout.zig` or change the terminal pane layout model.
- Do not require Clay to ship this work. If Clay is adopted later, it consumes the same resolved layout properties.
- Do not port Hollow to RmlUi, CSS, HTML, or another widget runtime.
- Do not build a generic selector cascade, CSS-in-Lua DSL, reactive hooks, or an elaborate variant compiler.
- Do not rewrite keyboard navigation, text input, scrolling/virtualization, mouse routing, or the Sokol renderer just to introduce recipes.
- Do not automatically convert terminal-cell dimensions to pixels; preserve current bar/sidebar/overlay public sizing semantics during migration.
- Keep existing third-party Lua config and theme compatibility unless a specific breaking change is separately approved.

## 1. Current branch: what's already there

Verified in `feat/declarative-ui`:

| Existing implementation | Location | Keep / build upon |
| --- | --- | --- |
| `ui.style = shared.merge_styles` with box-aware merging | `src/lua/hollow/ui/primitives.lua`; `shared.lua` | Keep as basic composition primitive |
| Theme-color tokens, dotted paths, strict validation, palette caching | `shared.lua` | Keep; refine semantic token layer, not a new parser |
| `ui.styles` presets: muted, title, pill, badge, kbd | `primitives.lua` | Keep for low-level composition |
| `ui.styled(theme, ...)` | `primitives.lua` | Keep implementation; fix public naming discrepancy |
| Hover applied to identifiable bar/overlay spans | `shared.apply_hover`, `widgets/overlay.lua`, `widgets/bars/bar_events.lua` | Reuse; make node-state treatment consistent |
| Component-specific button styling | `builder/components/button.lua` | Migrate behind one recipe resolution path |
| Independent row decoration and selected/hovered handling | `widgets/list_style.lua`, `widgets/select.lua`, `widgets/palette.lua` | Primary consolidation target |
| Independent bar/style normalization | `widgets/bars/bar_serialize.lua` | Adapt to common computed style |
| Independent overlay chrome and row fields | `widgets/overlay.lua`; `src/render/sokol_runtime.zig` | Adapt without changing overlay lifecycle |
| Native hardcoded UI colors/geometry in renderer | `src/render/sokol_runtime.zig` | Move widget paint decisions into theme/recipe when appropriate |

**Actual inconsistency to resolve early:** `primitives.lua` exports `ui.styled(theme, ...)`, while `docs/reference/lua/ui.md` advertises `ui.themed_style(theme, ...)`. Confirm the public typed API in `types/hollow.lua` and settle on one canonical name, retaining a backwards-compatible alias if necessary.

The earlier `ui.variants` DSL was deliberately removed for being heavier than its call sites justified. Do **not** reintroduce it unchanged.

## 2. Target model: four separate responsibilities

1. **Theme / tokens** — user-defined colors and optional semantic aliases; no knowledge of a particular button's hover state.
2. **Component recipe** — appearance for a semantic control (`button`, `list_row`, `tab`, `dialog`, etc.), including default size and visual variants.
3. **State resolver** — combines hover, selected, pressed, focused, disabled consistently; state comes from existing UI event/selection logic.
4. **Computed style** — normalized, immutable-by-convention style snapshot sent to the current rendering adapter.

Keep *style* separate from *behavior*. A disabled style never substitutes for disabling click/keyboard activation.

Proposed data flow:

```text
theme spec + widget tokens
            |
     recipe + variant + size + current visual state
            |
       computed style
          /      \
 layout fields    paint/text fields
        |         |
 current layout    current Sokol drawing
 (Clay later?)     + hit-region geometry
```

Do not create a generic CSS-style selector or DOM tree. Only named recipes with opt-in variants and explicit state.

## 3. Computed style contract

Introduce one documented internal shape (names below are conceptual; implement within the existing Lua types and host protocol):

```lua
-- Illustrative, not yet a public type:
ComputedStyle = {
  layout = {
    padding = { top = 0, right = 0, bottom = 0, left = 0 },
    margin = { top = 0, right = 0, bottom = 0, left = 0 },
    -- Future: gap, min/max constraints when/if a real widget layout engine lands.
  },
  paint = {
    fg = "#...",
    bg = "#...",
    border = "#...",
    border_size = 1,
    radius = 4,
    bold = false,
  },
}
```

### Migration rule

**Do not immediately change the existing serialized Lua-to-Zig format.** First normalize styles into this conceptual representation in Lua, then adapt to the existing fields. Only consolidate the host serialization after visuals/tests prove equivalence.

Legacy mapping must be explicit:

| Existing API | Canonical meaning |
| --- | --- |
| Span `fg` / `bg` / `border` / `radius` | Text/paint of span node |
| Row `fill_bg` / `fill_radius` / `accent_bar` | Row paint and decoration |
| Overlay `chrome.bg` / `border` / `radius` / `padding` | Surface paint plus layout padding |
| Bar `style` and `layout`, including `margin`/`padding` | Surface paint plus layout |
| Selected/hovered colors computed in widget helpers | State-dependent recipe overrides |

Do not make `opacity`, shadow, border modes, or font variants part of the guaranteed schema until the Sokol path actually implements them. No silent unsupported style keys.

Treat row accents, scrollbar track/thumb, tab close buttons, and overlays as **component parts** where necessary. Avoid hiding these parts in text-span styles.

## 4. Recipes: start small and explicit

Use plain tables and the existing `ui.style(...)` merging semantics. Define a tiny **internal** resolver first (suggested location: existing `shared.lua` or a small module with proper `src/lua_bridge.zig` packaging registration).

A sketch:

```lua
local recipes = {
  button = {
    base = { fg = "fg", radius = 4, padding = { x = 8, y = 4 } },
    variants = {
      default = { bg = "panel_bg" },
      primary = { fg = "primary_fg", bg = "primary_bg" },
      ghost = {},
    },
    sizes = {
      sm = { padding = { x = 6, y = 2 } },
      md = { padding = { x = 8, y = 4 } },
    },
    states = {
      hovered = { bg = "hover_bg" },
      disabled = { fg = "muted" },
    },
  },
}
```

This describes mechanics only, **not finalized colors**. Real defaults must preserve the current theme-specific visuals.

Suggested internal call:

```lua
local style = resolve_component_style(
  "button",
  { variant = "primary", size = "sm" },
  { hovered = true, disabled = false },
  opts.style
)
```

Resolution order (explicit, covered by tests):

1. Base recipe.
2. Variant.
3. Size.
4. Hover.
5. Selected/active.
6. Pressed.
7. Disabled (highest-priority state; also suppresses interaction in widget logic).
8. Per-instance `opts.style` overrides last, for compatibility.

Focused visibility is **separate** from selection: prefer a focus outline/accent part instead of overwriting selection foreground/background. If state combinations require exceptions, add **small named recipe-specific overrides**, not a generic compound-variant DSL.

The engine must use the current `merge_styles` and token resolver, avoid mutating constants, and reject unknown variant names with a useful error in development. Avoid cloning shared tables repeatedly when nothing changes.

## 5. Theme semantics and customization

Preserve `theme.terminal`, `theme.ui`, `theme.ui.widgets.all`, per-widget palettes, and the existing `fg`/`muted`/`panel_bg`/... token vocabulary.

Phase in optional *semantic aliases* only where needed (for example, primary text, secondary text, panel background, subtle border, accent, hover surface). Resolve aliases back to existing palette values by default so all bundled themes continue working.

Do not multiply synonyms with no concrete usage. Prefer **roles** (text, surface, border, action) over direct color names.

Theme overrides should follow one predictable hierarchy:

```text
bundled theme defaults
  -> user theme.ui / theme.ui.widgets overrides
  -> component recipe
  -> component variant and interactive state
  -> explicit instance style
```

Theme tokens and recipe defaults are separate: a theme says what `primary_bg` is; the button recipe says *when* it is used.

For plugin authors, support per-instance `style` immediately. Defer registering global custom recipes or selector-like classes until there are real external plugin use cases.

## 6. Unify surface/state styling in small steps

### A. Span / low-level node styles

Keep `ui.text`, `ui.group`, `ui.style`, `ui.styles`. Preserve style inheritance and node click IDs. Normalize token resolution and color/box parsing once in shared utilities, rather than each surface inventing its own rules.

### B. Rows / list items (highest priority)

Introduce a canonical row visual style that covers background, radius, selection accent, text and hover. Make `list_style.row` consume this recipe rather than computing its own `fill_bg` and `accent_bar`.

- Migrate one representative selectable row in `widgets/select.lua`.
- Compare with `palette.lua` and `mux_navigator.lua`.
- Keep current `fill_bg`, `fill_radius`, `accent_bar` options as compatibility aliases; define precedence against `style` explicitly.
- Keep scroll/selection navigation and row budgets unchanged.

### C. Buttons and tabs

Move `builder/components/button.lua` and `ui.action_button` / `ui.tab` toward the same recipe convention. Distinguish semantic `variant` (primary/ghost/destructive) from visual `size` (sm/md).

Avoid two independent button pipelines. Preserve existing button IDs, hover callbacks, close-button affordances and old style override behavior.

### D. Overlay surface/chrome

Map `chrome` (panel background, border, radius, padding, margin) into a surface recipe, with the existing `chrome` object still accepted and taking precedence when explicitly provided. Keep placement, backdrop, stacked notifications, expiry and modal keys unchanged.

### E. Top/bottom bars and sidebars

Give bars/sidebar the same style normalization contract. Keep tab fitting/truncation and geometry special cases until layout work is separately approved. Remove duplicate color/style normalization only after confirming that the exact same appearance is produced.

### F. Native rendering

Inventory widget-specific hardcoded paints in `src/render/sokol_runtime.zig` (including fallback tab colors and overlay hover colors). Expose those as computed style values from the Lua/theme pipeline with host-side safe fallbacks. Do **not** move terminal VT styling into the UI recipe system.

## 7. Implementation sequence (reviewable PR-sized slices)

| Slice | Work | Primary files | Exit criteria |
| --- | --- | --- | --- |
| **P0 — Contract & regression baseline** | Fix `ui.styled`/`ui.themed_style` mismatch; document current precedence; capture snapshots for representative widgets | `primitives.lua`, `types/hollow.lua`, docs, tests | Existing visuals and Lua API unchanged; tests green |
| **P1 — Shared style resolver** | One normalization path, immutable merge semantics, cache invalidation, typed computed-style concept, legacy adapters | `shared.lua`, `test_ui_styles.lua` | Merge/override/token/state tests, no renderer changes |
| **P2 — Row style + states** | Central row recipe; selected/hover/disabled precedence; migrate select + palette + mux navigator incrementally | `widgets/list_style.lua`, `widgets/select.lua`, `widgets/palette.lua`, `widgets/mux_navigator.lua` | Row states match current behavior; one reusable recipe |
| **P3 — Buttons, tabs, surfaces** | Button/tab recipes, common variants/sizes, overlay surface recipe and compatibility | `primitives.lua`, `builder/components/button.lua`, `widgets/overlay.lua`, `builder/components/dialog.lua` | One style engine across controls; overlay callbacks unchanged |
| **P4 — Bar/sidebar/host adapter** | Consolidate serialization; remove repeated UI paint constants where safe | `widgets/bars/bar_serialize.lua`, `widgets/bars/bar_events.lua`, `widgets/bars/sidebar.lua`, `src/render/sokol_runtime.zig` | Identical rendering and hit boxes at multiple sizes |
| **P5 — Public API & docs** | Decide whether to expose `ui.resolve_style` / recipes; document variants, themes, override precedence and plugin examples | `types/hollow.lua`, `docs/custom-ui.md`, `docs/reference/lua/ui.md`, `docs/themes.md` | One documented, consistent authoring pattern |
| **P6 — Perf and diagnostics** | Instrument style merge/resolve work; add optional developer-only computed-style dump for a node | targeted Lua/Zig helpers, tests/bench scripts | No meaningful regression in frame, Lua allocations or hover latency |

Each slice must be reviewable and revertible. **Do not bundle P0–P6 into one PR.** No need to implement a new public DSL in P1; evaluate usability after P2/P3.

## 8. Testing and acceptance

Existing test entry points: `scripts/test-lua.sh` / `zig build test-lua`; apply `stylua --check` on touched Lua. Extend existing tests rather than duplicate coverage:

- `src/lua/tests/test_ui_styles.lua` — token resolution, merge order, box shorthands, immutability, legacy aliases, unknown variants.
- `test_ui_primitive_styles.lua` and `test_ui_builder_styles.lua` — buttons/tabs/selection states.
- `test_ui_overlay_hover.lua` and `test_ui_widget_styles.lua` — hover and overlay surface parity.
- `test_ui_bars.lua` and `test_ui_select.lua` / `test_ui_palette.lua` — bar and row/selection regressions.
- `test_ui_children.lua` / `test_ui_composition.lua` — declarative composition still works.

Visual acceptance checklist (ideally automated screenshot fixtures, otherwise reproducible manual captures):

- Themes: Hollow default, Kanagawa Wave, Nord, Rose Pine (plus one high-contrast theme if available).
- Surfaces: topbar, bottombar, sidebar, select popup, command palette, notification, confirm/input, future Lua-pane mock.
- States: normal, hover, selected, hover+selected, focused, disabled; missing optional tokens and partial widget theme.
- Sizes: small/large windows, high DPI, varying tab counts, long UTF-8 labels, clipping/scrollbars.
- Geometry: hit targets remain aligned with backgrounds and text.
- Dynamics: theme change immediately invalidates any cached computed styles; moving between widgets leaves no stale hover paint.

### Performance guardrails

- Do not resolve the full theme on every span or pointer movement; cache per theme generation and component/variant/size/state where useful.
- Prevent accidental mutation of shared preset/recipe tables or cross-widget style leakage.
- Avoid copying huge nested Lua style tables on every frame; prefer small, immutable-by-convention snapshots.
- Benchmark overhead with 10, 25, and 50 simultaneously instantiated widget trees (even if not all visible); measure Lua allocations, style-resolution time and redraw cost.
- If the resolver introduces meaningful overhead, optimize *after* profiling before adding an elaborate generic cache.

## 9. Libraries / future layout integration

**No new library is required** to complete this plan.

- **Clay:** layout geometry only. If adopted, map computed `layout` fields into Clay and computed `paint`/text fields into Sokol; recipes remain independent of the layout engine.
- **RmlUi:** separate research spike only if fully CSS-like styling/controls become an explicit goal. The cost of a second UI runtime, C++ integration and Lua adapter must be compared against the recipe approach. Do not hold this styling cleanup hostage to that decision.
- **LibCSS / other CSS parsers:** out of scope; parsing and cascading alone would not solve mapping selectors to Hollow's existing Lua nodes/host rendering.

## 10. Risk register

| Risk | Mitigation |
| --- | --- |
| User themes or plugin styles silently change | Strict compatibility defaults, snapshots and theme matrix; explicit style precedence |
| Mutable style tables leak between instances | `merge_styles` always returns a fresh table; test hover/selection across siblings |
| UI host and Lua disagree on style | Normalize once; keep old serialization adapter until visuals match |
| Hover/selected/focused become conflated | Document state precedence; separate focus treatment; test combinations |
| Style metadata becomes another DSL | Keep recipes private and table-based; add only variants used by built-in components |
| Renderer gains unsupported properties | Track and reject/defer unsupported paint fields rather than silently accepting them |
| Theme caching causes stale colors | Theme generation key + explicit invalidation tests |
| Increased plugin breaking changes | Retain raw `style`, `chrome`, row fields and existing callbacks until a versioned deprecation plan |

## 11. Definition of done

The styling work is successful when:

1. A normal component author can choose **component + variant + size + state** without reconstructing color/padding/hover logic each time.
2. Custom Lua widgets can still use simple raw style tables and current theme tokens.
3. Rows, bars, overlays and widgets resolve shared tokens/paint consistently, with explicit legacy adapters.
4. Selection, hover and keyboard focus are visually distinct and behave consistently.
5. Bundled themes and the existing Lua API render as before unless intentionally adjusted.
6. Native UI color fallbacks are intentional and documented, not silently competing with Lua theme definitions.
7. Styling remains a **small Hollow subsystem**, independent of terminal mux layout and of any eventual Clay/RmlUi decision.

## 12. Immediate next task

Start with **P0 + a focused P1 prototype**, not a cross-cutting rewrite:

- Fix and test the `ui.styled` versus `ui.themed_style` public mismatch.
- Specify the normalized style/legacy adapter contract using *one* selected row and *one* action button as fixtures.
- Implement a pure Lua resolver in a private helper and verify all current tests and screenshots remain unchanged.
- Stop and review the real API/code-size tradeoff before migrating additional widgets.

**Review gate:** if P1 adds more complexity than it removes for these two representative controls, simplify the design or keep only centralized style normalization instead of proceeding to a general recipe system.
