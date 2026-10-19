//! Experimental hierarchical DRR over actual queued wire bytes.
//! Fixed storage and bounded searches; no credit/admission or wall-time QoS.
const std = @import("std");
const p = @import("protocol.zig");
pub const capacity = 16;
pub const quantum = p.max_data + p.header_len;
pub const max_cost = p.max_payload + p.header_len;
const search_limit = capacity * (2 * max_cost / quantum + 3);
const Group = struct {
    id: ?u64 = null,
    next_pane: usize = 0,
    deficit: i64 = 0,
    open: bool = false,
    required: usize = quantum,
};
const Pane = struct { deficit: i64 = 0, open: bool = false, required: usize = quantum };
pub const Slot = struct { group: u64, stream: u64 = 0, cost: usize };
pub const Selection = struct { slot: usize, group: usize };

pub const Scheduler = struct {
    groups: [capacity]Group = @splat(.{}),
    panes: [capacity]Pane = @splat(.{}),
    next_group: usize = 0,
    active_group: u64 = 0,
    active_stream: u64 = 0,
    retry: ?Selection = null,

    pub fn forget(self: *Scheduler, index: usize) void {
        self.panes[index] = .{};
        if (self.retry) |choice| if (choice.slot == index) {
            self.retry = null;
        };
    }

    pub fn focus(self: *Scheduler, group: u64, stream: u64) void {
        self.active_group = group;
        self.active_stream = stream;
        // Keep cursors; never refill budget. Preserve accumulation needed for
        // the next indivisible frame, so focus churn cannot starve metadata.
        for (&self.groups) |*entry| entry.deficit = @min(entry.deficit, @as(i64, @intCast(@max(quantum, entry.required))));
        for (&self.panes) |*entry| entry.deficit = @min(entry.deficit, @as(i64, @intCast(@max(quantum, entry.required))));
    }

    fn sync(self: *Scheduler, slots: *const [capacity]?Slot) void {
        for (slots, 0..) |entry, index| {
            if (entry == null or entry.?.cost == 0) self.panes[index] = .{};
            if (entry) |slot| std.debug.assert(slot.cost <= max_cost);
        }
        for (&self.groups) |*group| if (group.id) |id| {
            var live = false;
            var ready = false;
            for (slots) |entry| if (entry) |slot| if (slot.group == id) {
                live = true;
                ready = ready or slot.cost != 0;
            };
            if (!live) {
                group.* = .{};
            } else if (!ready) {
                group.deficit = 0;
                group.open = false;
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
    }

    fn pane(self: *Scheduler, group: *Group, slots: *const [capacity]?Slot) ?usize {
        var any_ready = false;
        for (slots) |entry| if (entry) |slot| {
            if (slot.group == group.id and slot.cost != 0) any_ready = true;
        };
        if (!any_ready) return null;
        for (0..search_limit) |_| {
            const index = group.next_pane;
            const budget = &self.panes[index];
            if (slots[index]) |slot| if (slot.group == group.id and slot.cost != 0) {
                budget.required = slot.cost;
                if (!budget.open) {
                    budget.deficit += quantum * @as(i64, if (slot.group != 0 and slot.group == self.active_group and slot.stream == self.active_stream) 4 else 1);
                    budget.open = true;
                }
                if (budget.deficit >= slot.cost) return index;
                budget.open = false;
            };
            group.next_pane = (index + 1) % capacity;
        }
        unreachable; // A bounded frame must fit after at most ceil(max_cost/Q) rounds.
    }

    // Next cost is an exact frame size or conservative terminal/error bound.
    // Charge only after enqueue succeeds. Failed batch fit reserves same frame.
    pub fn next(self: *Scheduler, slots: *const [capacity]?Slot) ?Selection {
        self.sync(slots);
        var ready = false;
        for (slots) |entry| if (entry) |slot| {
            if (slot.cost != 0) ready = true;
        };
        if (!ready) {
            self.retry = null;
            return null;
        }
        if (self.retry) |choice| {
            self.retry = null;
            if (slots[choice.slot]) |slot| if (slot.cost != 0 and self.groups[choice.group].id == slot.group) return choice;
        }
        for (0..search_limit) |_| {
            const index = self.next_group;
            const group = &self.groups[index];
            if (group.id) |id| if (self.pane(group, slots)) |leaf| {
                group.required = slots[leaf].?.cost;
                if (!group.open) {
                    group.deficit += quantum * @as(i64, if (id != 0 and id == self.active_group) 4 else 1);
                    group.open = true;
                }
                if (group.deficit >= slots[leaf].?.cost) return .{ .slot = leaf, .group = index };
                group.open = false;
            };
            self.next_group = (index + 1) % capacity;
        }
        return null;
    }

    pub fn charge(self: *Scheduler, choice: Selection, bytes: usize, live: bool) void {
        std.debug.assert(bytes > 0 and bytes <= max_cost);
        self.groups[choice.group].deficit -= @intCast(bytes);
        if (live) self.panes[choice.slot].deficit -= @intCast(bytes);
        std.debug.assert(self.groups[choice.group].deficit >= 0);
        if (live) std.debug.assert(self.panes[choice.slot].deficit >= 0);
    }
};

test "unequal frame sizes receive weighted bytes not equal visits" {
    var scheduler: Scheduler = .{};
    var slots: [capacity]?Slot = @splat(null);
    slots[0] = .{ .group = 1, .stream = 2, .cost = 100 };
    slots[1] = .{ .group = 1, .stream = 4, .cost = quantum };
    slots[2] = .{ .group = 2, .stream = 6, .cost = quantum / 2 };
    slots[3] = .{ .group = 0, .cost = quantum };
    slots[4] = .{ .group = 0, .cost = 1000 };
    scheduler.focus(1, 2);
    var bytes: [5]usize = @splat(0);
    for (0..100000) |_| {
        const choice = scheduler.next(&slots).?;
        const count = slots[choice.slot].?.cost;
        bytes[choice.slot] += count;
        scheduler.charge(choice, count, true);
    }
    const sibling: f64 = @floatFromInt(bytes[1]);
    const other: f64 = @floatFromInt(bytes[2]);
    try std.testing.expectApproxEqAbs(@as(f64, 4), @as(f64, @floatFromInt(bytes[0])) / sibling, 0.05);
    try std.testing.expectApproxEqAbs(@as(f64, 4), @as(f64, @floatFromInt(bytes[0] + bytes[1])) / other, 0.05);
    try std.testing.expectApproxEqAbs(@as(f64, 1), @as(f64, @floatFromInt(bytes[3] + bytes[4])) / other, 0.05);
    try std.testing.expectApproxEqAbs(@as(f64, 1), @as(f64, @floatFromInt(bytes[3])) / @as(f64, @floatFromInt(bytes[4])), 0.05);
}

test "large atomic frame progresses and idle or zero credit never hoards budget" {
    var scheduler: Scheduler = .{};
    var slots: [capacity]?Slot = @splat(null);
    slots[0] = .{ .group = 0, .cost = max_cost };
    const choice = scheduler.next(&slots).?;
    scheduler.retry = choice;
    scheduler.focus(7, 2);
    try std.testing.expectEqual(choice, scheduler.next(&slots).?);
    scheduler.charge(choice, max_cost, true);
    try std.testing.expect(scheduler.groups[choice.group].deficit >= 0);
    // Same ready frame accumulates another quantum round without a poll delay.
    const again = scheduler.next(&slots).?;
    scheduler.charge(again, max_cost, true);
    slots[0].?.cost = 0;
    try std.testing.expectEqual(@as(?Selection, null), scheduler.next(&slots));
    try std.testing.expectEqual(@as(i64, 0), scheduler.panes[0].deficit);
    try std.testing.expectEqual(@as(i64, 0), scheduler.groups[choice.group].deficit);
}

test "focus churn preserves large packet accumulation without granting extra budget" {
    var scheduler: Scheduler = .{};
    var slots: [capacity]?Slot = @splat(null);
    slots[0] = .{ .group = 1, .stream = 2, .cost = quantum };
    slots[1] = .{ .group = 0, .cost = max_cost };
    var large: usize = 0;
    for (0..4096) |_| {
        scheduler.focus(1, 2);
        const choice = scheduler.next(&slots).?;
        if (choice.slot == 1) large += 1;
        scheduler.charge(choice, slots[choice.slot].?.cost, true);
    }
    try std.testing.expect(large > 0);
}

test "actual terminal bytes charged rather than conservative reservation" {
    var scheduler: Scheduler = .{};
    var slots: [capacity]?Slot = @splat(null);
    slots[0] = .{ .group = 0, .cost = 278 };
    const choice = scheduler.next(&slots).?;
    scheduler.charge(choice, 50, true);
    try std.testing.expectEqual(@as(i64, quantum - 50), scheduler.groups[choice.group].deficit);
    try std.testing.expectEqual(@as(i64, quantum - 50), scheduler.panes[0].deficit);
}

test "slot release clears retry and residual budgets; churn cannot reset cursors" {
    var scheduler: Scheduler = .{};
    var slots: [capacity]?Slot = @splat(null);
    for (&slots, 0..) |*slot, index| slot.* = .{ .group = 1 + index / 4, .stream = 2 + 2 * index, .cost = if (index == 15) 0 else quantum };
    var counts: [capacity]usize = @splat(0);
    for (0..4096) |turn| {
        const active = turn % 15;
        scheduler.focus(slots[active].?.group, slots[active].?.stream);
        const choice = scheduler.next(&slots).?;
        counts[choice.slot] += 1;
        scheduler.charge(choice, slots[choice.slot].?.cost, true);
    }
    for (counts[0..15]) |count| try std.testing.expect(count > 0);
    try std.testing.expectEqual(@as(usize, 0), counts[15]);
    const choice = scheduler.next(&slots).?;
    scheduler.retry = choice;
    scheduler.forget(choice.slot);
    slots[choice.slot] = null;
    _ = scheduler.next(&slots);
    try std.testing.expect(scheduler.retry == null);
    try std.testing.expectEqual(@as(i64, 0), scheduler.panes[choice.slot].deficit);
}
