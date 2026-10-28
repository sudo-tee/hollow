# Private computed-style prototype

This is the Phase 1 experiment from `ui-styling-unification-plan.md`, stacked
on the Phase 0 baseline. It is private, is not called by live serializers, and
does not add a public `ui` method, recipe DSL, interaction state or host protocol.
`ui.styled` remains the canonical public token/merge helper.

## Contract

`shared.compute_style(palette, ...)` consumes an explicit palette and zero or
more legacy style layers. It uses the existing box-aware `merge_styles` and
color-token resolver. A single layer is read directly to avoid copying it;
multiple layers merge into an owned temporary. Neither path mutates inputs.

The result separates:

- `text`: concrete `fg` and boolean `bold`.
- `box`: concrete `bg` / `border`, `border_size`, `radius`, `background_extend`.
- `layout`: normalized `padding` and `margin`, when supplied.

Supported paint fields match the current span protocol. Unsupported fields
(such as `opacity`, `shadow` and `italic`) error in the prototype rather than
claiming native support. This does not change acceptance of legacy raw styles.
The prototype assumes the existing numeric paint-field types and keeps their
values unchanged; native geometry rules remain with existing surface adapters.

Colors resolve only against the supplied palette, including dotted tokens and
strict typo hints. Invalid literal colors are omitted as in legacy span
serialization. The helper performs no global theme lookup or caching. Callers
must obtain a fresh palette after a theme change and recompute affected styles.

Layer order is caller-owned. For eventual recipes it should be base, variant,
size, hover, selected, pressed, focus-visible, disabled, explicit override, but
this prototype supplies none of those states automatically. To preserve current
span hover, call `apply_hover` before computing; an inactive `hover` table is
not applied or resolved. Legacy group inheritance is unchanged. Inherited text
can be supplied as a first layer; do not feed parent boxes or callbacks into
new inheritance paths.

`nil` means absent and cannot clear an earlier layer. Explicit false color
values suppress earlier colors and become absent concrete paint. A false box
resets spacing to zero. A missing box remains absent, preserving adapter
defaults; an explicitly supplied box normalizes all four edges. Zero and false
values in ordinary fields retain existing merge behavior.

## Legacy adapter and fixtures

`shared.computed_style_to_segment(text, computed, id)` maps the snapshot to the
existing span protocol. Identity is supplied separately; callbacks and IDs are
never copied into computed paint. Padding is copied on output so mutation of
one segment cannot alter a shared snapshot. Margin remains in the computed
snapshot and is not emitted into a span protocol that has no margin field.

The action-button fixture compares this adapter directly to
`style_to_segment`, after existing hover resolution, for normal/hover/selected
combinations in Hollow, Kanagawa Wave, Nord and Rose Pine. The row fixture maps
`fill_bg` to `box.bg` and `fill_radius` to `box.radius`; selection accents remain
separate component parts. Row/chrome/bar compatibility adapters and recipes are
still future work, not implicit behavior of this prototype.

## Measurement and migration gate

Run from the repository root with the LuaJIT/Busted dependencies installed:

```sh
luajit scripts/bench-ui-style.lua
scripts/test-lua.sh
```

The benchmark warms each path and reports the median of seven timed batches,
with ordinary garbage collection enabled. A separate pass disables collection
briefly to count allocated Lua bytes per node. It compares the legacy segment
path, recomputing a snapshot for every segment, and adapting an existing
snapshot. Nodes repeat one action style; this is a Lua microbenchmark, not a
native frame, input-latency or full widget-tree benchmark.

One Linux x86-64 LuaJIT run, milliseconds per batch:

| Nodes | Legacy | Recompute + adapt | Reuse + adapt |
| --- | ---: | ---: | ---: |
| 25 | 0.032 | 0.056 | 0.020 |
| 100 | 0.153 | 0.284 | 0.087 |
| 500 | 1.091 | 1.809 | 0.422 |

Allocated bytes/node were 752, 1848 and 720 respectively. Timings vary with the
host; these values establish no universal budget or native performance claim.

**Decision:** keep this prototype outside the live render path. Recomputing
nested snapshots for every serialization costs more time and allocations than
the existing path. A later recipe migration should compute once for a dirty
node and reuse its snapshot, or simplify the shape to centralized flat
normalization. Do not introduce a generic cache until a real component proves
it worthwhile. This slice intentionally does not complete Phase 1's live
bar/overlay adoption exit criterion.

Native screenshots, DPI/hit-region checks and Zig tests are still pending;
this environment has no Zig toolchain or running Hollow GUI.
