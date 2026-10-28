//! Compile-time string repetition for test fixtures.
pub fn bytes(comptime text: []const u8, comptime count: usize) *const [text.len * count:0]u8 {
    return comptime blk: {
        @setEvalBranchQuota(count + 1000);
        var result: [text.len * count:0]u8 = undefined;
        for (0..count) |i| @memcpy(result[i * text.len ..][0..text.len], text);
        result[result.len] = 0;
        const value = result;
        break :blk &value;
    };
}
