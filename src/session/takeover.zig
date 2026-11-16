//! Native reclaim lifecycle for a taken session workspace. Lua owns the
//! takeover card; this state machine owns what its actions may do.
pub const Action = enum { reclaim, confirm, cancel, close };
pub const Phase = enum { idle, confirming, connecting, failed };

/// What the active workspace's takeover card shows; a null phase hides it.
pub const View = struct {
    workspace_id: usize = 0,
    phase: ?Phase = null,
    reason: ?anyerror = null,

    pub fn eql(a: View, b: View) bool {
        return a.workspace_id == b.workspace_id and a.phase == b.phase and a.reason == b.reason;
    }

    pub fn phaseName(self: View) []const u8 {
        return if (self.phase) |phase| @tagName(phase) else "none";
    }
};

test "takeover views compare phase and failure reason" {
    const std = @import("std");
    const failed: View = .{ .workspace_id = 3, .phase = .failed, .reason = error.Timeout };
    try std.testing.expect(failed.eql(failed));
    try std.testing.expect(!failed.eql(.{ .workspace_id = 3, .phase = .failed, .reason = error.Canceled }));
    try std.testing.expect(!(View{}).eql(.{ .workspace_id = 3, .phase = .idle }));
    try std.testing.expectEqualStrings("none", (View{}).phaseName());
}
