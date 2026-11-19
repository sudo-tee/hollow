const std = @import("std");

pub const max_bytes = 4 * 1024 * 1024;

/// One blocked paste awaiting user confirmation. A confirmation pastes exactly
/// this text once; a newer block, denial, or pane teardown discards it.
pub const State = struct {
    text: ?[]u8 = null,
    generation: usize = 0,

    pub fn clear(self: *State, allocator: std.mem.Allocator) void {
        if (self.text) |text| free(allocator, text);
        self.text = null;
        self.generation +%= 1;
    }

    pub fn hold(self: *State, allocator: std.mem.Allocator, text: []const u8) !usize {
        self.clear(allocator);
        if (text.len > max_bytes) return error.ResourceExhausted;
        self.text = try allocator.dupe(u8, text);
        return self.generation;
    }

    /// Caller owns the returned text and releases it with `free`.
    pub fn take(self: *State, generation: usize) ?[]u8 {
        const text = self.text orelse return null;
        if (self.generation != generation) return null;
        self.text = null;
        self.generation +%= 1;
        return text;
    }
};

pub fn free(allocator: std.mem.Allocator, text: []u8) void {
    std.crypto.secureZero(u8, text);
    allocator.free(text);
}

test "blocked paste is taken once and only by its generation" {
    const allocator = std.testing.allocator;
    var state: State = .{};
    defer state.clear(allocator);

    const first = try state.hold(allocator, "a\nb");
    const second = try state.hold(allocator, "c\nd");
    try std.testing.expect(state.take(first) == null);
    const text = state.take(second).?;
    defer free(allocator, text);
    try std.testing.expectEqualStrings("c\nd", text);
    try std.testing.expect(state.take(second) == null);

    const oversized = try allocator.alloc(u8, max_bytes + 1);
    defer allocator.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(error.ResourceExhausted, state.hold(allocator, oversized));
    try std.testing.expect(state.text == null);
}
