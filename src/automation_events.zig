//! Bounded replay journal. Cursors are subscription barriers, not UI revisions.
const std = @import("std");
const io = @import("io.zig");

pub const max_events = 512;
pub const Event = struct {
    sequence: u64 = 0,
    kind: []const u8,
    pane_id: usize,
    command_id: ?u64 = null,
    status: ?i64 = null,
};
pub const Filter = struct {
    id: ?usize = null,
    event: ?[]const u8 = null,
    command_id: ?u64 = null,
};
pub const Batch = struct {
    cursor: u64,
    events: [max_events]Event = undefined,
    count: usize = 0,
};

pub const Journal = struct {
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    sequence: u64 = 0,
    events: [max_events]Event = undefined,
    stopped: bool = false,

    pub fn subscribe(self: *Journal) u64 {
        self.mutex.lockUncancelable(io.get());
        defer self.mutex.unlock(io.get());
        return self.sequence;
    }

    /// Event kind must have static lifetime. No borrowed pane/string storage.
    pub fn publish(self: *Journal, event: Event) u64 {
        self.mutex.lockUncancelable(io.get());
        defer self.mutex.unlock(io.get());
        if (self.stopped) return self.sequence;
        self.sequence += 1;
        var owned = event;
        owned.sequence = self.sequence;
        self.events[@intCast((self.sequence - 1) % max_events)] = owned;
        self.changed.broadcast(io.get());
        return self.sequence;
    }

    pub fn stop(self: *Journal) void {
        self.mutex.lockUncancelable(io.get());
        defer self.mutex.unlock(io.get());
        self.stopped = true;
        self.changed.broadcast(io.get());
    }

    pub fn read(self: *Journal, after: u64, filter: Filter, timeout_ms: u64) !Batch {
        self.mutex.lockUncancelable(io.get());
        defer self.mutex.unlock(io.get());
        if (after > self.sequence) return error.InvalidCursor;
        const deadline = io.nanoTimestamp() + @as(i128, timeout_ms *| std.time.ns_per_ms);
        var cursor = after;
        while (true) {
            if (self.sequence - cursor > max_events) return error.EventOverflow;
            var batch: Batch = .{ .cursor = self.sequence };
            while (cursor < self.sequence) {
                cursor += 1;
                const event = self.events[@intCast((cursor - 1) % max_events)];
                if (filter.id) |id| if (event.pane_id != id) continue;
                if (filter.event) |kind| if (!std.mem.eql(u8, kind, event.kind)) continue;
                if (filter.command_id) |id| if (event.command_id != id) continue;
                batch.events[batch.count] = event;
                batch.count += 1;
            }
            if (batch.count > 0) return batch;
            if (self.stopped) return error.ShuttingDown;
            const now = io.nanoTimestamp();
            if (now >= deadline) return batch;
            io.waitTimeout(&self.changed, &self.mutex, @intCast(deadline - now)) catch return batch;
        }
    }
};

test "subscription barrier, scope, command correlation and replay" {
    var journal: Journal = .{};
    _ = journal.publish(.{ .kind = "process_exited", .pane_id = 1 });
    const cursor = journal.subscribe();
    const command = journal.publish(.{ .kind = "command_started", .pane_id = 2 });
    _ = journal.publish(.{ .kind = "command_finished", .pane_id = 2, .command_id = command, .status = 7 });
    const batch = try journal.read(cursor, .{ .id = 2, .event = "command_finished", .command_id = command }, 0);
    try std.testing.expectEqual(@as(usize, 1), batch.count);
    try std.testing.expectEqual(@as(?i64, 7), batch.events[0].status);
    try std.testing.expectEqual(@as(usize, 0), (try journal.read(batch.cursor, .{}, 0)).count);
    try std.testing.expectEqual(@as(usize, 0), (try journal.read(cursor, .{ .id = 3 }, 0)).count);
}

test "overflow and invalid cursors are explicit, shutdown wakes readers" {
    var journal: Journal = .{};
    for (0..max_events + 1) |_| _ = journal.publish(.{ .kind = "status_changed", .pane_id = 1 });
    try std.testing.expectError(error.EventOverflow, journal.read(0, .{}, 0));
    try std.testing.expectError(error.InvalidCursor, journal.read(journal.sequence + 1, .{}, 0));
    try std.testing.expectEqual(max_events, (try journal.read(1, .{}, 0)).count);
    journal.stop();
    try std.testing.expectError(error.ShuttingDown, journal.read(journal.sequence, .{}, 1));
}

test "waiting reader observes publication without frame-thread dispatch" {
    var journal: Journal = .{};
    const publisher = struct {
        fn run(target: *Journal) void {
            std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch return;
            _ = target.publish(.{ .kind = "process_exited", .pane_id = 7, .status = 0 });
        }
    };
    const thread = try std.Thread.spawn(.{}, publisher.run, .{&journal});
    defer thread.join();
    const batch = try journal.read(0, .{ .id = 7 }, 1000);
    try std.testing.expectEqual(@as(usize, 1), batch.count);
    try std.testing.expectEqualStrings("process_exited", batch.events[0].kind);
}

test "shutdown wakes a blocked reader" {
    var journal: Journal = .{};
    const stopper = struct {
        fn run(target: *Journal) void {
            std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch return;
            target.stop();
        }
    };
    const thread = try std.Thread.spawn(.{}, stopper.run, .{&journal});
    defer thread.join();
    try std.testing.expectError(error.ShuttingDown, journal.read(0, .{}, 1000));
}
