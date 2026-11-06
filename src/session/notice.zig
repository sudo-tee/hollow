//! Pane-independent native status. Fixed storage, no Lua/VT borrowing, no timer.
const std = @import("std");
pub const Outcome = @import("open.zig").Outcome;
pub const max_entries = 32;

pub const Notice = struct {
    id: u64,
    state: enum { connecting, failed } = .connecting,
    reason: ?anyerror = null,
    outcome: Outcome = .not_sent,
    remote: [64]u8 = undefined,
    remote_len: usize = 0,
};

pub const Notices = struct {
    entries: [max_entries]?Notice = @splat(null),
    count: usize = 0,

    pub fn start(self: *Notices, id: u64) bool {
        return self.put(.{ .id = id });
    }

    pub fn failed(self: *Notices, id: u64, reason: anyerror, outcome: Outcome) bool {
        return self.failedRemote(id, reason, outcome, null);
    }

    pub fn failedRemote(self: *Notices, id: u64, reason: anyerror, outcome: Outcome, remote: ?[]const u8) bool {
        var value: Notice = .{ .id = id, .state = .failed, .reason = reason, .outcome = outcome };
        if (remote) |message| {
            value.remote_len = @min(message.len, value.remote.len);
            for (message[0..value.remote_len], 0..) |byte, i| value.remote[i] = if (byte >= 32 and byte <= 126) byte else '?';
        }
        return self.put(value);
    }

    fn put(self: *Notices, value: Notice) bool {
        var empty: ?usize = null;
        var oldest_failure: ?usize = null;
        for (self.entries, 0..) |entry, i| {
            const notice = entry orelse {
                if (empty == null) empty = i;
                continue;
            };
            if (notice.id == value.id) {
                self.entries[i] = value;
                return true;
            }
            if (notice.state == .failed) {
                if (oldest_failure == null or notice.id < self.entries[oldest_failure.?].?.id) oldest_failure = i;
            }
        }
        const index = empty orelse oldest_failure orelse return false;
        if (self.entries[index] == null) self.count += 1;
        self.entries[index] = value;
        return true;
    }

    pub fn clear(self: *Notices, id: u64) bool {
        if (self.count == 0) return false;
        for (&self.entries) |*entry| if (entry.*) |value| {
            if (value.id != id) continue;
            entry.* = null;
            self.count -= 1;
            return true;
        };
        return false;
    }

    /// Latest operation first; older retained failures reappear after dismissal.
    pub fn current(self: *const Notices) ?Notice {
        if (self.count == 0) return null;
        var result: ?Notice = null;
        for (self.entries) |entry| if (entry) |value| {
            if (result == null or value.id > result.?.id) result = value;
        };
        return result;
    }
};

pub const Text = struct {
    buffer: [192]u8 = undefined,
    lines: [4][]const u8 = undefined,
    count: usize = 0,

    pub fn format(self: *Text, notice: Notice) void {
        if (notice.state == .connecting) {
            self.lines[0] = std.fmt.bufPrint(&self.buffer, "Connecting persistent session #{d}", .{notice.id}) catch "Connecting persistent session";
            self.lines[1] = "No shell fallback. Click to cancel.";
            self.count = 2;
            return;
        }
        const remote = notice.remote[0..notice.remote_len];
        if (notice.outcome == .rejected and (notice.reason orelse error.Unknown) == error.RespawnRejected) {
            self.lines[0] = std.fmt.bufPrint(&self.buffer, "Pane respawn failed: {s}", .{if (remote.len > 0) remote else "Owner rejected request"}) catch "Pane respawn failed";
            self.lines[1] = "Owner rejected respawn. Existing screen was kept.";
            self.lines[2] = "Click to dismiss. No automatic retry.";
            self.count = 3;
            return;
        }
        if (notice.outcome == .rejected and std.mem.eql(u8, remote, "SessionNotFound")) {
            // The owner is alive and authoritative: the session ended or was
            // killed. Nothing was created, so starting fresh is safe.
            self.lines[0] = "Session not found on host";
            self.lines[1] = "It ended or was killed. Run `hollow-cli session list`";
            self.lines[2] = "to see live sessions, or open a new workspace.";
            self.lines[3] = "Click to dismiss.";
            self.count = 4;
            return;
        }
        self.lines[0] = std.fmt.bufPrint(&self.buffer, "Session open failed: {s}", .{if (notice.remote_len > 0) remote else if (notice.reason) |reason| @errorName(reason) else "Unknown"}) catch "Session open failed";
        switch (notice.outcome) {
            .not_sent => {
                self.lines[1] = "Request was not sent. Check host settings.";
                self.lines[2] = "Click to dismiss. No automatic retry.";
                self.count = 3;
            },
            .rejected => {
                self.lines[1] = "Owner rejected request. Check session/host settings.";
                self.lines[2] = "Click to dismiss. No automatic retry.";
                self.count = 3;
            },
            .uncertain => {
                self.lines[1] = "Request may have reached owner. Do not recreate.";
                self.lines[2] = "Reconnect existing session; no automatic retry.";
                self.lines[3] = "Click to dismiss this warning.";
                self.count = 4;
            },
        }
    }
};

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,

    pub fn contains(self: Rect, x: f32, y: f32) bool {
        return self.width > 0 and self.height > 0 and x >= self.x and y >= self.y and x < self.x + self.width and y < self.y + self.height;
    }
};

pub fn panel(bounds: anytype, cell_w: f32, cell_h: f32, line_count: usize) Rect {
    if (bounds.width == 0 or bounds.height == 0 or line_count == 0 or
        !std.math.isFinite(cell_w) or !std.math.isFinite(cell_h) or cell_w <= 0 or cell_h <= 0) return .{};
    const width: f32 = @floatFromInt(bounds.width);
    const height: f32 = @floatFromInt(bounds.height);
    const margin = @min(@as(f32, 8), @min(width, height) / 4);
    const w = @min(width - 2 * margin, 72 * cell_w);
    const h = @min(height - 2 * margin, (@as(f32, @floatFromInt(@min(line_count, 4))) + 1) * cell_h);
    return .{
        .x = @as(f32, @floatFromInt(bounds.x)) + width - margin - w,
        .y = @as(f32, @floatFromInt(bounds.y)) + margin,
        .width = w,
        .height = h,
    };
}

test "session pane notice transitions preserve unrelated failures and bound history" {
    var notices: Notices = .{};
    try std.testing.expect(notices.current() == null);
    try std.testing.expect(notices.start(1));
    try std.testing.expect(notices.failed(1, error.Disconnected, .uncertain));
    try std.testing.expect(notices.start(2));
    try std.testing.expectEqual(@as(u64, 2), notices.current().?.id);
    try std.testing.expect(notices.clear(2));
    try std.testing.expectEqual(@as(u64, 1), notices.current().?.id);
    try std.testing.expect(!notices.clear(2));
    for (2..max_entries + 2) |id| try std.testing.expect(notices.start(id));
    try std.testing.expectEqual(max_entries, notices.count);
    // Old failure evicted, but never hide an in-flight operation for capacity.
    try std.testing.expect(!notices.start(max_entries + 2));
    try std.testing.expect(!notices.clear(1));
}

test "session pane notice text distinguishes uncertainty without implying safe replay" {
    var text: Text = .{};
    text.format(.{ .id = 4 });
    try std.testing.expectEqual(@as(usize, 2), text.count);
    text.format(.{ .id = 4, .state = .failed, .reason = error.Disconnected, .outcome = .uncertain });
    try std.testing.expectEqual(@as(usize, 4), text.count);
    try std.testing.expect(std.mem.indexOf(u8, text.lines[1], "Do not recreate") != null);
    text.format(.{ .id = 4, .state = .failed, .reason = error.DeployFailed, .outcome = .not_sent });
    try std.testing.expectEqual(@as(usize, 3), text.count);
    try std.testing.expect(std.mem.indexOf(u8, text.lines[1], "not sent") != null);
}

test "session pane notice geometry stays inside content viewport and clips tiny sizes" {
    const Bounds = struct { x: u32, y: u32, width: u32, height: u32 };
    const bounds: Bounds = .{ .x = 40, .y = 32, .width = 600, .height = 200 };
    const rect = panel(bounds, 8, 16, 4);
    try std.testing.expect(rect.x >= 40 and rect.y >= 32);
    try std.testing.expect(rect.x + rect.width <= 640 and rect.y + rect.height <= 232);
    try std.testing.expect(rect.contains(rect.x, rect.y));
    try std.testing.expect(!rect.contains(rect.x + rect.width, rect.y));
    const tiny = panel(Bounds{ .x = 0, .y = 0, .width = 1, .height = 1 }, 8, 16, 4);
    try std.testing.expect(tiny.width > 0 and tiny.height > 0);
    try std.testing.expect(!panel(bounds, 0, 16, 4).contains(50, 50));
}

test "session pane notice remote rejection detail owns bounded safe bytes" {
    var notices: Notices = .{};
    var detail = "SessionNotFound\n".*;
    try std.testing.expect(notices.failedRemote(1, error.Rejected, .rejected, &detail));
    @memset(&detail, 'x');
    var text: Text = .{};
    text.format(notices.current().?);
    try std.testing.expectEqualStrings("Session open failed: SessionNotFound?", text.lines[0]);
}

test "session pane notice explains a missing session and how to recover" {
    var notices: Notices = .{};
    try std.testing.expect(notices.failedRemote(1, error.Rejected, .rejected, "SessionNotFound"));
    var text: Text = .{};
    text.format(notices.current().?);
    try std.testing.expectEqualStrings("Session not found on host", text.lines[0]);
    try std.testing.expect(std.mem.indexOf(u8, text.lines[1], "session list") != null);
    // A lost reply is not a missing session: keep the do-not-recreate warning.
    try std.testing.expect(notices.failedRemote(2, error.Disconnected, .uncertain, "SessionNotFound"));
    text.format(notices.current().?);
    try std.testing.expect(std.mem.indexOf(u8, text.lines[1], "Do not recreate") != null);
}

test "respawn rejection names pane operation without suggesting a new session" {
    var notices: Notices = .{};
    for ([_]?[]const u8{ "PaneAlive", "PaneNotFound", "SessionNotFound", null }) |remote| {
        try std.testing.expect(notices.failedRemote(1, error.RespawnRejected, .rejected, remote));
        var text: Text = .{};
        text.format(notices.current().?);
        try std.testing.expect(std.mem.startsWith(u8, text.lines[0], "Pane respawn failed:"));
        try std.testing.expectEqualStrings("Owner rejected respawn. Existing screen was kept.", text.lines[1]);
        try std.testing.expectEqualStrings("Click to dismiss. No automatic retry.", text.lines[2]);
        try std.testing.expectEqual(@as(usize, 3), text.count);
    }
    // Never let rejection wording erase uncertainty about a submitted mutation.
    try std.testing.expect(notices.failedRemote(1, error.RespawnRejected, .uncertain, "PaneAlive"));
    var text: Text = .{};
    text.format(notices.current().?);
    try std.testing.expectEqual(@as(usize, 4), text.count);
    try std.testing.expect(std.mem.indexOf(u8, text.lines[1], "Do not recreate") != null);
}
