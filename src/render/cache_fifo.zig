const std = @import("std");

/// Insertion order for bounded caches. Amortized constant-time eviction avoids
/// rescanning the hash table from its first bucket on every cache miss.
pub fn Fifo(comptime Key: type) type {
    return struct {
        keys: std.ArrayListUnmanaged(Key) = .empty,
        head: usize = 0,

        pub fn reserve(self: *@This(), allocator: std.mem.Allocator) !void {
            if (self.head > 0 and self.head >= self.keys.items.len / 2) {
                const remaining = self.keys.items.len - self.head;
                std.mem.copyForwards(Key, self.keys.items[0..remaining], self.keys.items[self.head..]);
                self.keys.items.len = remaining;
                self.head = 0;
            }
            try self.keys.ensureUnusedCapacity(allocator, 1);
        }

        pub fn push(self: *@This(), key: Key) void {
            self.keys.appendAssumeCapacity(key);
        }

        pub fn pop(self: *@This()) ?Key {
            if (self.head == self.keys.items.len) return null;
            const key = self.keys.items[self.head];
            self.head += 1;
            return key;
        }

        pub fn clear(self: *@This()) void {
            self.keys.clearRetainingCapacity();
            self.head = 0;
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.keys.deinit(allocator);
        }
    };
}

test "cache insertion order survives repeated compaction" {
    var fifo = Fifo(usize){};
    defer fifo.deinit(std.testing.allocator);
    for (0..8) |i| {
        try fifo.reserve(std.testing.allocator);
        fifo.push(i);
    }
    for (8..10000) |i| {
        try std.testing.expectEqual(i - 8, fifo.pop().?);
        try fifo.reserve(std.testing.allocator);
        fifo.push(i);
    }
    try std.testing.expect(fifo.keys.items.len <= 16);
    fifo.clear();
    try std.testing.expect(fifo.pop() == null);
}
