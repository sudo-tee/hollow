const std = @import("std");
const benchmark = @import("bench/renderer_bench.zig");

test "renderer benchmark corpus integration" {
    try std.testing.expectEqual(@as(u64, 0x652825d1a05e7565), try benchmark.deterministicRepaintChecksum(std.testing.allocator));
    try benchmark.runCorrectnessTest(std.testing.allocator);
}

test "renderer handles oversized grapheme clusters" {
    try benchmark.runUnicodeGraphemeTest(std.testing.allocator);
}
