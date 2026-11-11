//! Native lifecycle state and reserved height for the Lua takeover banner.
const std = @import("std");
pub const Rect = @import("notice.zig").Rect;
pub const Action = enum { reclaim, confirm, cancel, close };
pub const Phase = enum { idle, confirming, connecting, failed };

pub fn height(width: u32, cell_w: u32, cell_h: u32) u32 {
    if (cell_w == 0 or cell_h == 0 or width == 0) return 0;
    return (cell_h * 3 / 2 + 2) * @as(u32, if (width < cell_w * 90) 2 else 1);
}

pub fn message(phase: Phase, reason: ?anyerror, buf: []u8) []const u8 {
    return switch (phase) {
        .idle => "Session active in another window - this view is frozen",
        .confirming => "Reclaim will disconnect the other window. Continue?",
        .connecting => "Reclaiming session - keeping the frozen view until ready",
        .failed => std.fmt.bufPrint(buf, "Reclaim failed: {s} - retry explicitly", .{@errorName(reason orelse error.Unknown)}) catch "Reclaim failed - retry explicitly",
    };
}

test "session banner reserves two rows in narrow windows" {
    try std.testing.expectEqual(@as(u32, 26), height(1400, 8, 16));
    try std.testing.expectEqual(@as(u32, 52), height(320, 8, 16));
    try std.testing.expectEqual(@as(u32, 0), height(0, 8, 16));
}
