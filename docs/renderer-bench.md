# Renderer Benchmark

Build benchmark with `zig build renderer-bench -Doptimize=ReleaseFast`.

Run deterministic repaint workload with `zig build run-renderer-bench -Doptimize=ReleaseFast -- --scenario repaint --frames 1000`.

Use `--scenario scroll`, `--scenario styled`, or `--scenario replay --input PATH` for other workloads.

Use `--mode parse`, `--mode render-state`, `--mode render`, or `--mode pipeline` to isolate stages.

Use `--json` for machine-readable output.

Run `.github/workflows/renderer-bench.yml` on a runner labeled `self-hosted`, `linux`, and `renderer-bench` for stable CI measurements.

Benchmark input generation and replay file reads happen outside timed regions.

Parse timing covers Ghostty VT input processing through `terminalWrite`.

Render-state timing covers Ghostty render-state synchronization through `updateRenderState`.

Render timing covers Hollow row and cell traversal, style resolution, shaping, rasterization, atlas maintenance, and CPU geometry generation.

Pipeline timing also uploads staged glyph vertices and submits dummy Sokol commands.

Dummy Sokol reports CPU command encoding only.

It does not create a window, initialize a PTY, load Lua, create mux state, create an X11 or D3D11 context, or execute GPU work.

The benchmark uses embedded Hollow fonts and does not inspect host font inventory.

Input checksum, byte count, grid dimensions, frame count, and chunk size identify workload drift.

Use `--chunk-bytes 16384`, `--chunk-bytes 65536`, and the default `--chunk-bytes 393216` when comparing parser behavior.
