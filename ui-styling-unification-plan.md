# Hollow UI styling unification plan

**Target:** `feat/declarative-ui`
**Status:** proposed / not implemented
**Scope:** Lua widget styling, theme resolution, interaction states, the Lua-to-Zig presentation contract, and future Lua-view reuse.
**Companion plans:** `ui-master-plan.md`, `ui-styles-plan.md`, `ui-composition-plan.md`.
**Out of scope:** changes to the mux split tree, terminal cell styling, and choosing a layout engine.

> This is a follow-up plan, not a replacement for `ui-styles-plan.md`. That plan introduced tokens, merging, presets, and hover for spans. Reuse that work. The remaining problem is consistency across components and surfaces.

## 1. Why this work is needed

Styling is currently distributed between several independently interpreted shapes and render paths:

- `src/lua/hollow/ui/primitives.lua`: `ui.style`, `ui.styles`, `ui.styled`, span/button/tab style tables.
- `src/lua/hollow/ui/shared.lua`: theme-token resolution, merging, palette caches, inherited span styles, hover application, serialization.
- `src/lua/hollow/ui/widgets/list_style.lua`: special-case selection/hover logic and row-specific presentation.
- `src/lua/hollow/ui/builder/components/button.lua`: another button-state styling policy.
- `src/lua/hollow/ui/widgets/overlay.lua`: separate `chrome` properties, row fields and per-overlay hover tracking.
- `src/lua/hollow/ui/widgets/bars/bar_serialize.lua` and `bar_events.lua`: separate bar style/hover serialization and handler assignment.
- `src/render/sokol_runtime.zig`: native bar, overlay and sidebar rendering with hardcoded fallbacks, radii, dimensions, and colors.

A span uses `style.bg` / `style.radius`; a row uses `fill_bg` / `fill_radius` / `accent_bar`; an overlay has `chrome`; a bar has its own `BarStyle`. This makes similar components look different even when using the same theme.

**Success condition:** building or restyling a widget generally requires selecting a component role, variant, state, and a few overrides—not manually deriving colors, padding and hover behavior in every render function.

## 2. Keep these existing investments

These are already present on `feat/declarative-ui` and should be preserved:

- Theme palette + widget-specific overrides through `hollow.theme`.
- Color tokens with dotted paths, error messages and suggestions for unknown tokens.
- `ui.style(...)` for immutable, box-aware layer merging.
- `ui.styles` presets (`muted`, `title`, `pill`, `badge`, `kbd`).
- `shared.apply_hover` for identified spans in bars and overlays.
- Declarative composition helpers (`ui.when`, `ui.each`, `ui.join`).
- Existing custom `opts.theme` and `opts.style` options.
- Existing Lua widget lifecycle, keyboard navigation, callbacks, and Sokol rendering.

**Naming cleanup:** `primitives.lua` defines `ui.styled(theme, ...)` while `docs/reference/lua/ui.md` advertises `ui.themed_style(theme, ...)`. Pick one canonical name, retain an alias during migration, and update LuaLS types/tests/docs.

**Existing design decision to retain:** `ui-styles-plan.md` intentionally removed a public `ui.variants` DSL as too complex for its call sites. This proposal does **not** reintroduce that API. Component recipes should start as small, internal Lua tables/functions.

## 3. Desired architecture

`Lua widget declaration`
  -> `component/variant/size/state resolution`
  -> `theme-token resolution + inherited styles`
  -> `one normalized computed style per node`
  -> `layout geometry + Sokol painting`

The computed style is independent of any layout-engine choice. If Clay is later adopted, box/spacing fields can feed Clay and visual fields can feed Sokol; if Clay is not adopted, the current native layout continues to work.

There are **three distinct responsibilities**:

1. **Theme:** supplies colors and app-level design tokens; the same terminal theme may derive a default UI palette.
2. **Recipe:** specifies how a component role (button, tab, list row, badge, panel) looks in each variant and state.
3. **Resolver:** merges recipes, user overrides, inherited properties and tokens into a stable, renderer-friendly result.

A layout engine is *not* a style engine; avoid mixing these responsibilities.

### 3.1 Public style syntax: incremental, not CSS

Keep plain Lua tables. Eventually a caller could write (illustrative; not yet implemented):

```lua
ui.button({
  id = "apply",
  text = "Apply",
  variant = "primary",
  size = "sm",
  disabled = busy,
  on_click = apply,
  style = { padding = { x = 10 } }, -- optional override
})
```

The caller should not need to manually select `hover_bg`, calculate pressed-state colors, or duplicate radius/spacing across widgets.

Keep current shorthand and explicit style tables valid. No class selector language, no runtime CSS parsing, and no mandatory new dependency.

### 3.2 Component recipes (internal first)

Define small tables/functions for:

- `button`: `default`, `primary`, `destructive`; later `ghost` if useful.
- `tab`: inactive, active, hovered, close-button hover.
- `list_row`: normal, hovered, selected, disabled, with optional indicator/accent.
- `badge` and `kbd`: semantic variants.
- `panel` / `dialog`: common surface background, border, radius, spacing and title styling.
- `input`: normal, focused, disabled, invalid (only when interaction support exists).

Proposed *internal* recipe shape (subject to tests, not a public DSL):

```lua
local button = {
  base = { fg = "fg", radius = 4, padding = { x = 8, y = 3 } },
  variants = {
    default = {},
    primary = { fg = "primary_fg", bg = "primary_bg" },
    destructive = { fg = "destructive_fg", bg = "destructive_bg" },
  },
  sizes = {
    sm = { padding = { x = 6, y = 2 } },
    md = { padding = { x = 8, y = 3 } },
  },
  states = {
    hover = { bg = "hover_bg" },
    selected = { bg = "selected_bg", fg = "selected_fg" },
    -- pressed / focus / disabled should be added only with real state data
  },
}
```

A private `resolve_component_style(kind, variant, size, state, override, palette)` applies the layers. Do not ship a general public `ui.recipe` / `ui.class` / `ui.variants` API until several built-in components actually justify it.

### 3.3 Explicit state contract

Use one state model when a widget supports the corresponding behavior:

`hovered`, `selected`, `pressed`, `focused`, `focus_visible`, `disabled`.

- `hovered`: pointer is over the target; distinct from keyboard focus.
- `selected`: persistent model choice, e.g. active tab or highlighted list item.
- `pressed`: button-down interaction, not synonymous with selected.
- `focused` / `focus_visible`: input/keyboard focus; don't invent it from hover.
- `disabled`: blocks interaction as well as changing appearance.

**Proposed deterministic layer priority:** base -> variant -> size -> hovered -> selected -> pressed -> focus-visible -> disabled -> explicit per-instance override. Document collision handling. Focus should preferably add an outline/accent without overwriting the selected background. Only compute states that existing event/input code can actually supply; do not fake pressed or focused in the first PR.

Compatibility: existing `style.hover` must continue working. First unify state lookup internally; extend user-facing state syntax only after widget behavior is consistent.

### 3.4 One computed-style vocabulary

Retain current Lua style fields at the public boundary. Normalize internally to one renderer-facing presentation model, roughly:

```lua
{
  text = { fg = "#...", bold = false, italic = false },
  box = { bg = "#...", border = "#...", border_size = 1, radius = 4 },
  layout = {
    padding = { top = 0, right = 0, bottom = 0, left = 0 },
    margin = { top = 0, right = 0, bottom = 0, left = 0 },
  },
}
```

This is an **internal example**, not a required wholesale Lua API change. Row properties (`fill_bg` / `fill_radius` / `accent_bar`) and overlay `chrome` should initially normalize *into* this model through compatibility adapters.

Do not casually fold interaction callbacks, node identity, scroll state or accessibility semantics into the visual style. Keep them separate. A style object should be shareable and immutable.

### 3.5 Theme tokens and ownership

Prefer existing canonical widget tokens (`fg`, `muted`, `panel_bg`, `panel_border`, `selected_bg`, `hover_bg`, etc.) over introducing a second color vocabulary prematurely.

Use this resolution order for colors:

1. Resolve the current theme's `widgets.all` defaults.
2. Layer the widget-kind palette, if applicable.
3. Resolve the component's base + variant + state recipe.
4. Apply explicitly passed local styles, preserving the current `opts.theme` override semantics.
5. Convert token colors to concrete values **once**, close to the style boundary.

Document how bar-specific tokens fit this order, since `shared.bar_palette()` currently merges extra bar names into the widget palette.

Avoid implicit derivation of styling colors inside render functions. If a derived color is needed, create it in theme resolution and expose it as a semantic token. Existing computed fallbacks can be migrated incrementally.

### 3.6 Inheritance vs local state

Only inherit suitable text properties (`fg`, font weight/style if intended) from parent containers. Do **not** automatically inherit box backgrounds, margins, padding, border, radius, hover, selection or callbacks.

Keep existing `ui.group` style inheritance compatible. Add tests for nested groups, explicit child overrides and mixed text colors. Never mutate a shared preset or theme table when assigning an auto-generated interaction ID.

## 4. Concrete migration strategy

### Phase 0 — Freeze semantics and baseline (no behavior changes)

**Files:** `ui-master-plan.md` / tests, `docs/reference/lua/ui.md`, `src/lua/hollow/ui/primitives.lua`.

- Confirm current test baseline and screenshots for top/bottom bars, sidebar, picker, dialog, notification, palette, and selected/hover states.
- Resolve `ui.styled` vs `ui.themed_style` naming; implement alias and tests, document canonical name.
- List all style-related hardcoded values in Lua and native Zig before refactoring them.
- Record basic timings/allocations for render and serialization, not only GPU frame time.

**Done when:** no visual behavior changes; all existing tests pass; baseline artifacts and naming are documented.

### Phase 1 — Pure computed-style resolver

**Files:** `src/lua/hollow/ui/shared.lua`, `primitives.lua`, `types/hollow.lua`, tests.

- Implement a single pure resolver around existing `merge_styles` / `resolve_tokens`.
- Define precedence and inheritance without a CSS-style cascade.
- Keep the public style syntax unchanged; normalize padding/margin once and return fresh/immutable-by-convention results.
- Resolve theme tokens under a supplied palette, respecting user-provided partial themes.
- Ensure `nil` / missing / explicit overrides have precise semantics; don't assume Lua `nil` can mean both "unset" and "clear".
- Share test fixtures between span, row, and panel normalization.

**Done when:** existing style calls render equivalently; both bar and overlay serialization can consume resolved styles with no extra ad hoc palette resolution.

### Phase 2 — Small component recipes

**Files:** `src/lua/hollow/ui/primitives.lua`, `widgets/list_style.lua`, `builder/components/button.lua`, `builder/components/dialog.lua`, related tests.

- Start with a button recipe and **one** list-row recipe. Compare their current behavior side-by-side.
- Migrate `ui.action_button` and dialog buttons without breaking `kind` / `hover_style` / `opts.theme` compatibility.
- Replace manually derived selected/hover colors in `list_style.lua` with the shared recipe resolver.
- Migrate `ui.tab` and `ui.tab_bar` after their current badge and close-button behavior is protected by tests.
- Migrate `ui.styles` presets to reference recipe defaults only where that improves consistency; don't remove the presets.

**Done when:** button, tab and list-row styling comes from one mechanism; existing built-in widget screenshots remain consistent.

### Phase 3 — Interaction state parity across surfaces

**Files:** `src/lua/hollow/ui/widgets/overlay.lua`, `widgets/bars/bar_events.lua`, `shared.lua`, `widgets/core.lua`; potentially `src/render/sokol_runtime.zig` for missing events.

- Keep stable IDs and existing Lua callback dispatch.
- Route hover through one state lookup for spans and rows; no widget-local comparisons for visual styling.
- Add selected support where the widget supplies a selected model state.
- Add pressed, focused, focus-visible and disabled only alongside actual input/event semantics.
- Define interaction priority and update invalidation on state changes. Preserve mouse-enter/leave and keyboard-navigation behavior.
- Fix any auto-ID code that mutates a shared style preset.

**Done when:** a selected or hovered component looks the same in bars, overlays and lists for the same recipe; disabled components cannot be activated.

### Phase 4 — Normalize the native presentation boundary

**Files:** `src/lua/hollow/ui/widgets/bars/bar_serialize.lua`, `widgets/overlay.lua`, `widgets/bars/sidebar.lua`, `src/ui/bar.zig`, `src/render/sokol_runtime.zig`, relevant bridge code.

- Introduce a versionable internal style representation at the existing Lua-to-Zig boundary.
- Gradually map row `fill_*` fields and overlay `chrome` into the normalized presentation style without removing legacy inputs.
- Replace scattered native default colors and radii with computed styles or centrally owned fallbacks. Separate *placement* math from painting.
- Ensure clickable/semantic bounds use the same final visual geometry where possible.
- Do **not** rewrite pane layout, hit-testing/focus semantics, or text shaping as part of this phase.
- Keep allocations bounded and preserve caching for unchanged widget trees.

**Done when:** bars, sidebars and overlays have one consistent paint-style consumption path, with no visual regressions and no measurable frame-time regression outside the agreed benchmark tolerance.

### Phase 5 — Theming and plugin ergonomics

**Files:** `src/lua/hollow/theme.lua`, `docs/themes.md`, `docs/custom-ui.md`, `types/hollow.lua`, tests/examples.

- Document which tokens belong to the global theme vs widget kind vs component recipe.
- Expose a small, stable way for user plugins to override component recipes or their theme tokens **only after** built-in use cases stabilize.
- Support runtime theme switching and proper style-cache invalidation.
- Add examples showing buttons, tabs, lists and panels with minimal inline styles.
- Provide LuaLS autocomplete for variants, sizes and states that are truly public.
- Keep custom inline colors and fully custom widgets possible.

**Done when:** a new Lua widget can match Hollow's native visual language without copying its theme-derivation code.

### Phase 6 — Optional developer inspection

Not a prerequisite for the MVP:

- Add opt-in debug logging or an inspector for a node's resolved style.
- Show component/variant/state, winning token, override source, final color and final geometry.
- Optionally produce a small screenshot/style snapshot gallery for built-in themes.

**Done when:** style bugs can be diagnosed without tracing several serializers and native render functions.

## 5. Recommended PR order

1. **PR 1:** naming reconciliation, baseline snapshots and tests (Phase 0).
2. **PR 2:** pure style resolver and normalization tests (Phase 1).
3. **PR 3:** button and list-row recipes (first half of Phase 2).
4. **PR 4:** tabs, dialogs and widget migrations (rest of Phase 2).
5. **PR 5:** hover/selection state parity and real input states (Phase 3).
6. **PR 6:** native style boundary, incrementally by surface (Phase 4).
7. **PR 7:** public theming docs and extension API, if justified (Phase 5).

Each PR should be reviewable and independently green. Keep layout-engine adoption as a separate experimental branch/PR.

## 6. Verification matrix

Test across surfaces (`topbar`, `bottombar`, `sidebar`, `overlay`, future `lua-pane`) and states (`normal`, `hover`, `selected`, `focus`, `disabled` when supported):

- Token resolution: global theme, per-widget theme, explicit override, unknown token hints, runtime switching.
- Style layering: base/variant/size/state/inline precedence, nested padding/hover, no mutation of reused style tables.
- Text inheritance: parent foreground vs child override; no accidental inheritance of padding/bg/events.
- Components: regular/primary/destructive buttons; selected/hovered list rows; tab badges and close buttons; dialogs; notifications.
- Interaction: clickable regions align with painted bounds; stable IDs; no click on disabled; hover transitions and keyboard focus remain correct.
- Visual: render snapshots for at least the built-in Hollow theme and a high-contrast second theme.
- Performance: compare current and proposed implementation for ~25/~100/~500 UI nodes, including Lua render time, style resolve time, serialization, allocations, native layout and draw time. Establish tolerance from baseline rather than inventing a universal budget.
- Resilience: theme changes, overlays opening/closing, sidebar resizing, varying DPI, UTF-8 and long labels.

Run at minimum:

```sh
zig build test-lua
zig build test
stylua --check <touched-lua-files>
```

If a target differs on the current platform, record the actual command and status. Update LuaLS annotations and docs with each public API change.

## 7. Risks and explicit non-goals

- **No public CSS parser/selectors/cascade for MVP.** RmlUi or LibCSS would be a separate architectural experiment, not a dependency of this plan.
- **No public general variants DSL until warranted.** An internal table-driven recipe resolver is enough for a handful of components.
- **No blanket style recomputation per GPU frame.** Reuse cached theme/recipe results and dirty-state invalidation, but measure first.
- **Do not mix style with behavior.** The style layer cannot substitute for keyboard focus, input, accessibility, or selection ownership.
- **No forced merge with the mux split tree.** The same style engine may later serve Lua panes, but pane geometry remains in `src/mux/layout.zig`.
- **No premature renderer rewrite.** Draw through existing Sokol/FreeType/HarfBuzz infrastructure.
- **No breaking config change without compatibility adapters.** Existing `style`, `chrome`, `fill_*`, `opts.theme` and token names continue working while new internal representation is adopted.

## 8. First implementation slice (suggested)

The smallest convincing proof is **one button plus one selectable list row**, used in both an overlay and a bar.

Deliver:

1. Shared recipe resolver with explicit precedence and token resolution.
2. Stable component state propagation (normal/hover/selected; other states later).
3. Same background, border, radius and padding on both surfaces.
4. Before/after screenshot diff and Lua/native timing comparison.
5. No changes to the mux, Clay integration, or public plugin APIs.

If this does not materially reduce special-case style code or improve visual consistency, stop and reconsider before undertaking the Zig serialization refactor.

---

**Implementation note:** On this branch `src/lua_bridge.zig` has an explicit embedded-Lua module registry. If a new Lua source module is introduced, register it there; otherwise start within existing modules to keep the first PR small.
