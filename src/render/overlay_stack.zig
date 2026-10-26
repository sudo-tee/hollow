//! Independent positioning contexts for direct overlays, modals, and notifications.
const std = @import("std");

pub const Context = enum { overlay, modal, notification };

pub const Stack = struct {
    top: [3]f32 = @splat(0),
    bottom: [3]f32 = @splat(0),

    pub fn next(self: *Stack, context: Context, is_bottom: bool, height: f32, gap: f32) f32 {
        const offsets = if (is_bottom) &self.bottom else &self.top;
        const index = @intFromEnum(context);
        const offset = offsets[index];
        offsets[index] += height + gap;
        return offset;
    }
};

test "notifications and modals never offset each other in either insertion order" {
    for ([_]bool{ false, true }) |is_bottom| {
        var stack = Stack{};
        try std.testing.expectEqual(@as(f32, 0), stack.next(.notification, is_bottom, 60, 10));
        try std.testing.expectEqual(@as(f32, 0), stack.next(.modal, is_bottom, 300, 10));
        try std.testing.expectEqual(@as(f32, 70), stack.next(.notification, is_bottom, 60, 10));
        try std.testing.expectEqual(@as(f32, 0), stack.next(.overlay, is_bottom, 40, 10));

        stack = .{};
        try std.testing.expectEqual(@as(f32, 0), stack.next(.modal, is_bottom, 300, 10));
        try std.testing.expectEqual(@as(f32, 0), stack.next(.notification, is_bottom, 60, 10));
    }
}

test "top and bottom notification stacks remain independent" {
    var stack = Stack{};
    _ = stack.next(.notification, false, 60, 10);
    try std.testing.expectEqual(@as(f32, 0), stack.next(.notification, true, 80, 10));
    try std.testing.expectEqual(@as(f32, 70), stack.next(.notification, false, 60, 10));
    try std.testing.expectEqual(@as(f32, 90), stack.next(.notification, true, 80, 10));
}
