const std = @import("std");
const ghostty = @import("term/ghostty.zig");

test "session GUI and agent use identical ghostty package identities" {
    try std.testing.expect(ghostty.buildIdentity().len > 0);
    try std.testing.expectEqualStrings(@import("agent/session_vt.zig").buildIdentity(), ghostty.buildIdentity());
}

test {
    _ = @import("term/session_snapshot.zig");
    _ = @import("term/session_snapshot_job.zig");
}
