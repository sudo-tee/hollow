pub fn main(init: @import("std").process.Init) !void {
    return @import("bench/renderer_bench.zig").main(init);
}
