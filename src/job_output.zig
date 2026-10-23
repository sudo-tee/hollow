//! Bounded raw PTY tail, independent of viewport and terminal escape processing.
const std = @import("std");
pub const capacity = 1024 * 1024;
pub const Capture = struct {
    bytes: ?[]u8 = null,
    start: usize = 0,
    len: usize = 0,
    truncated: bool = false,
    incomplete: bool = false,

    pub fn deinit(self: *Capture, a: std.mem.Allocator) void {
        if (self.bytes) |bytes| a.free(bytes);
        self.* = .{};
    }

    pub fn append(self: *Capture, a: std.mem.Allocator, input: []const u8) void {
        if (input.len == 0) return;
        if (self.bytes == null) self.bytes = a.alloc(u8, capacity) catch {
            self.incomplete = true;
            return;
        };
        const bytes = self.bytes.?;
        if (input.len >= capacity) {
            self.truncated = self.len != 0 or input.len > capacity;
            @memcpy(bytes, input[input.len - capacity ..]);
            self.start = 0;
            self.len = capacity;
            return;
        }
        const dropped = (self.len + input.len) -| capacity;
        if (dropped > 0) {
            self.truncated = true;
            self.start = (self.start + dropped) % capacity;
            self.len -= dropped;
        }
        const end = (self.start + self.len) % capacity;
        const first = @min(input.len, capacity - end);
        @memcpy(bytes[end..][0..first], input[0..first]);
        @memcpy(bytes[0 .. input.len - first], input[first..]);
        self.len += input.len;
    }

    pub fn snapshot(self: *const Capture, a: std.mem.Allocator) ![]u8 {
        const out = try a.alloc(u8, self.len);
        if (self.bytes) |bytes| {
            const first = @min(self.len, capacity - self.start);
            @memcpy(out[0..first], bytes[self.start..][0..first]);
            @memcpy(out[first..], bytes[0 .. self.len - first]);
        }
        return out;
    }
};

test "job output retains ordered bounded tail and reports loss" {
    const a = std.testing.allocator;
    var capture: Capture = .{};
    defer capture.deinit(a);
    const large = try a.alloc(u8, capacity);
    defer a.free(large);
    @memset(large, 'a');
    capture.append(a, large);
    try std.testing.expect(!capture.truncated);
    capture.append(a, "\xfflast");
    const snapshot = try capture.snapshot(a);
    defer a.free(snapshot);
    try std.testing.expectEqual(capacity, snapshot.len);
    try std.testing.expectEqualStrings("\xfflast", snapshot[snapshot.len - 5 ..]);
    try std.testing.expect(capture.truncated);
    try std.testing.expect(!capture.incomplete);
}

test "job output allocation failure is explicit even after capture recovers" {
    const a = std.testing.allocator;
    var capture: Capture = .{};
    defer capture.deinit(a);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0, .resize_fail_index = 0 });
    capture.append(failing.allocator(), "lost");
    try std.testing.expect(capture.incomplete);
    try std.testing.expectEqual(@as(usize, 0), capture.len);
    capture.append(a, "retained");
    const result = try capture.snapshot(a);
    defer a.free(result);
    try std.testing.expectEqualStrings("retained", result);
    try std.testing.expect(capture.incomplete);
}
