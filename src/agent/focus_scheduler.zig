//! Fixed-capacity experimental hierarchical weighted round robin.
//! One visit = one PTY quantum or one whole bulk frame, not byte fairness.
const std = @import("std");
pub const capacity = 16;
pub const weight = 4;
pub const Slot = struct {
    // Zero is reserved for the aggregate filesystem/exec class.
    group: u64,
    stream: u64 = 0,
    ready: bool,
};
const Group = struct {
    id: ?u64 = null,
    next_pane: usize = 0,
    pane_left: usize = 0,
};

pub const Scheduler = struct {
    groups: [capacity]Group = @splat(.{}),
    next_group: usize = 0,
    group_left: usize = 0,
    active_group: u64 = 0,
    active_stream: u64 = 0,
    sequence: u64 = 0,
    // A failed atomic metadata fit must be retried before any smaller DATA.
    retry: ?usize = null,

    pub fn forget(self: *Scheduler, slot: usize) void {
        if (self.retry == slot) self.retry = null;
        // Never carry a pane's residual quota over to a reused slot.
        for (&self.groups) |*group| if (group.next_pane == slot) {
            group.pane_left = 0;
        };
    }

    // Validate connection generation and live focus targets before calling.
    // Changing focus does not restart either cursor or extend residual quotas.
    pub fn focus(self: *Scheduler, sequence: u64, group: u64, stream: u64) bool {
        if (sequence <= self.sequence) return false;
        self.sequence = sequence;
        self.active_group = group;
        self.active_stream = stream;
        self.group_left = @min(self.group_left, 1);
        for (&self.groups) |*entry| entry.pane_left = @min(entry.pane_left, 1);
        return true;
    }

    pub fn next(self: *Scheduler, slots: *const [capacity]?Slot) ?usize {
        if (self.retry) |index| {
            self.retry = null;
            if (slots[index]) |slot| if (slot.ready) return index;
        }
        // Retain group state while any member lives, including zero-credit panes.
        for (&self.groups, 0..) |*group, index| if (group.id) |id| {
            var live = false;
            for (slots) |entry| if (entry) |slot| {
                if (slot.group == id) live = true;
            };
            if (!live) {
                group.* = .{};
                if (self.next_group == index) self.group_left = 0;
            }
        };
        for (slots) |entry| if (entry) |slot| {
            var found = false;
            for (self.groups) |group| if (group.id == slot.group) {
                found = true;
            };
            if (!found) for (&self.groups) |*group| if (group.id == null) {
                group.* = .{ .id = slot.group };
                break;
            };
        };
        for (0..capacity) |_| {
            const group_index = self.next_group;
            const group = &self.groups[group_index];
            if (group.id) |id| {
                for (0..capacity) |_| {
                    const pane = group.next_pane;
                    if (slots[pane]) |slot| if (slot.ready and slot.group == id) {
                        if (self.group_left == 0) self.group_left = if (id != 0 and id == self.active_group) weight else 1;
                        if (group.pane_left == 0) group.pane_left = if (id != 0 and id == self.active_group and slot.stream == self.active_stream) weight else 1;
                        group.pane_left -= 1;
                        if (group.pane_left == 0) group.next_pane = (pane + 1) % capacity;
                        self.group_left -= 1;
                        if (self.group_left == 0) self.next_group = (group_index + 1) % capacity;
                        return pane;
                    };
                    group.pane_left = 0;
                    group.next_pane = (pane + 1) % capacity;
                }
            }
            self.group_left = 0;
            self.next_group = (group_index + 1) % capacity;
        }
        return null;
    }
};

test "hierarchy weights sessions independent of pane count and rotates bulk" {
    var scheduler: Scheduler = .{};
    var slots: [capacity]?Slot = @splat(null);
    slots[0] = .{ .group = 1, .stream = 2, .ready = true };
    slots[1] = .{ .group = 1, .stream = 4, .ready = true };
    slots[2] = .{ .group = 2, .stream = 6, .ready = true };
    slots[3] = .{ .group = 0, .ready = true };
    slots[4] = .{ .group = 0, .ready = true };
    try std.testing.expect(scheduler.focus(1, 1, 2));
    var counts: [capacity]usize = @splat(0);
    for (0..600) |_| counts[scheduler.next(&slots).?] += 1;
    try std.testing.expectEqualSlices(usize, &.{ 320, 80, 100, 50, 50 }, counts[0..5]);
    try std.testing.expect(!scheduler.focus(1, 2, 6));
    try std.testing.expectEqual(@as(u64, 1), scheduler.active_group);
}

test "all sixteen ready slots progress under focus churn and zero credit" {
    var scheduler: Scheduler = .{};
    var slots: [capacity]?Slot = @splat(null);
    for (&slots, 0..) |*slot, index| slot.* = .{ .group = 1 + index / 4, .stream = index + 2, .ready = index != 15 };
    var counts: [capacity]usize = @splat(0);
    for (0..4096) |turn| {
        const active = turn % 15;
        _ = scheduler.focus(turn + 1, slots[active].?.group, slots[active].?.stream);
        counts[scheduler.next(&slots).?] += 1;
    }
    for (counts[0..15]) |count| try std.testing.expect(count > 0);
    try std.testing.expectEqual(@as(usize, 0), counts[15]);
    slots[15].?.ready = true;
    for (0..256) |_| counts[scheduler.next(&slots).?] += 1;
    try std.testing.expect(counts[15] > 0);
}

test "metadata retry survives focus changes but not slot release" {
    var scheduler: Scheduler = .{};
    var slots: [capacity]?Slot = @splat(null);
    slots[0] = .{ .group = 1, .stream = 2, .ready = true };
    slots[1] = .{ .group = 0, .ready = true };
    scheduler.retry = 1;
    _ = scheduler.focus(1, 1, 2);
    try std.testing.expectEqual(@as(usize, 1), scheduler.next(&slots).?);
    scheduler.retry = 1;
    scheduler.forget(1);
    slots[1] = null;
    try std.testing.expectEqual(@as(usize, 0), scheduler.next(&slots).?);
    slots[0] = null;
    try std.testing.expectEqual(@as(?usize, null), scheduler.next(&slots));
}

test "ready background visit gaps stay bounded under sustained focused output" {
    // Fixed readiness/topology, not a wall-time, byte-QoS or arbitrary churn proof.
    var scheduler: Scheduler = .{};
    var slots: [capacity]?Slot = @splat(null);
    for (&slots, 0..) |*slot, index| slot.* = .{ .group = if (index == 15) 0 else 1 + index / 4, .stream = index + 2, .ready = true };
    _ = scheduler.focus(1, 1, 2);
    var last: [capacity]usize = @splat(0);
    for (1..16385) |turn| {
        const index = scheduler.next(&slots).?;
        try std.testing.expect(turn - last[index] <= (capacity + weight) * (capacity + weight));
        last[index] = turn;
        if (turn > 400) for (last) |previous| try std.testing.expect(turn - previous <= 400);
    }
}
