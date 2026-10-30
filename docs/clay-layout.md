# Experimental Clay layout

Command palette, workspace picker, mux navigator and activity picker use Clay by
default, including workspace create/rename inputs. Existing shortcuts and
configuration need no changes.
Mux geometry, terminal rendering and bars retain their current implementation.
Direct confirmation, input and select APIs remain opt-in, keeping their overlay
shell and keyboard behavior.

## Test normal workflows

Rebuild and restart the normal application, then use your existing command palette
and workspace-picker shortcuts. Test filtering, category collapse, keyboard/wheel
navigation, clicking commands, workspace switching and Ctrl-R/Ctrl-N rename/create.
Custom themes, workspace column settings and `format_item` remain supported.
Use the usual mux navigator and activity shortcuts to test tree/category collapse,
search, attention filters, inbox/history switching, detail views and actions.

To compare or fall back globally, add this to your configuration:

```lua
hollow.ui.layout.configure({ backend = "legacy" })
```

`backend = "auto"` restores widget-specific defaults; `"clay"` opts all supported
dialogs in. Explicit per-call `layout = "legacy"` or `"clay"` wins over this setting.
Changes apply to subsequently opened dialogs. Workspace switcher options, including
`layout`, retain their existing persistent `workspace.configure`/`open_switcher`
behavior. Native caches are reset when configuration reload replaces the Lua runtime.
Full rendering performance parity has not yet been benchmarked. A reproducible
[Lua-only picker baseline](renderer-bench.md#picker-lua-snapshot-benchmark)
compares event handling and snapshot/serialization costs without native layout
or drawing.
A separate [Lua memory baseline](renderer-bench.md#picker-lua-memory-baseline)
measures heap retention and uncollected growth; native/GPU memory is not included.

## Try it

Build Windows GUI from WSL, then launch a separate demo window:

```sh
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast
./launch.sh --no-build --app-arg=--config \
  --app-arg="$(wslpath -w "$PWD/examples/clay-layout.lua")"
```

For native Linux, use `zig build run -- --config examples/clay-layout.lua`
(requires the normal Linux GUI build dependencies).

The demo contains nested columns inside a row, wrapped text, buttons using
Hollow's existing style recipes, a scrollable task list, and custom-painted
progress bars. Resize the window, scroll over the list, and click the counter.
Close or Escape dismisses the experimental surface; close the window afterward.

An existing configuration can bind `hollow.ui.layout.demo` to an action instead.
The running executable must include the new native adapter; Lua-only reload is
not sufficient when upgrading from an older binary.

## Confirmation dialog comparison

Launch `examples/clay-confirm.lua` with the same command (replace the example
filename), or add this call to an existing configuration/action:

```lua
hollow.ui.confirm.open({
  layout = "clay",
  title = "Delete file?",
  prompt = "This action cannot be undone.",
  on_confirm = function(value) hollow.log("Confirmed:", value) end,
  on_cancel = function() hollow.log("Cancelled") end,
})
```

Omit `layout` for the original confirmation renderer under the default `auto`
policy, or explicitly set `layout = "legacy"`.

Tab/arrow navigation, Enter, Escape, custom button values, callback ordering,
modal ownership and overlay cleanup use the existing implementations. The Clay
branch bypasses legacy row serialization and the panel/row geometry loop.
Namespaced dialog/button IDs and Clay-calculated bounds populate existing overlay
hit regions and CLI semantic nodes. Width/height retain confirmation-dialog cell
units; alignment and sizing are calculated by Clay inside the host content rect.

## Text-input dialogs

`hollow.ui.input.open` also accepts `layout = "clay"`. Run
`examples/clay-input.lua` to try a deliberately long default value, arrow-key
editing, Backspace, Enter and Escape. Omit the flag for the legacy renderer.

```lua
hollow.ui.input.open({
  layout = "clay",
  prompt = "Rename workspace",
  default = "tasks",
  width = 50,
  on_confirm = function(value) hollow.log(value) end,
})
```

Editing stays in the existing `ui.text_input` behavior. Clay lays out the input
background, styled text runs and block caret as ordinary containers/text, not an
opaque custom widget. The input viewport scrolls horizontally to keep the caret
visible. It uses actual Clay bounds, with a second layout pass only when the
reveal offset changes, instead of a Lua character-budget calculation.

This does not add a new editor: byte-offset cursor behavior, keyboard coverage,
paste/IME support and pointer-based caret positioning retain existing behavior
and limitations. Generic text selection/editing is outside the layout adapter.

## Selectable lists

`hollow.ui.select.open({ layout = "clay", ... })` reuses the existing fuzzy/plain
ranking, query input, custom search text, action chords, cancellation and list
navigation. `examples/clay-select.lua` demonstrates styled labels, optional detail
lines, a long clipped label, wheel scrolling and action hints.

Clay owns the pixel viewport and selected-row reveal. Native viewport dimensions
feed back into page/wheel capacity after layout. Wheel scrolling keeps selection
when it remains visible, using the existing navigation state, and aligns the new
first visible row. Keyboard navigation resumes nearest-edge selected-row reveal.
Only painted portions of rows enter hit testing and CLI `listitem` semantics;
clipped rows cannot be activated through the published bounds.

The prototype builds a window of at most 24 entries around the logical viewport,
not the entire result set. All entries remain searchable and reachable with
Home/End and navigation. Column-based labels use a conservative 23-entry window.
To stay inside the 512-node arena, the farthest overscan rows simplify first when
the combined row budget exceeds 410 nodes; very fragmented hint/label lines also
simplify. Normal styled runs and nested `ui.button` callbacks are preserved.
Panel height remains bounded. Clay pickers use the existing overlay scrollbar
paint and pointer-drag routing, with logical full-list thumb ratios rather than
ratios for the small native overscan window. Actions continue to decide whether
to close the select themselves.

Static item tables keep cached snapshots. Generic callable select sources retain
their existing per-frame behavior, so their providers and label/detail functions
must stay inexpensive. Builtin workspace, mux navigator and activity snapshots
instead invalidate on model events, input, theme/font/viewport changes, or timed
spinner/age updates. Empty/static lists do not schedule periodic refreshes.
Workspace status/bells refresh without rescanning discovery sources; completed
host scans and explicit workspace configuration/cache changes invalidate the list.
Custom workspace formatters retain live rendering. Its default formatter uses native columns;
custom `format_item` output still uses the rich inline adapter. Advanced select
components can supply `layout_label(item, ctx, view)` to return a native label tree
or nil to use the existing label; the ordinary label remains required for semantic
text and default search behavior. `view.id` supplies a stable row-local ID prefix.

## Components are functions

`hollow.ui.layout` is an experimental namespace, deliberately separate from
legacy `ui.row` / `ui.column`, whose flattening behavior is unchanged.

```lua
local layout = hollow.ui.layout

local function Card(title, body)
  return layout.column({
    layout.text(title, { bold = true }),
    layout.text(body),
  }, {
    width = "grow",
    padding = 16,
    gap = 8,
    style = { bg = "#242b38", radius = 6 },
  })
end

layout.show(layout.row({
  Card("One", "A composed Lua component."),
  Card("Two", "Clay owns the child placement."),
}, { width = "grow", height = "grow", padding = 24, gap = 16 }))
```

- `row(children, opts)` / `column(children, opts)` preserve container hierarchy.
  Fragments, holes and boolean children are accepted.
- Width/height accept `"fit"` (default), `"grow"`, or a positive pixel count.
- Options: `id`, `padding`, `gap`, `style`, `scroll` (vertical), `scroll_x`,
  `reveal` (local ID of a descendant container), `reveal_start`, `on_click`,
  `align_y` (`"start"`, `"center"`, `"end"`), and `measure` (scroll viewport feedback).
- `text(value, style, opts)` uses the existing monospace label renderer. Its
  `opts.wrap` accepts `"words"` (default), `"newlines"` or `"none"`.
- `button(opts)` reuses `ui.button` recipes, variants, sizes and disabled state.
- `progress(value, opts)` demonstrates a Clay `CUSTOM` command. It is a native
  proof of custom painting, not an API for arbitrary Lua drawing callbacks.
- `show(tree)` validates and serializes a snapshot. Call again to update content.
- `hide()` dismisses the surface and drops its callbacks.

All clickable nodes require explicit unique local IDs; surfaces prefix them with
an instance namespace. Standalone buttons activate on matching press/release;
overlay buttons retain the existing overlay click behavior. Callbacks never run
from inside Clay traversal.

## Owned surfaces

```lua
local surface = layout.new({
  render = function(ctx)
    return layout.column({ layout.text("Host width: " .. tostring(ctx.width)) })
  end,
})
surface:show()
surface:invalidate() -- schedules a new snapshot
surface:destroy()    -- drops cached nodes and callbacks
```

Each instance owns callbacks and its serialized snapshot. Rendering happens only
when dirty or when host dimensions, font metrics or the theme generation change.
Opt-in (`measure = true`) scroll viewport measurements appear in read-only `ctx.metrics`, keyed
by local ID. Changed dimensions invalidate once; unchanged measurements do not
rebuild the tree. Generic live select providers and custom workspace formatters
are explicit per-frame exceptions. Builtin pickers subscribe to model events and
schedule timed refreshes only for changing spinner or age labels. Modal listeners
are removed on close; pending callbacks become inert without retaining widgets.
Modal surfaces are mounted and destroyed by the existing overlay shell. The
native adapter currently renders one active Clay surface at a time; this is not
yet a simultaneous multi-pane renderer. Demo content lives in `layout_demo.lua`,
while validation/serialization lives in `layout_serialize.lua`.

Container option `full_bleed_x = true` extends its background paint to the inner
horizontal edges of a framed overlay. Layout bounds, padding, and clipping stay
unchanged; standalone surfaces do not expand this paint.

## Ownership boundary

```text
Lua component -> cached preorder tree with child counts -> C Clay bridge
             -> render commands -> existing Sokol / FreeType drawing
```

Although serialized as a preorder array, the tree retains each container and
its direct child count. It is not flattened into rows or inline segments.

Clay owns sizing, child placement, word wrapping, scroll offsets and hit geometry.
Hollow owns themes, callbacks, modal input routing, glyph measurement/drawing,
clipping implementation, custom painting and native memory lifetime. Text and
IDs are copied out of Lua before rendering, and glyphs are prerasterized before
the swapchain pass. Command arrays and custom payloads are consumed in that frame.

Snapshots are sparse: false, zero and default fields are omitted and the native
parser supplies defaults (`alpha` 255, `scrollbar_thumb_size` 1). Only the root,
explicit IDs, scroll viewports and `measure` nodes carry IDs; anonymous nodes are
identified by preorder index. Style resolution is memoized per style table within
one snapshot, and text nodes resolve only `fg` and `bold`.

One Clay context is shared by all surfaces; IDs are namespaced per surface, so
retired scroll records are pruned by Clay rather than by reallocating the arena.
Bounds, visible (clip-intersected) bounds and hit testing are computed once per
layout in a single preorder pass. Paint geometry is snapped to whole pixels.
Clay errors are logged once per snapshot revision.

Overlay invalidation (`layout_events`, timed refreshes) calls the host's
`request_redraw`, which wakes the frame loop without recomputing pane layout.
Legacy overlays register no layout listeners.

`ui.layout.debug(true)` enables Clay's built-in inspector for the active surface;
the framed panel paint clip is lifted while it is open. The inspector adds
several Clay elements per inspected element, so a context is rebuilt with a
16384-element capacity (about 11 MB) the first time an inspector opens on it;
plain layouts keep the 2048-element default. Pointer input over the panel goes
to the inspector before the surface or the overlay owning it, so it stays
usable while overlays capture input; its close button clears the flag. Keyboard
input still belongs to the overlay.

Both inspectors share one panel width, `ui.layout.debug_width(px)` (default 400).
Dragging the panel's left edge resizes it. The host clamps the width to at least
250 px while leaving 100 px of layout, and writes the applied width back to Lua.

`ui.layout.debug_grid(true)` opens the same inspector over Hollow's own window
geometry, which is not laid out by Clay. Each frame the top bar, sidebar, bottom
bar, the active tab's split tree and its floating panes are mirrored into a
dedicated Clay context using the same split math as the renderer
(`mux.splitChildBounds`). The mirror is never painted; only the inspector panel
and its hover highlight are.

- Elements: `window`, `topbar`, `body`, `sidebar`, `tab`, `bottombar`,
  `split.vertical`/`split.horizontal` (numbered in preorder) and `pane:<id>`,
  where `<id>` matches Lua `pane.id`. Pane text shows `colsxrows`, state flags
  (`active`, `floating`, `maximized`) and the title.
- Bars: `topbar.frame`/`bottombar.frame` (the bar box inside its margin) holds
  `<bar>.segment` (numbered by item position) and `<bar>.tab` (numbered by tab)
  margin boxes, recorded by the bar renderer while the inspector is open. Each
  margin box holds a `<bar>.segment.box`/`<bar>.tab.box` painted box with its
  displayed text. At most 64 items per bar.
- Bar frames and item boxes carry the paint the renderer resolved, shown in the
  inspector's element info: background, border (1 px, alpha 72), corner radius,
  padding, and the text's color and font (font id 1 is bold). Tabs show their
  active/inactive fallbacks; segments fall back to their segment colors. Panes,
  the sidebar and the window carry no style.
- Children that tile their parent along one axis become a Clay row or column.
  The first child's offset becomes the parent's left/top padding (right/bottom
  come from its style); dividers and other gaps between children appear as `gap`
  spacers. Floating panes, an unreserved
  sidebar and a maximized pane shown over its background are attached as Clay
  floating elements, so they appear as separate roots in the inspector.
- Granularity stops at panes; rows and cells are not mirrored.
- Pointer input over the panel on the right goes to the inspector only;
  elsewhere it still reaches panes and bars. The close button clears the flag.
- It takes precedence over `ui.layout.debug` while both are enabled.

Static surfaces do not call their Lua render function while idle. Snapshot
revisions gate copying/parsing into retained native nodes. Native layout still runs on each rendered frame;
dirty-layout and texture caching are not implemented. Glyph prerasterization is
revisited each frame to handle atlas changes safely.

## Deliberate prototype limits

- One active standalone or overlay surface, at most 512 nodes and 32 container levels.
- Fixed pixel sizing; no DPI-independent unit system or percentage sizing yet.
- Uniform corner radius/border width; hex RGB paint; background-only hover style.
- No new editing engine, generic keyboard traversal, images, transitions,
  general-purpose virtualization, or arbitrary custom renderer registration.
  Select has bounded windowing; confirmation and
  input dialogs reuse existing behaviors; semantics cover panels, buttons and
  visible select list items.
- Very small fixed heights can clip dialog content/buttons. Long-prompt and tiny
  viewport parity need visual checks before making Clay the default.
- Scroll offsets and explicit descendant reveal are supported; picker scrollbar
  controls reuse the overlay shell. Reveal targets one container per viewport.
- Opaque custom widgets need explicit size constraints; Clay cannot measure their
  painted contents.

Next: compare production picker visuals and hit bounds, benchmark idle/resize/scrolling.
Existing geometry remains available for
comparison; no legacy geometry has been deleted yet.

## Tests

```sh
zig build test-clay
make test-lua
```

`test-clay` exercises the actual C library without a window backend: nested
layout, resize allocation, custom payloads, clipping, scrolling, hit testing and
host-relative frame alignment/clamping. Lua tests cover hierarchy, recipes,
callback isolation, dirty snapshots, theme/metric invalidation, confirmation keys,
clicks, input editing/cancellation, caret reveal, selectable-list ranking/actions,
bounded windows, clipped hits, live sources, modal ownership and destruction.
Full `make test` still requires normal Linux GUI development libraries.

Clay is pinned under `third_party/clay` with one local patch to
`Clay_UpdateScrollContainers` (see its README); its declaration macros stay inside
`src/ui/clay_bridge.c`. Future Lua panes can reuse this layout boundary inside
mux-provided rectangles without transferring terminal split geometry to Clay.
