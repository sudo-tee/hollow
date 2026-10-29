# Renderer Benchmark

Build benchmark with `zig build renderer-bench -Doptimize=ReleaseFast`.

Run deterministic repaint workload with `zig build run-renderer-bench -Doptimize=ReleaseFast -- --scenario repaint --frames 1000`.

`bench.sh` image modes emit visible Kitty protocol traffic, like other terminal
workloads:

```sh
./bench.sh image 120 30 6 48
./bench.sh image-animation 240 30 6 4 80
```

Use positional arguments to control count, rate, image count, pixel size, and
animation settings. Use `renderer-image` and `renderer-image-animation` for the
headless renderer benchmark routes.

Use `--scenario scroll`, `--scenario styled`, or `--scenario replay --input PATH` for other workloads.

Headless `--scenario image` transmits deterministic raw RGBA Kitty images and resolves fixed,
virtual, and relative placements. `--scenario image-animation` adds Kitty animation
frames and measures render-state refresh after each animation tick.

Image options:

- `--images N` controls image count (default `8`).
- `--image-width N` and `--image-height N` control raw image dimensions (default `32x32`).
- `--animation-frames N` controls frames per animated image (default `4`).
- `--animation-gap-ms N` controls frame delay (default `40`).

Use `--mode parse`, `--mode render-state`, `--mode render`, or `--mode pipeline` to isolate stages.

Use `--json` for machine-readable output.

Run `.github/workflows/renderer-bench.yml` on a runner labeled `self-hosted`, `linux`, and `renderer-bench` for stable CI measurements.

Benchmark input generation and replay file reads happen outside timed regions.

Parse timing covers Ghostty VT input processing through `terminalWrite`.

Render-state timing covers Ghostty render-state synchronization through `updateRenderState`.

Render timing covers Hollow row and cell traversal, style resolution, shaping, rasterization, atlas maintenance, and CPU geometry generation.

`image_prepare` timing covers Kitty render-image placement resolution and texture
creation before draw submission. `animation_tick` timing covers
`ghostty_kitty_graphics_animation_tick` calls; each animated pipeline sample sums
one tick per requested `--frames` value.

Pipeline timing also uploads staged glyph vertices and submits dummy Sokol commands.

Dummy Sokol reports CPU command encoding only.

It does not create a window, initialize a PTY, load Lua, create mux state, create an X11 or D3D11 context, or execute GPU work.

The benchmark uses embedded Hollow fonts and does not inspect host font inventory.

Input checksum, byte count, grid dimensions, frame count, and chunk size identify workload drift.

Use `--chunk-bytes 16384`, `--chunk-bytes 65536`, and the default `--chunk-bytes 393216` when comparing parser behavior.

## Picker Lua snapshot benchmark

Run `luajit scripts/bench-pickers.lua 10` from the repository root, with the
Lua test harness dependencies (including luassert) on `LUA_PATH`. The optional
argument is an even iteration count per sample. On Nix installations where
`busted` wraps its dependencies but `luajit` does not, one option is:

```sh
source <(sed '$d' "$(command -v busted)")
luajit scripts/bench-pickers.lua 10
```

This uses actual command palette and workspace picker implementations with
explicit `layout` overrides, the stub host from `tests.harness`, 100 synthetic
entries, 1200x900 host, and 8x19 cell metrics. Workspace source is replaced
with a callable returning a fixed table: live formatting/refresh is included,
filesystem discovery and real host calls are not. Open/setup is outside timing.
Each step calls `_overlay_state` and `_layout_prepare`; selection alternates
page down/up, filter alternates typing `1`/backspace, resize alternates host
width 1000/1200, and idle performs neither event nor resize. Legacy overlay
serialization has no host dimensions, so its resize result does not include
native resize work. Clay workspace live snapshots rebuild each frame. Native
viewport feedback is not simulated.

Values are median of seven batches after 20 warmup steps, process CPU time via
`os.clock`, with normal GC and a collection before each batch. Timings cover Lua
event handling, overlay snapshot/legacy row serialization and Clay tree
construction/serialization as applicable. They exclude native tree copying,
Clay layout, legacy native geometry, font work, drawing, GPU, window system,
and real frame scheduling. They are not full renderer or visual parity results.
The terminal renderer benchmark above does not measure these picker paths either.

### Example baseline

2026-10-29, Linux environment exposing 6 CPUs on AMD Ryzen 7 PRO 8840HS,
LuaJIT 2.1.1774638290, 10 steps/batch. Short batches and shared-machine noise
make these indicative, not thresholds; repeat with larger counts on an idle host.
Milliseconds per step:

| Picker | Backend | Idle | Selection/page | Filter | Resize |
| --- | --- | ---: | ---: | ---: | ---: |
| Palette | Legacy | 0.7520 | 0.4806 | 0.8610 | 0.5949 |
| Palette | Clay | 0.0047 | 2.6284 | 2.5421 | 2.9003 |
| Workspace | Legacy | 20.1866 | 20.3096 | 16.4867 | 18.4405 |
| Workspace | Clay | 23.5028 | 21.3221 | 20.4919 | 20.8045 |

Cached Clay palette idle is notably cheaper here, while palette invalidation
and resize rebuilds cost more Lua CPU. Live workspace refresh dominates even
idle and is an optimization candidate for both backends; profile before
changing caching, since status must remain live. Results cannot establish which
backend renders faster end-to-end or isolate native layout cost.

### After Lua snapshot optimizations

Same host and fixture, 2026-10-29, 20 steps/batch after integration tests/builds
finished. These are separate runs, not controlled speedup thresholds:

| Picker | Backend | Idle | Selection/page | Filter | Resize |
| --- | --- | ---: | ---: | ---: | ---: |
| Palette | Legacy | 0.6788 | 0.5368 | 0.6527 | 0.5997 |
| Palette | Clay | 0.0023 | 2.7940 | 2.3117 | 2.4830 |
| Workspace | Legacy | 8.2365 | 7.7338 | 8.0726 | 7.3878 |
| Workspace | Clay | 5.0531 | 4.2549 | 4.4573 | 4.7159 |

Workspace legacy formatting shares derived palette and variant styles within a
single provider refresh. The builtin Clay formatter generates cheap plain
accessibility labels for the full list and styles only native visible/overscan
columns, rather than also building unused legacy styled labels for every entry.
Custom formatters retain their existing path. No cross-frame cache hides status,
bell, theme or custom item changes.

Tree serialization resolves default scrollbar colors once per snapshot and
avoids resolving surface tokens twice. Palette rebuilds still cost more Lua CPU
than legacy in this fixture; individual before/after palette timings are noisy.
The substantial workspace reduction does not establish native rendering parity.

## Picker Lua memory baseline

With the same harness dependencies and fixture as the CPU benchmark, run:

```sh
source <(sed '$d' "$(command -v busted)") # if needed for Nix's busted wrapper
luajit scripts/bench-picker-memory.lua 20
```

The optional even argument sets steps per batch and open/frame/close cycles per
batch. Each explicit backend runs the same four workloads described above, in
order, with 20 warmup steps per workload and seven measured batches. Numbers are
KiB from LuaJIT `collectgarbage("count")`:

- **Retained:** median whole Lua heap after full GC, with picker open, after
  warmup and preceding batches. Includes harness, fixture, loaded modules and
  caches, not only picker-owned objects. Sequential scenarios and backends are
  not isolated processes, so absolute values are not additive or a clean
  measurement of picker footprint.
- **Uncollected/step:** median heap increase during one step with GC stopped,
  starting after full GC. Samples alternate odd/even steps. GC resumes immediately.
  This approximates short-lived heap growth, not exact total allocator traffic:
  resizing, reuse, JIT behavior and runtime bookkeeping affect the count.
- **Batch delta:** median post-full-GC heap change across a batch of event/frame
  steps with GC enabled, not per-step allocation. Negative values are possible.
- **Lifecycle:** after clearing the picker and warming up 20 open/frame/close
  cycles, report each consecutive post-GC batch delta and its median. This probes
  growth over time, not an isolated retained size per picker.

Full collections reduce noise but do not remove module caches, interned strings,
JIT warmup or other runtime effects. Positive deltas, especially early batches,
do not alone prove a leak; compare later batches, longer runs and independent
processes before investigating retained references. Results depend on workload,
iteration count, order and LuaJIT environment. These are Lua heap measurements,
not true peak memory, process RSS, native/host allocations, Clay native layout,
GPU memory, or an end-to-end memory comparison.

### Example memory baseline

2026-10-29, same Linux/LuaJIT environment as CPU examples, 100 entries,
20 steps or cycles per batch, seven batches. Values below are median KiB:

| Picker | Backend | Workload | Retained | Uncollected/step | Batch delta |
| --- | --- | --- | ---: | ---: | ---: |
| Palette | Legacy | Idle | 1668.7 | 380.7 | +1.2 |
| Palette | Legacy | Selection | 1682.9 | 380.1 | +0.6 |
| Palette | Legacy | Filter | 1754.1 | 344.7 | +0.1 |
| Palette | Legacy | Resize | 1758.8 | 342.9 | +0.1 |
| Palette | Clay | Idle | 2077.1 | 0.8 | +0.0 |
| Palette | Clay | Selection | 3275.8 | 1071.6 | +6.6 |
| Palette | Clay | Filter | 3425.3 | 1045.3 | +1.4 |
| Palette | Clay | Resize | 3449.8 | 1040.1 | +0.2 |
| Workspace | Legacy | Idle | 2015.7 | 2423.7 | +3.8 |
| Workspace | Legacy | Selection | 2035.4 | 2423.4 | +1.8 |
| Workspace | Legacy | Filter | 2068.6 | 2467.2 | +0.6 |
| Workspace | Legacy | Resize | 2069.8 | 2466.8 | +0.0 |
| Workspace | Clay | Idle | 2782.3 | 1794.2 | +1.6 |
| Workspace | Clay | Selection | 2804.2 | 1798.6 | +0.4 |
| Workspace | Clay | Filter | 2866.3 | 1931.1 | +2.6 |
| Workspace | Clay | Resize | 2890.6 | 1924.3 | +0.1 |

Lifecycle batch deltas, in order, KiB:

| Picker | Backend | Seven consecutive batch deltas | Median |
| --- | --- | --- | ---: |
| Palette | Legacy | +16.7, +7.4, +9.5, +7.6, +7.1, +9.6, +10.2 | +9.5 |
| Palette | Clay | +22.5, +19.4, +12.8, +13.0, +16.0, +16.3, +16.4 | +16.3 |
| Workspace | Legacy | +0.4, +3.8, +3.9, +3.2, +3.2, +3.7, +4.8 | +3.7 |
| Workspace | Clay | +1.8, +9.6, +7.9, +6.8, +6.9, +5.8, +7.0 | +6.9 |

Several later lifecycle batches still grow; longer isolated runs and retained
object analysis are needed to distinguish ongoing retention from warmup or caches.
