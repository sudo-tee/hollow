const std = @import("std");
const PendingInputEvent = @import("input.zig").PendingInputEvent;

pub const ActionQueue = struct {
    const capacity = 64;

    mutex: std.Thread.Mutex = .{},
    items: [capacity]PendingInputEvent = [_]PendingInputEvent{.none} ** capacity,
    head: usize = 0,
    tail: usize = 0,

    pub fn push(self: *ActionQueue, event: PendingInputEvent) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.head != self.tail) {
            const last = if (self.tail == 0) capacity - 1 else self.tail - 1;
            const replace = switch (event) {
                .motion => switch (self.items[last]) {
                    .motion => true,
                    else => false,
                },
                .selection_update => |update| switch (self.items[last]) {
                    .selection_update => |queued| queued.pane == update.pane,
                    else => false,
                },
                else => false,
            };
            if (replace) {
                self.items[last] = event;
                return true;
            }
        }

        const next_tail = (self.tail + 1) % capacity;
        if (next_tail == self.head) return false;
        self.items[self.tail] = event;
        self.tail = next_tail;
        return true;
    }

    pub fn pop(self: *ActionQueue) ?PendingInputEvent {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.head == self.tail) return null;
        const event = self.items[self.head];
        self.items[self.head] = .none;
        self.head = (self.head + 1) % capacity;
        return event;
    }

    pub fn popIfChar(self: *ActionQueue) ?PendingInputEvent {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.head == self.tail) return null;
        switch (self.items[self.head]) {
            .char => {},
            else => return null,
        }
        const event = self.items[self.head];
        self.items[self.head] = .none;
        self.head = (self.head + 1) % capacity;
        return event;
    }

    pub fn isEmpty(self: *ActionQueue) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.head == self.tail;
    }
};

test "coalesces consecutive mouse motion without crossing event boundaries" {
    var queue = ActionQueue{};
    const first = PendingInputEvent{ .motion = .{ .held_button = null, .x = 1, .y = 2, .mods = 0 } };
    const latest = PendingInputEvent{ .motion = .{ .held_button = null, .x = 3, .y = 4, .mods = 0 } };
    const button = PendingInputEvent{ .button = .{ .action = .press, .button = .left, .x = 3, .y = 4, .mods = 0 } };

    try std.testing.expect(queue.push(first));
    try std.testing.expect(queue.push(latest));
    const motion = queue.pop() orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f32, 3), motion.motion.x);
    try std.testing.expect(queue.pop() == null);

    try std.testing.expect(queue.push(latest));
    try std.testing.expect(queue.push(button));
    try std.testing.expect(queue.push(first));
    try std.testing.expect(queue.pop().? == .motion);
    try std.testing.expect(queue.pop().? == .button);
    try std.testing.expect(queue.pop().? == .motion);
}
