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
