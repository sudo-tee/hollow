#!/usr/bin/env python3
"""Compare exact old/current outline functions using real Sokol CPU recording.

Dummy GPU backend: no window, GPU execution, presentation, or frame-time claim.
Sources are extracted on each run, not maintained as benchmark-only copies.
"""

import argparse
import pathlib
import re
import subprocess
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
RUNTIME = "src/render/sokol_runtime.zig"


def function(source, name):
    match = re.search(r"^fn " + re.escape(name) + r"\(.*?^}", source, re.M | re.S)
    if not match:
        raise ValueError(f"Cannot extract {name}")
    return match.group()


HARNESS = r'''
const std = @import("std");
const rounded_border = @import("rounded_border");
const c = @import("sokol_c");
var g_rect_pip: c.sgl_pipeline = .{ .id = 0 };

const Fixture = struct { name: []const u8, width: f32, height: f32, radius: f32, thickness: f32 };
const fixtures = [_]Fixture{
    .{ .name = "tab", .width = 180, .height = 28, .radius = 6, .thickness = 1 },
    .{ .name = "toast", .width = 220, .height = 44, .radius = 6, .thickness = 2 },
    .{ .name = "toast-large-radius", .width = 220, .height = 44, .radius = 16, .thickness = 2 },
    .{ .name = "dialog", .width = 768, .height = 480, .radius = 8, .thickness = 1 },
    .{ .name = "tall-panel", .width = 768, .height = 900, .radius = 8, .thickness = 2 },
};
const batch_size = 16;

fn checkErrors() !void {
    const errors = c.sgl_error();
    if (errors.any) return error.SokolRecordingFailed;
}

fn batch(comptime modern: bool, fixture: Fixture) void {
    for (0..batch_size) |i| {
        // Include fractional positions, as Clay layouts can produce them.
        const x = @as(f32, @floatFromInt(i)) * 0.25;
        const draw = if (modern) drawRoundedRectOutline else oldRoundedRectOutline;
        draw(x, 0.25, fixture.width, fixture.height, fixture.radius, fixture.thickness, 136, 192, 208, 220);
    }
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const iterations = if (args.next()) |text| try std.fmt.parseInt(usize, text, 10) else 2048;
    if (iterations < batch_size or iterations % batch_size != 0) return error.InvalidIterations;
    var gfx = std.mem.zeroes(c.sg_desc);
    gfx.environment.defaults.color_format = c.SG_PIXELFORMAT_RGBA8;
    gfx.environment.defaults.depth_format = c.SG_PIXELFORMAT_NONE;
    gfx.environment.defaults.sample_count = 1;
    c.sg_setup(&gfx);
    defer c.sg_shutdown();
    var gl = std.mem.zeroes(c.sgl_desc_t);
    gl.max_vertices = 400000;
    gl.max_commands = 200000;
    gl.color_format = c.SG_PIXELFORMAT_RGBA8;
    gl.depth_format = c.SG_PIXELFORMAT_NONE;
    gl.sample_count = 1;
    c.sgl_setup(&gl);
    defer c.sgl_shutdown();
    var pipeline = std.mem.zeroes(c.sg_pipeline_desc);
    pipeline.colors[0].blend.enabled = true;
    pipeline.colors[0].blend.src_factor_rgb = c.SG_BLENDFACTOR_SRC_ALPHA;
    pipeline.colors[0].blend.dst_factor_rgb = c.SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
    pipeline.colors[0].blend.src_factor_alpha = c.SG_BLENDFACTOR_ONE;
    pipeline.colors[0].blend.dst_factor_alpha = c.SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
    pipeline.colors[0].pixel_format = c.SG_PIXELFORMAT_RGBA8;
    pipeline.depth.pixel_format = c.SG_PIXELFORMAT_NONE;
    g_rect_pip = c.sgl_make_pipeline(&pipeline);
    defer c.sgl_destroy_pipeline(g_rect_pip);
    for (fixtures) |fixture| {
        // Warm both implementations, then alternate measurement order to reduce
        // bias from frequency scaling, cache warmth, and sustained CPU load.
        for (0..32) |_| {
            batch(false, fixture);
            try checkErrors();
            c.sg_commit();
            batch(true, fixture);
            try checkErrors();
            c.sg_commit();
        }
        var times: [2][9]f64 = undefined;
        var vertices: [2]c_int = undefined;
        var commands: [2]c_int = undefined;
        for (0..9) |round| {
            inline for (0..2) |order| {
                // Keep each implementation specialized, but reverse order on
                // alternating rounds without including dispatch in the timing.
                inline for (.{ false, true }) |modern| {
                    const slot = @intFromBool(modern);
                    if (slot == (order + round) % 2) {
                        const start = std.Io.Clock.awake.now(init.io).toNanoseconds();
                        for (0..iterations / batch_size) |_| {
                            batch(modern, fixture);
                            c.sg_commit(); // Rewind real Sokol command/vertex buffers.
                        }
                        const elapsed = std.Io.Clock.awake.now(init.io).toNanoseconds() - start;
                        times[slot][round] = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
                        batch(modern, fixture);
                        try checkErrors();
                        vertices[slot] = @divTrunc(c.sgl_num_vertices(), batch_size);
                        commands[slot] = c.sgl_num_commands();
                        c.sg_commit();
                    }
                }
            }
        }
        for (&times) |*samples| std.mem.sort(f64, samples, {}, std.sort.asc(f64));
        const json = try std.json.Stringify.valueAlloc(init.gpa, .{
            .fixture = fixture.name,
            .iterations_per_sample = iterations,
            .samples = 9,
            .old_median_ns_per_border = times[0][4],
            .new_median_ns_per_border = times[1][4],
            .speedup = times[0][4] / times[1][4],
            .old_vertices_per_border = vertices[0],
            .new_vertices_per_border = vertices[1],
            .old_commands_per_batch = commands[0],
            .new_commands_per_batch = commands[1],
        }, .{});
        defer init.gpa.free(json);
        try std.Io.File.stdout().writeStreamingAll(init.io, json);
        try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", default="4a4775d", help="Git revision before rounded-border AA")
    parser.add_argument("--iterations", type=int, default=2048, help="Borders per sample; multiple of 16")
    args = parser.parse_args()
    old = subprocess.check_output(["git", "show", f"{args.baseline}:{RUNTIME}"], cwd=ROOT, text=True)
    current = (ROOT / RUNTIME).read_text()
    helpers = "\n\n".join(function(current, name) for name in (
        "roundedRectRowInset", "drawRoundedRect", "drawRectOutline", "drawBorderRect",
        "drawRoundedRectOutline",
    ))
    old_outline = function(old, "drawRoundedRectOutline").replace(
        "fn drawRoundedRectOutline(", "fn oldRoundedRectOutline(", 1
    )
    with tempfile.TemporaryDirectory(prefix="rounded-border-bench-", dir="/tmp/opencode") as temp:
        temp = pathlib.Path(temp)
        source = temp / "bench.zig"
        source.write_text(HARNESS + "\n" + helpers + "\n" + old_outline)
        subprocess.run([
            "zig", "build", "bench-rounded-borders", f"-Dborder-bench-source={source}",
            "--", str(args.iterations),
        ], cwd=ROOT, check=True)


if __name__ == "__main__":
    main()
