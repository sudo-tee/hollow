//! Portable per-pane delivery state. The runtime owns the VT, attachment,
//! snapshot encoding, and process drain/linger decisions.
const std = @import("std");
const p = @import("session_protocol.zig");

/// Bounded byte queue with O(1) consumption between compactions.
pub const ByteQueue = struct {
    buf: std.ArrayList(u8) = .empty,
    start: usize = 0,

    pub fn len(self: *const ByteQueue) usize {
        return self.buf.items.len - self.start;
    }

    pub fn slice(self: *const ByteQueue) []const u8 {
        return self.buf.items[self.start..];
    }

    /// Reject before allocating, including arithmetic overflow.
    pub fn append(self: *ByteQueue, a: std.mem.Allocator, bytes: []const u8, limit: usize) !void {
        if (self.len() > limit or bytes.len > limit - self.len()) return error.ResourceExhausted;
        if (self.start > 0 and bytes.len > self.buf.capacity - self.buf.items.len) self.compact();
        try self.buf.appendSlice(a, bytes);
    }

    pub fn consume(self: *ByteQueue, n: usize) void {
        std.debug.assert(n <= self.len());
        self.start += n;
        if (self.start == self.buf.items.len) {
            self.clear();
        } else if (self.start >= 64 * 1024 and self.start >= self.len()) {
            self.compact();
        }
    }

    fn compact(self: *ByteQueue) void {
        const rest = self.len();
        std.mem.copyForwards(u8, self.buf.items[0..rest], self.slice());
        self.buf.items.len = rest;
        self.start = 0;
    }

    pub fn clear(self: *ByteQueue) void {
        self.buf.clearRetainingCapacity();
        self.start = 0;
    }

    pub fn deinit(self: *ByteQueue, a: std.mem.Allocator) void {
        self.buf.deinit(a);
    }
};

pub const Stream = struct {
    unsent: ByteQueue = .{},
    credit: u32 = p.window,
    stale: bool = false,
    snapshot_pending: bool = false,
    exit_sent: bool = false,

    pub fn deinit(self: *Stream, a: std.mem.Allocator) void {
        self.unsent.deinit(a);
    }

    pub fn attach(self: *Stream) void {
        self.unsent.clear();
        self.credit = p.window;
        self.stale = false;
        self.exit_sent = false;
        self.snapshot_pending = true;
    }

    pub fn detach(self: *Stream) void {
        self.unsent.clear();
    }

    /// The owner VT already contains bytes read while a snapshot is pending.
    /// Output after exit likewise belongs only to a future snapshot.
    pub fn appendOutput(self: *Stream, a: std.mem.Allocator, bytes: []const u8) void {
        if (self.stale or self.snapshot_pending or self.exit_sent) return;
        self.unsent.append(a, bytes, p.resync_limit) catch {
            self.unsent.clear();
            self.stale = true;
        };
    }

    pub fn grant(self: *Stream, amount: u32) void {
        self.credit += @min(amount, p.window - self.credit);
    }

    /// Old frames must be acknowledged before replacing their screen.
    pub fn requestResync(self: *Stream) bool {
        if (!self.stale or self.snapshot_pending or self.credit != p.window) return false;
        self.stale = false;
        self.snapshot_pending = true;
        return true;
    }

    /// Runtime must serialize the snapshot before allowing live output again.
    /// No runtime output may be fed between this barrier and serialization.
    pub fn startSnapshot(self: *Stream) bool {
        if (!self.snapshot_pending) return false;
        self.snapshot_pending = false;
        self.unsent.clear();
        return true;
    }

    pub fn nextOutput(self: *const Stream) []const u8 {
        if (self.snapshot_pending or self.stale or self.exit_sent) return "";
        const n = @min(@min(self.unsent.len(), p.max_data), self.credit);
        return self.unsent.slice()[0..n];
    }

    /// Call only after successful frame admission. Failed admission can detach
    /// synchronously and clear this queue; nothing may be consumed then.
    pub fn consumeOutput(self: *Stream, n: usize) void {
        std.debug.assert(n <= self.nextOutput().len);
        self.unsent.consume(n);
        self.credit -= @intCast(n);
    }

    /// Runtime supplies process exit plus EOF/linger readiness, not OS handles.
    pub fn exitReady(self: *const Stream, drained: bool) bool {
        return drained and !self.exit_sent and !self.snapshot_pending and !self.stale and self.unsent.len() == 0;
    }

    pub fn respawn(self: *Stream) void {
        self.unsent.clear();
        self.exit_sent = false;
    }
};

test "stream credit bounds chunks and grants, exit waits for drain and delivers once" {
    const a = std.testing.allocator;
    var stream: Stream = .{};
    defer stream.deinit(a);
    const bytes = try a.alloc(u8, p.window + 1);
    defer a.free(bytes);
    @memset(bytes, 'x');
    stream.appendOutput(a, bytes);
    while (stream.nextOutput().len > 0) {
        const n = stream.nextOutput().len;
        try std.testing.expect(n <= p.max_data);
        stream.consumeOutput(n);
    }
    try std.testing.expectEqual(@as(u32, 0), stream.credit);
    try std.testing.expect(!stream.exitReady(true));
    stream.grant(std.math.maxInt(u32));
    try std.testing.expectEqual(@as(u32, p.window), stream.credit);
    stream.consumeOutput(1);
    try std.testing.expect(!stream.exitReady(false));
    try std.testing.expect(stream.exitReady(true));
    stream.exit_sent = true;
    try std.testing.expect(!stream.exitReady(true));
    stream.appendOutput(a, "late");
    try std.testing.expectEqual(@as(usize, 0), stream.unsent.len());
    stream.respawn();
    try std.testing.expect(!stream.exit_sent);
}

test "overflow and allocation failure drop backlog without resetting credit; resync waits for all credit" {
    const a = std.testing.allocator;
    var stream: Stream = .{};
    defer stream.deinit(a);
    stream.appendOutput(a, "sent");
    stream.consumeOutput(4);
    const bytes = try a.alloc(u8, p.resync_limit);
    defer a.free(bytes);
    @memset(bytes, 'x');
    stream.appendOutput(a, bytes);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    // Overflow must be rejected without even trying this allocator.
    stream.appendOutput(failing.allocator(), "x");
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expect(stream.stale);
    try std.testing.expectEqual(@as(usize, 0), stream.unsent.len());
    try std.testing.expectEqual(@as(u32, p.window - 4), stream.credit);
    try std.testing.expect(!stream.requestResync());
    stream.grant(3);
    try std.testing.expect(!stream.requestResync());
    stream.grant(1);
    try std.testing.expect(stream.requestResync());
    try std.testing.expect(!stream.requestResync());
    try std.testing.expect(!stream.exitReady(true));
    stream.appendOutput(a, "already in VT");
    try std.testing.expect(stream.startSnapshot());
    try std.testing.expect(!stream.startSnapshot());
    try std.testing.expectEqual(@as(usize, 0), stream.unsent.len());

    var fresh: Stream = .{ .credit = 7 };
    defer fresh.deinit(a);
    fresh.appendOutput(a, "backlog");
    var oom = std.testing.FailingAllocator.init(a, .{ .fail_index = 0, .resize_fail_index = 0 });
    fresh.appendOutput(oom.allocator(), bytes[0..p.max_data]);
    try std.testing.expect(oom.has_induced_failure);
    try std.testing.expect(fresh.stale);
    try std.testing.expectEqual(@as(usize, 0), fresh.unsent.len());
    try std.testing.expectEqual(@as(u32, 7), fresh.credit);
}

test "attach resets delivery, pending snapshot discards live backlog, detach clears" {
    const a = std.testing.allocator;
    var stream: Stream = .{};
    defer stream.deinit(a);
    stream.appendOutput(a, "old backlog");
    stream.credit = 1;
    stream.stale = true;
    stream.exit_sent = true;
    stream.attach();
    try std.testing.expectEqual(@as(u32, p.window), stream.credit);
    try std.testing.expect(!stream.stale and !stream.exit_sent and stream.snapshot_pending);
    stream.appendOutput(a, "frozen in VT");
    try std.testing.expectEqual(@as(usize, 0), stream.nextOutput().len);
    // Even a queue prepared before the snapshot must not be replayed.
    try stream.unsent.append(a, "old", p.resync_limit);
    try std.testing.expect(stream.startSnapshot());
    try std.testing.expectEqual(@as(usize, 0), stream.unsent.len());
    stream.appendOutput(a, "new");
    try std.testing.expectEqualStrings("new", stream.nextOutput());
    stream.detach();
    try std.testing.expectEqual(@as(usize, 0), stream.unsent.len());
}

test "byte queue rejects bounds before allocation and compacts consumed prefix" {
    const a = std.testing.allocator;
    var queue: ByteQueue = .{};
    defer queue.deinit(a);
    try queue.append(a, "abcd", 4);
    queue.consume(3);
    try queue.append(a, "efg", 4);
    try std.testing.expectEqualStrings("defg", queue.slice());
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.ResourceExhausted, queue.append(failing.allocator(), "x", 4));
    try std.testing.expect(!failing.has_induced_failure);
}
