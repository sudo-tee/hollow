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

## Rounded border CPU benchmark

```sh
python3 scripts/bench-rounded-borders.py --iterations 8192
```

Extracts the old outline function from revision `4a4775d` (`--baseline` overrides
this) and the new function from the working tree. Both use the real Sokol GL
implementation with its dummy GPU backend, identical blending, and batches of
16 borders at fractional positions. ReleaseFast compilation, setup and warmup
are outside timing. Nine samples alternate old/new order; JSON reports median
CPU time per border, recorded vertices, and draw commands. Timed work includes
geometry generation, vertex/command recording, and buffer rewind via `sg_commit`.
Buffer-capacity errors are checked on warmup and count-verification batches.

Example measurement, 2026-10-30, Ryzen 7 PRO 8840HS under WSL, Zig 0.17.0:

| Border (width × height, radius, thickness) | Old µs | AA µs | Old / AA | Vertices old → AA |
| --- | ---: | ---: | ---: | ---: |
| Tab (180 × 28, 6, 1) | 1.27 | 1.29 | 0.98× | 324 → 360 |
| Toast (220 × 44, 6, 2) | 1.97 | 1.30 | 1.52× | 504 → 360 |
| Large-radius toast (220 × 44, 16, 2) | 2.10 | 2.30 | 0.92× | 504 → 648 |
| Dialog (768 × 480, 8, 1) | 22.09 | 2.42 | 9.12× | 5,748 → 648 |
| Tall panel (768 × 900, 8, 2) | 41.98 | 2.38 | 17.66× | 10,776 → 648 |

Both paths coalesce into one draw command per batch: the improvement is reduced
CPU recording and geometry, not fewer GPU draw calls. Small borders can cost
slightly more, especially with larger radii. These headless measurements do
not measure GPU blending/rasterization, real frame times, or application FPS.

## Picker Lua snapshot benchmark

Run `luajit scripts/bench-pickers.lua 10` from the repository root, with the
Lua test harness dependencies (including luassert) on `LUA_PATH`. The optional
argument is an even iteration count per sample. On Nix installations where
`busted` wraps its dependencies but `luajit` does not, one option is:

```sh
source <(sed '$d' "$(command -v busted)")
luajit scripts/bench-pickers.lua 10
```

This uses actual Clay command palette and workspace picker implementations with
the stub host from `tests.harness`, 100 synthetic
entries, 1200x900 host, and 8x19 cell metrics. Workspace source is replaced
with a callable returning a fixed table: live formatting/refresh is included,
filesystem discovery and real host calls are not. Open/setup is outside timing.
Each step calls `_overlay_state` and `_layout_prepare`; selection alternates
page down/up, filter alternates typing `1`/backspace, resize alternates host
width 1000/1200, and idle performs neither event nor resize. The original baseline rebuilt Clay workspace snapshots each
frame; the scheduled-refresh implementation reuses unchanged snapshots instead.
This synthetic fixture has no animated statuses or external model events. Native
viewport feedback is not simulated.

Values are median of seven batches after 20 warmup steps, process CPU time via
`os.clock`, with normal GC and a collection before each batch. Timings cover Lua
event handling, overlay snapshots and Clay tree
construction/serialization. They exclude native tree copying,
Clay layout, font work, drawing, GPU, window system,
and real frame scheduling. They are not full renderer or visual parity results.
The terminal renderer benchmark above does not measure these picker paths either.

### Example baseline

2026-10-29, Linux environment exposing 6 CPUs on AMD Ryzen 7 PRO 8840HS,
LuaJIT 2.1.1774638290, 10 steps/batch. Short batches and shared-machine noise
make these indicative, not thresholds; repeat with larger counts on an idle host.
Milliseconds per step:

| Picker | Backend | Idle | Selection/page | Filter | Resize |
| --- | --- | ---: | ---: | ---: | ---: |
| Palette | Clay | 0.0047 | 2.6284 | 2.5421 | 2.9003 |
| Workspace | Clay | 23.5028 | 21.3221 | 20.4919 | 20.8045 |

Cached Clay palette idle avoids rebuilds here. Live workspace refresh dominates even
idle in this historical baseline. Results do not measure end-to-end rendering
or isolate native layout cost.

### After Lua snapshot optimizations

Same host and fixture, 2026-10-29, 20 steps/batch after integration tests/builds
finished. These are separate runs, not controlled speedup thresholds:

| Picker | Backend | Idle | Selection/page | Filter | Resize |
| --- | --- | ---: | ---: | ---: | ---: |
| Palette | Clay | 0.0023 | 2.7940 | 2.3117 | 2.4830 |
| Workspace | Clay | 5.0531 | 4.2549 | 4.4573 | 4.7159 |

### After Clay-only migration

2026-10-30, same host, 40 steps/batch. Removing the legacy backend added
display-width measurement to workspace and palette formatting, raising workspace
steps to about 7 ms. `util.display_width` and `truncate_*` now skip grapheme
tables for printable ASCII (one cell per byte, as in `text_width.c`):

| Picker | Idle | Selection/page | Filter | Resize |
| --- | ---: | ---: | ---: | ---: |
| Palette | 0.0012 | 1.6490 | 1.8620 | 1.7221 |
| Workspace | 0.0016 | 3.1340 | 3.4382 | 3.0418 |

In the native runtime, the fast path also skips one `host_api.text_graphemes`
call and table per label, so the gain there is likely larger than this harness
fallback shows.

The builtin Clay formatter generates cheap plain
accessibility labels for the full list and styles only native visible/overscan
columns.
Custom formatters retain their existing path. No cross-frame cache hides status,
bell, theme or custom item changes.

Tree serialization resolves default scrollbar colors once per snapshot and
avoids resolving surface tokens twice. Individual before/after palette timings are noisy.
The substantial workspace reduction does not establish native rendering performance.

## Picker Lua memory baseline

With the same harness dependencies and fixture as the CPU benchmark, run:

```sh
source <(sed '$d' "$(command -v busted)") # if needed for Nix's busted wrapper
luajit scripts/bench-picker-memory.lua 20
```

The optional even argument sets steps per batch and open/frame/close cycles per
batch. Each picker runs the same four workloads described above, in
order, with 20 warmup steps per workload and seven measured batches. Numbers are
KiB from LuaJIT `collectgarbage("count")`:

- **Retained:** median whole Lua heap after full GC, with picker open, after
  warmup and preceding batches. Includes harness, fixture, loaded modules and
  caches, not only picker-owned objects. Sequential scenarios and pickers are
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
| Palette | Clay | Idle | 2077.1 | 0.8 | +0.0 |
| Palette | Clay | Selection | 3275.8 | 1071.6 | +6.6 |
| Palette | Clay | Filter | 3425.3 | 1045.3 | +1.4 |
| Palette | Clay | Resize | 3449.8 | 1040.1 | +0.2 |
| Workspace | Clay | Idle | 2782.3 | 1794.2 | +1.6 |
| Workspace | Clay | Selection | 2804.2 | 1798.6 | +0.4 |
| Workspace | Clay | Filter | 2866.3 | 1931.1 | +2.6 |
| Workspace | Clay | Resize | 2890.6 | 1924.3 | +0.1 |

Lifecycle batch deltas, in order, KiB:

| Picker | Backend | Seven consecutive batch deltas | Median |
| --- | --- | --- | ---: |
| Palette | Clay | +22.5, +19.4, +12.8, +13.0, +16.0, +16.3, +16.4 | +16.3 |
| Workspace | Clay | +1.8, +9.6, +7.9, +6.8, +6.9, +5.8, +7.0 | +6.9 |

Several later lifecycle batches still grow; longer isolated runs and retained
object analysis are needed to distinguish ongoing retention from warmup or caches.

2026-10-30, after the Clay-only migration and ASCII width fast path: uncollected
per step fell to 759/714/693 KiB (palette selection/filter/resize) and
1112/1198/1196 KiB (workspace). Seven-batch lifecycle medians were +16.0 KiB
(palette) and +11.5 KiB (workspace), but isolated 15-batch runs with JIT on and
off stayed flat (within ±4 KiB per batch) and released every tracked widget,
palette, chrome and surface, so the growth is warmup, not retention.

### Isolated lifecycle diagnosis

Run one combination per fresh process, with the same harness dependencies:

```sh
luajit scripts/diagnose-picker-lifecycle.lua palette off 20 20 15
luajit scripts/diagnose-picker-lifecycle.lua palette on 20 20 15
```

Arguments select picker (`palette`/`workspace`), JIT mode, warmup cycles,
cycles per batch and batch count. Two full collections precede measurements.
Weak references track widgets, palettes, chrome and surfaces, not every possible
retained object. Compare all combinations, including JIT-off runs, before treating
positive heap deltas as leaks.

Closed surfaces must release widgets, themes and callbacks; other active surfaces
retain their callbacks. JIT-on growth can reflect warmup, but this does not
attribute trace memory or rule out retention of untracked objects.

## Headless native Clay baseline

```sh
zig build bench-clay -Doptimize=ReleaseFast -- 2000
```

Runs 200 warmup layouts and seven timed batches of a synthetic 166-node framed
workspace-like tree with 23 rows and two clipped columns per row. JSON lines
report median microseconds per layout for unchanged layout, alternating first/last
row reveal, and alternating host width. Reveal includes the adapter's second
layout pass when scrolling changes. Idle still performs native layout; it is not
an application idle-frame measurement.

2026-10-29, same Linux host, 2000 layouts per batch:

| Workload | Median µs/layout |
| --- | ---: |
| Unchanged | 27.77 |
| Alternating reveal | 50.16 |
| Alternating width | 26.32 |

Clay reports a minimum library arena of 1,496,768 bytes for this configured
context. This excludes adapter structures, input nodes/text, allocator overhead,
Lua heap, font atlas and GPU memory. Timings use monotonic wall time and exclude
Lua snapshots, native tree parsing/copying, glyph work, drawing and frame
scheduling. These numbers cannot establish end-to-end rendering speed.

On 2026-10-30 the same benchmark reported 27.26/50.88/27.65 µs and a
1,668,160-byte arena. Each open overlay and each visible native bar, sidebar
or debug surface owns one such context; overlay contexts are freed on close.
