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
