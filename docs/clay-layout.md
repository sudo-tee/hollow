# Experimental Clay layout

Opt-in integration. Mux geometry, terminal rendering, bars and legacy overlays
retain their current implementation. Confirmation dialogs can now opt into Clay
without replacing their overlay shell or keyboard behavior.

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

Omit `layout`, or set `layout = "legacy"`, for the original renderer. Legacy
remains the default until visual/performance comparison is complete.

Tab/arrow navigation, Enter, Escape, custom button values, callback ordering,
modal ownership and overlay cleanup use the existing implementations. The Clay
branch bypasses legacy row serialization and the panel/row geometry loop.
Namespaced dialog/button IDs and Clay-calculated bounds populate existing overlay
hit regions and CLI semantic nodes. Width/height retain confirmation-dialog cell
units; alignment and sizing are calculated by Clay inside the host content rect.

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
- Options: `id`, `padding`, `gap`, `style`, `scroll` (vertical), `on_click`.
- `text(value, style)` wraps words and uses the existing monospace label renderer.
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
Modal surfaces are mounted and destroyed by the existing overlay shell. The
native adapter currently renders one active Clay surface at a time; this is not
yet a simultaneous multi-pane renderer. Demo content lives in `layout_demo.lua`,
while validation/serialization lives in `layout_serialize.lua`.

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

No Lua render function runs while idle. Snapshot revisions gate copying/parsing
into retained native nodes. Native layout still runs on each rendered frame;
dirty-layout and texture caching are not implemented. Glyph prerasterization is
revisited each frame to handle atlas changes safely.

## Deliberate prototype limits

- One active standalone or overlay surface, at most 512 nodes and 32 container levels.
- Fixed pixel sizing; no DPI-independent unit system or percentage sizing yet.
- Uniform corner radius/border width; hex RGB paint; background-only hover style.
- No text editing, generic keyboard traversal, images, transitions, virtualization,
  or arbitrary custom renderer registration. Confirmation navigation is provided
  by the existing modal behavior; semantics are published for its panel/buttons.
- Very small fixed heights can clip dialog content/buttons. Long-prompt and tiny
  viewport parity need visual checks before making Clay the default.
- Scroll offsets are supported; scrollbar controls and scroll-to-selection are not.
- Opaque custom widgets need explicit size constraints; Clay cannot measure their
  painted contents.

Next: compare confirmation screenshots and hit bounds, benchmark idle/resize,
then migrate additional overlays. Existing geometry remains available for
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
clicks, modal ownership and destruction. Full `make test` still requires normal
Linux GUI development libraries.

Clay is pinned under `third_party/clay`; its declaration macros stay inside
`src/ui/clay_bridge.c`. Future Lua panes can reuse this layout boundary inside
mux-provided rectangles without transferring terminal split geometry to Clay.
