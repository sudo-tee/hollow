const std = @import("std");

/// Each class gets its own parsing budget. Time is charged only while polling
/// that class, so active-pane work cannot spend a hidden pane's allowance.
pub const Budget = struct {
    bytes: usize,
    nanoseconds: i128,
    panes: usize,

    pub fn byteQuota(self: Budget) usize {
        if (self.panes == 0) return 0;
        return std.math.divCeil(usize, self.bytes, self.panes) catch 0;
    }

    pub fn timeQuota(self: Budget) i128 {
        if (self.panes == 0) return 0;
        return @divFloor(self.nanoseconds, @as(i128, @intCast(self.panes)));
    }

    pub fn consume(self: *Budget, bytes: usize, elapsed_ns: i128) void {
        self.bytes -|= bytes;
        self.nanoseconds = @max(0, self.nanoseconds - @max(0, elapsed_ns));
        self.panes -|= 1;
    }
};

test "busy panes share time and idle panes donate unused quota" {
    var budget = Budget{ .bytes = 300, .nanoseconds = 3000, .panes = 3 };
    try std.testing.expectEqual(@as(usize, 100), budget.byteQuota());
    try std.testing.expectEqual(@as(i128, 1000), budget.timeQuota());
    budget.consume(0, 0);
    try std.testing.expectEqual(@as(usize, 150), budget.byteQuota());
    try std.testing.expectEqual(@as(i128, 1500), budget.timeQuota());
    budget.consume(150, 1500);
    try std.testing.expectEqual(@as(usize, 150), budget.byteQuota());
    try std.testing.expectEqual(@as(i128, 1500), budget.timeQuota());
    budget.consume(200, 2000);
    try std.testing.expectEqual(@as(usize, 0), budget.byteQuota());
    try std.testing.expectEqual(@as(i128, 0), budget.timeQuota());
}
