//! Opt-in, fixed-size diagnostics only. Never influences scheduling/admission.
//! Positions count successfully queued/written wire bytes, independent of buffer
//! compaction. A filesystem worker reply is one opaque framed span, not one DATA.
const std = @import("std");
const focus_profile = @import("focus_profile.zig");

pub const Class = enum { other, pty_data, exec_data, filesystem_reply, pty_input_ack, pty_resize_ack, pty_close_ack };
pub const Request = enum { pty_input, pty_resize, pty_close, exec, filesystem };
const class_count = std.meta.tags(Class).len;
pub const capacity = 1024;

pub const Samples = struct {
    count: u64 = 0,
    sum: u64 = 0,
    max: u64 = 0,
    // Bucket 0 includes 0 and 1; bucket i>0 includes [2^i, 2^(i+1)).
    log2: [64]u64 = @splat(0),

    pub fn record(self: *Samples, value: u64) void {
        self.count += 1;
        self.sum +|= value;
        self.max = @max(self.max, value);
        self.log2[std.math.log2_int(u64, @max(1, value))] += 1;
    }
};

pub const ClassStats = struct {
    enqueued: u64 = 0,
    untracked: u64 = 0,
    discarded: u64 = 0,
    bytes_ahead: Samples = .{},
    first_write_ns: Samples = .{},
    complete_write_ns: Samples = .{},
};

pub const Snapshot = struct {
    schema: u32 = 1,
    bounded_bulk: bool = false,
    bulk_frames: u64 = 0,
    bulk_deferred: u64 = 0,
    bulk_oversized_frames: u64 = 0,
    bulk_max_queued_bytes: usize = 0,
    class_order: [class_count]Class = std.meta.tags(Class).*,
    classes: [class_count]ClassStats = @splat(.{}),
    request_order: [std.meta.tags(Request).len]Request = std.meta.tags(Request).*,
    request_handler_ns: [std.meta.tags(Request).len]Samples = @splat(.{}),
    dispatch_ns: Samples = .{},
    poll_ns: Samples = .{},
    poll_with_complete_command_ns: Samples = .{},
    max_pending: usize = 0,
    pending: usize = 0,
    queued_wire_bytes: u64 = 0,
    written_wire_bytes: u64 = 0,
    discarded_wire_bytes: u64 = 0,
};

const Mark = struct {
    start: u64,
    end: u64,
    queued_ns: u64,
    class: Class,
    started: bool = false,
};

pub const Profiler = struct {
    focus: focus_profile.Profiler = .{},
    marks: [capacity]Mark = undefined,
    head: usize = 0,
    count: usize = 0,
    // Includes discarded bytes so future marks retain monotonic positions.
    consumed: u64 = 0,
    stats: Snapshot = .{},

    pub fn enqueue(self: *Profiler, class: Class, bytes: usize, now_ns: u64) void {
        const stats = &self.stats.classes[@intFromEnum(class)];
        stats.enqueued += 1;
        stats.bytes_ahead.record(self.stats.queued_wire_bytes - self.consumed);
        const start = self.stats.queued_wire_bytes;
        self.stats.queued_wire_bytes += bytes;
        if (self.count == capacity) {
            stats.untracked += 1;
            return;
        }
        self.marks[(self.head + self.count) % capacity] = .{
            .start = start,
            .end = start + bytes,
            .queued_ns = now_ns,
            .class = class,
        };
        self.count += 1;
        self.stats.max_pending = @max(self.stats.max_pending, self.count);
        self.stats.pending = self.count;
    }

    pub fn wrote(self: *Profiler, bytes: usize, now_ns: u64) void {
        std.debug.assert(bytes <= self.stats.queued_wire_bytes - self.consumed);
        self.focus.wrote(self.consumed, self.consumed + bytes, now_ns);
        self.consumed += bytes;
        self.stats.written_wire_bytes += bytes;
        while (self.count > 0) {
            const mark = &self.marks[self.head];
            if (self.consumed <= mark.start) break;
            const stats = &self.stats.classes[@intFromEnum(mark.class)];
            const elapsed = now_ns -| mark.queued_ns;
            if (!mark.started) {
                stats.first_write_ns.record(elapsed);
                mark.started = true;
            }
            if (self.consumed < mark.end) break;
            stats.complete_write_ns.record(elapsed);
            self.head = (self.head + 1) % capacity;
            self.count -= 1;
        }
        self.stats.pending = self.count;
    }

    pub fn discard(self: *Profiler) void {
        self.focus.discard();
        while (self.count > 0) {
            const mark = self.marks[self.head];
            self.stats.classes[@intFromEnum(mark.class)].discarded += 1;
            self.head = (self.head + 1) % capacity;
            self.count -= 1;
        }
        self.stats.discarded_wire_bytes += self.stats.queued_wire_bytes - self.consumed;
        self.consumed = self.stats.queued_wire_bytes;
        self.stats.pending = 0;
    }
};

test "queue timings distinguish first and complete writes across partial spans" {
    var profile: Profiler = .{};
    profile.enqueue(.filesystem_reply, 100, 10);
    profile.enqueue(.pty_input_ack, 20, 20);
    profile.wrote(50, 30);
    try std.testing.expectEqual(@as(u64, 20), profile.stats.classes[3].first_write_ns.max);
    try std.testing.expectEqual(@as(u64, 0), profile.stats.classes[3].complete_write_ns.count);
    profile.wrote(50, 40);
    try std.testing.expectEqual(@as(u64, 0), profile.stats.classes[4].first_write_ns.count);
    profile.wrote(1, 50);
    profile.wrote(19, 60);
    const ack = profile.stats.classes[@intFromEnum(Class.pty_input_ack)];
    try std.testing.expectEqual(@as(u64, 100), ack.bytes_ahead.max);
    try std.testing.expectEqual(@as(u64, 30), ack.first_write_ns.max);
    try std.testing.expectEqual(@as(u64, 40), ack.complete_write_ns.max);
    try std.testing.expectEqual(@as(usize, 0), profile.count);
}

test "diagnostic overflow drops timings, never wire positions, and recovers" {
    var profile: Profiler = .{};
    for (0..capacity + 1) |_| profile.enqueue(.other, 1, 1);
    try std.testing.expectEqual(@as(u64, 1), profile.stats.classes[0].untracked);
    profile.wrote(capacity + 1, 2);
    try std.testing.expectEqual(@as(u64, capacity), profile.stats.classes[0].complete_write_ns.count);
    profile.enqueue(.pty_resize_ack, 5, 3);
    profile.wrote(5, 4);
    try std.testing.expectEqual(@as(u64, 1), profile.stats.classes[5].complete_write_ns.count);
    try std.testing.expectEqual(@as(u64, capacity + 6), profile.stats.written_wire_bytes);
}

test "discarded and partially written spans are censored, not false completions" {
    var profile: Profiler = .{};
    profile.enqueue(.exec_data, 100, 10);
    profile.wrote(1, 20);
    profile.discard();
    try std.testing.expectEqual(@as(u64, 1), profile.stats.classes[2].discarded);
    try std.testing.expectEqual(@as(u64, 0), profile.stats.classes[2].complete_write_ns.count);
    try std.testing.expectEqual(@as(u64, 99), profile.stats.discarded_wire_bytes);
    profile.enqueue(.pty_data, 10, 30);
    profile.wrote(10, 40);
    try std.testing.expectEqual(@as(u64, 0), profile.stats.classes[1].bytes_ahead.max);
    try std.testing.expectEqual(@as(u64, 10), profile.stats.classes[1].complete_write_ns.max);
}

test "focus payload positions remain correct when aggregate span marks overflow or discard" {
    var profile: Profiler = .{};
    for (0..capacity) |_| profile.enqueue(.other, 1, 1);
    profile.focus.acceptedFocus(1, 7, 2, 2);
    profile.focus.ready(2, 3);
    profile.enqueue(.pty_data, 32, 4);
    profile.focus.enqueue(2, capacity + 22, capacity + 32, 4);
    profile.wrote(capacity + 22, 5);
    try std.testing.expect(profile.focus.events[0].first_write_ns == null);
    profile.wrote(1, 6);
    profile.discard();
    try std.testing.expectEqual(@as(?focus_profile.Stop, .discarded), profile.focus.events[0].stop);
    try std.testing.expect(profile.focus.events[0].complete_write_ns == null);
    profile.focus.acceptedFocus(2, 7, 2, 7);
    profile.focus.ready(2, 8);
    profile.enqueue(.pty_data, 32, 9);
    profile.focus.enqueue(2, profile.stats.queued_wire_bytes - 10, profile.stats.queued_wire_bytes, 9);
    profile.wrote(32, 10);
    try std.testing.expectEqual(@as(?u64, 10), profile.focus.events[1].complete_write_ns);
}
