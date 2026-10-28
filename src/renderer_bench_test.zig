const std = @import("std");
const benchmark = @import("bench/renderer_bench.zig");

test "renderer benchmark corpus integration" {
    try std.testing.expectEqual(@as(u64, 0x652825d1a05e7565), try benchmark.deterministicRepaintChecksum(std.testing.allocator));
    try benchmark.runCorrectnessTest(std.testing.allocator);
}

test "renderer handles oversized grapheme clusters" {
    try benchmark.runUnicodeGraphemeTest(std.testing.allocator);
}

test "renderer handles timer-driven flashing updates" {
    try benchmark.runFlashScenarioTest(std.testing.allocator);
}

test "renderer prepares static Kitty image placements" {
    try benchmark.runImageScenarioTest(std.testing.allocator);
}

test "renderer advances animated Kitty images" {
    try benchmark.runImageAnimationScenarioTest(std.testing.allocator);
}

test "direct glyph vertices include pane offset" {
    try benchmark.runPaneGlyphOffsetTest(std.testing.allocator);
}

test "renderer preserves colors across page-local style IDs" {
    try benchmark.runPageStyleTest(std.testing.allocator);
}

test "text caches remain bounded under unique output" {
    try benchmark.runCachePressureTest(std.testing.allocator);
}
