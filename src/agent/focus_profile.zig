//! Bounded diagnostic correlation, never a scheduling or protocol input.
//! Ready means captured PTY bytes plus credit observed by the agent, not kernel
//! readiness. Writes end at successful stdout syscalls, not client consumption.
const std = @import("std");
pub const capacity = 64;
pub const Stop = enum { no_stream, superseded, released, discarded };
pub const Event = struct {
    sequence: u64,
    group: u64,
    stream: u64,
    dispatch_ns: u64,
    ready_ns: ?u64 = null,
    enqueue_ns: ?u64 = null,
    payload_begin: ?u64 = null,
    payload_end: ?u64 = null,
    first_write_ns: ?u64 = null,
    complete_write_ns: ?u64 = null,
    stop: ?Stop = null,
};

pub const Profiler = struct {
    events: [capacity]Event = undefined,
    count: usize = 0,
    accepted: u64 = 0,
    dropped: u64 = 0,
    current: ?usize = null,

    pub fn acceptedFocus(self: *Profiler, sequence: u64, group: u64, stream: u64, now: u64) void {
        if (self.current) |index| self.events[index].stop = .superseded;
        self.current = null;
        self.accepted += 1;
        if (self.count == capacity) {
            self.dropped += 1;
            return;
        }
        const index = self.count;
        self.count += 1;
        self.events[index] = .{ .sequence = sequence, .group = group, .stream = stream, .dispatch_ns = now, .stop = if (stream == 0) .no_stream else null };
        if (stream != 0) self.current = index;
    }

    pub fn ready(self: *Profiler, stream: u64, now: u64) void {
        const index = self.current orelse return;
        const event = &self.events[index];
        if (event.stream == stream and event.ready_ns == null) event.ready_ns = now;
    }

    pub fn enqueue(self: *Profiler, stream: u64, begin: u64, end: u64, now: u64) void {
        const index = self.current orelse return;
        const event = &self.events[index];
        if (event.stream != stream) return;
        std.debug.assert(event.ready_ns != null and begin < end);
        event.enqueue_ns = now;
        event.payload_begin = begin;
        event.payload_end = end;
        self.current = null;
    }

    pub fn wrote(self: *Profiler, begin: u64, end: u64, now: u64) void {
        for (self.events[0..self.count]) |*event| {
            if (event.stop != null or event.payload_begin == null or event.complete_write_ns != null) continue;
            const first = event.payload_begin.?;
            const last = event.payload_end.?;
            if (end <= first or begin >= last) continue;
            if (event.first_write_ns == null) event.first_write_ns = now;
            if (end >= last) event.complete_write_ns = now;
        }
    }

    pub fn release(self: *Profiler, stream: u64) void {
        const index = self.current orelse return;
        if (self.events[index].stream == stream) {
            self.events[index].stop = .released;
            self.current = null;
        }
    }

    pub fn discard(self: *Profiler) void {
        for (self.events[0..self.count]) |*event| if (event.stop == null and event.complete_write_ns == null) {
            event.stop = .discarded;
        };
        self.current = null;
    }

    pub fn snapshot(self: *const Profiler) struct { schema: u32, capacity: usize, accepted: u64, dropped: u64, events: []const Event } {
        return .{ .schema = 1, .capacity = capacity, .accepted = self.accepted, .dropped = self.dropped, .events = self.events[0..self.count] };
    }
};

test "correlation ignores old queued data, unrelated streams and header-only writes" {
    var profile: Profiler = .{};
    profile.acceptedFocus(1, 7, 2, 10);
    profile.ready(4, 11);
    try std.testing.expect(profile.events[0].ready_ns == null);
    profile.ready(2, 12);
    profile.ready(2, 13);
    profile.enqueue(4, 50, 60, 14);
    profile.enqueue(2, 122, 132, 15);
    profile.wrote(0, 122, 20);
    try std.testing.expect(profile.events[0].first_write_ns == null);
    profile.wrote(122, 123, 21);
    profile.wrote(123, 131, 22);
    try std.testing.expect(profile.events[0].complete_write_ns == null);
    profile.wrote(131, 140, 23);
    try std.testing.expectEqual(@as(?u64, 12), profile.events[0].ready_ns);
    try std.testing.expectEqual(@as(?u64, 15), profile.events[0].enqueue_ns);
    try std.testing.expectEqual(@as(?u64, 21), profile.events[0].first_write_ns);
    try std.testing.expectEqual(@as(?u64, 23), profile.events[0].complete_write_ns);
}

test "supersession and release censor unenqueued records without stealing queued writes" {
    var profile: Profiler = .{};
    profile.acceptedFocus(1, 1, 2, 1);
    profile.ready(2, 2);
    profile.enqueue(2, 22, 32, 3);
    profile.acceptedFocus(2, 2, 4, 4);
    profile.acceptedFocus(3, 2, 4, 5);
    profile.release(2);
    try std.testing.expect(profile.current != null);
    profile.release(4);
    profile.wrote(0, 32, 6);
    try std.testing.expectEqual(@as(?u64, 6), profile.events[0].complete_write_ns);
    try std.testing.expectEqual(@as(?Stop, .superseded), profile.events[1].stop);
    try std.testing.expectEqual(@as(?Stop, .released), profile.events[2].stop);
    profile.acceptedFocus(4, 0, 0, 7);
    try std.testing.expectEqual(@as(?Stop, .no_stream), profile.events[3].stop);
}

test "overflow drops only diagnostic events and cannot attribute output to old focus" {
    var profile: Profiler = .{};
    for (0..capacity + 1) |index| profile.acceptedFocus(index + 1, 1, 2, index);
    profile.ready(2, 100);
    profile.enqueue(2, 22, 32, 101);
    try std.testing.expectEqual(@as(u64, capacity + 1), profile.accepted);
    try std.testing.expectEqual(@as(u64, 1), profile.dropped);
    try std.testing.expectEqual(@as(usize, capacity), profile.snapshot().events.len);
    for (profile.events) |event| {
        try std.testing.expectEqual(@as(?Stop, .superseded), event.stop);
        try std.testing.expect(event.enqueue_ns == null);
    }
}

test "discarded partial payload and pending records remain censored" {
    var profile: Profiler = .{};
    profile.acceptedFocus(1, 1, 2, 1);
    profile.ready(2, 2);
    profile.enqueue(2, 22, 32, 3);
    profile.wrote(0, 23, 4);
    profile.acceptedFocus(2, 2, 4, 5);
    profile.discard();
    profile.wrote(23, 32, 6);
    try std.testing.expectEqual(@as(?Stop, .discarded), profile.events[0].stop);
    try std.testing.expectEqual(@as(?Stop, .discarded), profile.events[1].stop);
    try std.testing.expect(profile.events[0].first_write_ns != null);
    try std.testing.expect(profile.events[0].complete_write_ns == null);
}

test "full diagnostic snapshot with maximum integers fits bounded serialization storage" {
    var profile: Profiler = .{};
    const maximum = std.math.maxInt(u64);
    for (0..capacity) |index| {
        profile.acceptedFocus(index + 1, maximum, maximum - 1, maximum - 3);
        profile.ready(maximum - 1, maximum - 2);
        profile.enqueue(maximum - 1, maximum - 10, maximum, maximum - 1);
    }
    profile.wrote(maximum - 10, maximum, maximum);
    var storage: [65536 - 1024]u8 = undefined;
    var output: std.Io.Writer = .fixed(&storage);
    try std.json.Stringify.value(profile.snapshot(), .{}, &output);
    try std.testing.expect(output.buffered().len > 0);
}
