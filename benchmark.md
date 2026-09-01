
**Recommended Scope**
Build dedicated `renderer-bench` executable using Ghostty VT core, Hollow CPU renderer, FreeType/HarfBuzz, and Sokol dummy backend.

It should not initialize:

- Window
- PTY
- Lua
- Mux/workspaces
- Sokol app runtime
- X11/D3D11
- Actual GPU

It should measure:

```text
VT input
  -> Ghostty parse
  -> Ghostty render-state update
  -> Hollow row/cell traversal
  -> shaping and rasterization
  -> atlas maintenance
  -> glyph/background geometry
  -> dummy Sokol command submission
```

Dummy Sokol measures CPU command encoding, not GPU execution.

**Deliverables**
1. `zig build renderer-bench -Doptimize=ReleaseFast`
2. `zig build run-renderer-bench -- --scenario repaint --frames 1000`
3. Text and JSON output.
4. Built-in deterministic repaint and scroll workloads.
5. External VT recording support.
6. Separate timing for every pipeline stage.
7. No dependency on app executable or GUI libraries.
8. Small correctness test usable in normal CI.
9. Benchmark workflow usable on dedicated CI runner.
10. Documentation explaining measured and unmeasured work.

## Phase 1: Decouple Renderer Core

Current blocker: ` src/render/terminal_render.zig:69-104` stores pointers to `Config`, `App`, and `Pane` in `QueueContext`.

`queueInViewport` at ` src/render/terminal_render.zig:140-276` receives full application state even though core terminal rendering mostly needs explicit values.

### Required refactor

Introduce app-independent input type, either in `terminal_render.zig` or new `terminal_render_types.zig`:

```zig
pub const QueueOptions = struct {
    render_state: ?*anyopaque,
    row_iterator: *?*anyopaque,
    row_cells: *?*anyopaque,

    row_count: usize,
    col_count: usize,

    offset_x: f32 = 0,
    offset_y: f32 = 0,
    viewport_width: f32,
    viewport_height: f32,

    force_full: bool = true,
    debug_timing: bool = false,
    focused: bool = true,

    cursor_row: usize = std.math.maxInt(usize),
    cursor_col: usize = std.math.maxInt(usize),
    cursor_style: ?ghostty.CursorVisualStyle = null,
    cursor_wide: bool = false,

    selection_range: ?selection.Range = null,
    redraw_range: ?selection.Range = null,
    hovered_hyperlink: ?HoveredRange = null,

    colors: QueueColors,

    row_map_keys: ?[]u64 = null,
    row_map_vals: ?[]u64 = null,
    row_map_skip: bool = false,
    prev_cursor_row: usize = std.math.maxInt(usize),
};
```

Make `QueueColors` public or move it into shared types.

Replace `App.HoveredHyperlink` with renderer-owned value type:

```zig
pub const HoveredRange = struct {
    row: usize,
    start_col: usize,
    end_col: usize,
};
```

### App adapter

Keep existing public app-facing method as thin adapter:

```zig
pub fn queueInViewport(
    self: *FtRenderer,
    runtime: *ghostty.Runtime,
    cfg: *const Config,
    app: *const App,
    pane: ?*const Pane,
    ...
) void {
    const options = buildQueueOptions(runtime, cfg, app, pane, ...);
    queueTerminal(self, runtime, options);

    queueQuickSelectBackgrounds(self, app, pane, pane_w, pane_h);
}
```

Add app-independent entry point:

```zig
pub fn queueTerminal(
    self: *FtRenderer,
    runtime: *ghostty.Runtime,
    options: QueueOptions,
) void;
```

### Move app-only policy out of core

These policies should be resolved before calling `queueTerminal`:

- Copy-mode cursor suppression
- Unfocused cursor choice
- Quick-select overlays
- Search highlights
- Hovered hyperlink range
- App theme selection
- Current timestamp for cursor blinking

Relevant coupling:

- Cursor policy: ` src/render/color_math.zig:90-106`
- Quick-select rendering: ` src/render/terminal_render.zig:278-296`
- Search/copy mode: around  `src/render/terminal_render.zig:1215`
- Hyperlink logic: around  `src/render/terminal_render.zig:918`

Do not create fake `App` or `Pane` values for benchmark. That preserves coupling and creates fragile initialization.

### Acceptance criteria

```bash
zig build test
./launch.sh --build-only
```

Existing GUI behavior must remain unchanged.

`queueTerminal` must import neither `app.zig` nor `pane.zig`.

## Phase 2: Make `FtRenderer` Headless-Compatible

Current initialization directly asks Sokol glue for swapchain format:

```zig
const swapchain = c.sglue_swapchain();
const swapchain_color_format =
    if (swapchain.color_format != c.SG_PIXELFORMAT_NONE)
        swapchain.color_format
    else
        c.sglue_environment().defaults.color_format;
```

Location: ` src/render/ft_renderer.zig:485-486`.

This forces dependency on `sokol_app` and `sokol_glue`.

### Change initialization API

Pass target color format explicitly:

```zig
pub fn init(
    allocator: std.mem.Allocator,
    cfg: FtRendererConfig,
    swapchain_color_format: c.sg_pixel_format,
) !FtRenderer
```

GUI caller computes existing value before calling `FtRenderer.init`.

Headless caller passes:

```zig
c.SG_PIXELFORMAT_RGBA8
```

Alternative acceptable API:

```zig
pub const GraphicsConfig = struct {
    color_format: c.sg_pixel_format,
};
```

Do not add runtime checks for whether Sokol glue exists.

### Deterministic fonts

`FtRenderer.init` currently discovers system emoji font at  `src/render/ft_renderer.zig:319`.

Add explicit configuration:

```zig
discover_system_emoji: bool = true,
```

Benchmark sets it to `false`.

Use embedded Hollow fonts for benchmark. Do not depend on CI host font inventory.

### Acceptance criteria

- `ft_renderer.zig` no longer calls `sglue_swapchain`.
- `ft_renderer.zig` no longer calls `sglue_environment`.
- Existing app passes same format it used before.
- Benchmark uses embedded fonts only.
- GUI rendering remains unchanged.

## Phase 3: Add Dummy Sokol Backend

Create:

```text
src/render/sokol_headless.c
src/render/sokol_headless_bindings.h
```

Suggested C implementation:

```c
#define SOKOL_DUMMY_BACKEND
#define SOKOL_IMPL

#include "sokol_gfx.h"
#include "util/sokol_gl.h"
```

Verify exact implementation macro required by vendored Sokol version. Existing `sokol_app.c` uses `SOKOL_IMPL`, but dummy target should include only headers needed by renderer.

Suggested binding header:

```c
#include "sokol_gfx.h"
#include "util/sokol_gl.h"
```

Do not include:

```text
sokol_app.h
sokol_glue.h
sokol_debugtext.h
fontstash.h
sokol_fontstash.h
```

Benchmark initialization:

```zig
var sg_desc = std.mem.zeroes(c.sg_desc);
c.sg_setup(&sg_desc);

var sgl_desc = std.mem.zeroes(c.sgl_desc_t);
c.sgl_setup(&sgl_desc);
```

Shutdown order:

```zig
renderer.deinit();
c.sgl_shutdown();
c.sg_shutdown();
```

### Acceptance criteria

Linux binary should not link these libraries:

```text
X11
Xi
Xcursor
GL
asound
D3D11
DXGI
user32
```

Verify with:

```bash
ldd zig-out/bin/hollow-renderer-bench
```

Dummy resources must report valid state after initialization.

## Phase 4: Add Benchmark Executable

Create:

```text
src/bench/renderer_bench.zig
```

Avoid importing  `src/main.zig`.

### CLI

Minimum interface:

```text
hollow-renderer-bench [options]

--scenario repaint|scroll|styled|replay
--input PATH
--frames N
--rows N
--cols N
--chunk-bytes N
--warmup N
--iterations N
--mode parse|render-state|render|pipeline
--json
```

Suggested defaults:

```text
scenario=repaint
frames=1000
rows=40
cols=120
chunk-bytes=393216
warmup=3
iterations=10
mode=pipeline
```

`393216` matches current active-pane 384 KiB budget.

Also test 16 KiB and 64 KiB chunks because chunk shape affects parser and sanitizer behavior.

### Ghostty lifecycle

Implement:

```text
Runtime.init
createTerminal
register callbacks
createRenderState
createRowIterator
createRowCells
terminalWrite
updateRenderState
queueTerminal
free row cells
free row iterator
free render state
free terminal
Runtime.deinit
```

Callbacks are mandatory before VT writes. Requirement documented at ` src/term/ghostty.zig:722-733`.

Use no-op callbacks:

- `write_pty`: count response bytes
- `bell`: increment counter
- `enquiry`: no-op
- `xtversion`: no-op
- `size`: no-op
- `color_scheme`: no-op
- `device_attributes`: no-op
- `title_changed`: no-op

Do not add optional callback guards.

## Phase 5: Add Deterministic Workloads

Generate corpora in Zig. Do not check in multi-megabyte generated files.

### Repaint

Match ` bench.sh:223-250`:

```text
alternate screen
clear
HOME
rows - 1 styled rows
status row
repeat N frames
```

Use same palette and frame/row formulas.

### Scroll

Generate newline-heavy styled output larger than viewport.

### Styled

Cover:

```text
16 color
256 color
truecolor
bold
italic
underline
strikethrough
inverse
ligatures
box drawing
combining characters
wide characters
```

### Replay

Read raw bytes from `--input PATH`.

Keep file reading outside timed region.

### Corpus checksum

Print:

- Input byte count
- FNV or Wyhash checksum
- Rows and columns
- Frame count
- Chunk size

This prevents accidental workload drift.

## Phase 6: Benchmark Modes

Implement each independently.

### Parse

Timed operation:

```zig
runtime.terminalWrite(terminal, chunk);
```

Report:

```text
bytes/s
MiB/s
ns/byte
chunks
```

### Render State

Prepare terminal before timing.

Timed operation:

```zig
runtime.updateRenderState(render_state, terminal);
```

Report:

```text
updates/s
ns/update
dirty level
```

### Render

Prepare terminal and render state before timing.

Timed operation:

```zig
renderer.beginFrame();
terminal_render.queueTerminal(&renderer, &runtime, options);
renderer.discardGlyphQuads();
```

This measures:

- Row iteration
- Cell extraction
- Style resolution
- Shaping
- Rasterization
- Atlas packing
- Background generation
- Glyph geometry generation

Report existing counters from `FtRenderer`:

```text
last_rows_rendered
last_rows_skipped
last_cells_visited
last_glyph_runs
last_bg_rects
last_atlas_flushed
glyph_verts_count
```

### Pipeline

For each input chunk:

```text
terminalWrite
updateRenderState
queueTerminal
upload glyph vertices
dummy draw/commit
```

Report stage totals separately and combined.

### Cold and warm variants

Cold render:

```text
Fresh FtRenderer
Empty glyph cache
Empty shape cache
First atlas population
```

Warm render:

```text
Same content
Same renderer
Force full redraw
Caches retained
```

Incremental render:

```text
Feed one chunk
Update render state
Render dirty rows
Repeat
```

These must be separate results. Mixing cold and warm samples hides regressions.

## Phase 7: Timing and Output

Use monotonic nanoseconds.

Run internal warmups, then collect samples.

Report:

```text
minimum
median
mean
p95
maximum
standard deviation
```

Text example:

```text
scenario: repaint
grid: 120x40
frames: 1000
bytes: 6123456
chunk_bytes: 393216
iterations: 10

parse:
  median_ms: 82.41
  throughput_mib_s: 70.84

render_state:
  median_ms: 4.12

render_cpu:
  median_ms: 31.88
  cells: 4800
  glyph_runs: 830

pipeline:
  median_ms: 121.37
  throughput_mib_s: 48.09
```

JSON example:

```json
{
  "scenario": "repaint",
  "rows": 40,
  "cols": 120,
  "frames": 1000,
  "bytes": 6123456,
  "chunk_bytes": 393216,
  "parse_ns": 82410000,
  "render_state_ns": 4120000,
  "render_cpu_ns": 31880000,
  "submit_cpu_ns": 920000,
  "pipeline_ns": 121370000,
  "cells_visited": 4800,
  "glyph_runs": 830,
  "input_checksum": "..."
}
```

Label dummy submission as `submit_cpu_ns`, never `gpu_ns`.

## Phase 8: Build Integration

Add isolated build module in  `build.zig`.

Target name:

```text
hollow-renderer-bench
```

Build steps:

```text
renderer-bench
run-renderer-bench
```

Required imports:

```text
fonts
sokol_c from headless translate-c
ft_c
ghostty-vt-static
```

Required linked libraries:

```text
ghostty-vt-static
freetype
harfbuzz
libc
```

Must not import or link:

```text
zluajit
nightwatch
icon_data
sokol_app.c
dwrite_resolver.c
png_decode.c
platformSystemLibraries(...)
```

Expected commands:

```bash
zig build renderer-bench -Doptimize=ReleaseFast
zig build run-renderer-bench -Doptimize=ReleaseFast -- --scenario repaint --frames 1000
```

Force benchmark target to `ReleaseFast` or fail if another optimization mode is selected. Comparing Debug results is useless.

## Phase 9: Testing

Add small integration test, not performance assertion:

```text
20x5 terminal
10 repaint frames
fixed input checksum
nonzero cells visited
nonzero glyph vertices
expected final cursor position
expected render-state dimensions
no leaked allocations
```

Run under:

```bash
zig build test
zig build renderer-bench -Doptimize=ReleaseFast
zig build run-renderer-bench -Doptimize=ReleaseFast -- --scenario repaint --frames 20 --iterations 1
```

Do not enforce tight timing thresholds on shared GitHub runners. They are too noisy.

