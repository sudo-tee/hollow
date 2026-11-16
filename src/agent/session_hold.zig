//! Internal held watcher. Fixed five-byte stdin/stdout controls; no diagnostics
//! on stdout. A lost observer is unknown, never an empty-session indication.
const std = @import("std");
const c = @import("posix_c");
const owner = @import("session_posix.zig");
const watcher = @import("session_wait.zig");

pub const Control = struct {
    pinned: bool = true,
    generation: u32 = 1,
    empty_after: i64 = std.math.maxInt(i64),
    draining: bool = false,

    pub fn apply(self: *Control, bytes: *const [5]u8, now: i64) !bool {
        const generation = std.mem.readInt(u32, bytes[1..5], .little);
        if (generation == 0 or generation < self.generation) return error.InvalidControl;
        if (self.draining and bytes[0] != 'D') return error.InvalidControl;
        switch (bytes[0]) {
            'P' => {
                self.pinned = true;
                self.generation = generation;
                self.empty_after = std.math.maxInt(i64);
                return true;
            },
            'U', 'D' => {
                self.draining = bytes[0] == 'D';
                self.pinned = false;
                self.generation = generation;
                // Drain a possibly uncertain GUI submission before accepting an
                // empty observation. A fresh pin cancels this grace period.
                self.empty_after = now + 30_000;
                return false;
            },
            else => return error.InvalidControl,
        }
    }
};

pub fn run(a: std.mem.Allocator) !void {
    const paths = try owner.resolvePaths(a);
    defer paths.deinit(a);
    var control: Control = .{};
    var input: [5]u8 = undefined;
    var input_len: usize = 0;
    var monitor: ?watcher.Monitor = null;
    defer if (monitor) |*value| {
        value.deinit();
        _ = c.close(value.fd);
    };
    var retry_at: i64 = 0;
    var reported_failure = false;
    var drain_reported = false;
    try emit('R', 1);
    while (true) {
        const now = owner.nowMs();
        var fds = [_]c.struct_pollfd{
            .{ .fd = 0, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (!drain_reported) (if (monitor) |value| value.fd else -1) else -1, .events = c.POLLIN, .revents = 0 },
        };
        if (monitor) |value| if (value.sent < value.out_len) {
            fds[1].events |= c.POLLOUT;
        };
        const deadline = if (drain_reported) now + 1000 else if (monitor) |value| value.deadline else retry_at;
        const timeout: c_int = @intCast(@min(@max(deadline - now, 0), 1000));
        if (c.poll(&fds, fds.len, timeout) < 0) {
            if (c.__errno_location().* == c.EINTR) continue;
            return error.PollFailed;
        }
        // Parent lifetime/pins take priority over any empty-list completion.
        if (fds[0].revents != 0) {
            const n = c.read(0, input[input_len..].ptr, input.len - input_len);
            if (n == 0) return;
            if (n < 0) {
                if (c.__errno_location().* == c.EINTR) continue;
                return error.ReadFailed;
            }
            input_len += @intCast(n);
            if (input_len == input.len) {
                if (try control.apply(&input, owner.nowMs())) try emit('P', control.generation);
                // A drain needs a fresh hello that seals empty admission in
                // the guest owner, not a stale list from the pinned observer.
                if (control.draining) {
                    if (monitor) |*value| {
                        if (!value.drain) {
                            value.deinit();
                            _ = c.close(value.fd);
                            monitor = null;
                        }
                    }
                    retry_at = 0;
                    // Pin ACKs still fence fresh GUI admissions while the
                    // guest has live sessions. Empty creates remain sealed
                    // by the guest owner, including across fresh connectors.
                    try emit('P', control.generation);
                    if (drain_reported) try emit('E', control.generation);
                }
                input_len = 0;
            }
        }
        const current = owner.nowMs();
        if (monitor == null and current >= retry_at) {
            const fd = watcher.connect(paths.socket) catch {
                if (!reported_failure) try emit('F', 0);
                reported_failure = true;
                retry_at = current + 1000;
                continue;
            };
            if (fd) |socket| {
                monitor = watcher.Monitor.initMode(a, socket, current, std.math.maxInt(i64), control.draining) catch {
                    _ = c.close(socket);
                    if (!reported_failure) try emit('F', 0);
                    reported_failure = true;
                    retry_at = current + 1000;
                    continue;
                };
            } else {
                if (!control.pinned and current >= control.empty_after) {
                    try emit('E', control.generation);
                    return;
                }
                retry_at = current + 1000;
            }
        }
        if (!drain_reported) if (monitor) |*value| {
            // Held mode owns empty completion, including after reconnect.
            value.startup_deadline = if (control.pinned) std.math.maxInt(i64) else control.empty_after;
            value.seen_sessions = false;
            const done = value.step(current) catch {
                value.deinit();
                _ = c.close(value.fd);
                monitor = null;
                retry_at = current + 1000;
                if (!reported_failure) try emit('F', 0);
                reported_failure = true;
                continue;
            };
            if (done) {
                try emit('E', control.generation);
                if (!control.draining) return;
                // Retain the guest socket: do not let a racing connector
                // start a new owner between empty confirmation and teardown.
                drain_reported = true;
            }
        };
    }
}

fn emit(kind: u8, generation: u32) !void {
    var bytes: [5]u8 = undefined;
    bytes[0] = kind;
    std.mem.writeInt(u32, bytes[1..5], generation, .little);
    // Controls are atomic pipe writes (< PIPE_BUF); the native holder admits
    // one outstanding pin write and continuously drains this bounded channel.
    if (c.write(1, &bytes, bytes.len) != bytes.len) return error.WriteFailed;
}

test "held watcher pins fence empty completion and reject stale controls" {
    var state: Control = .{};
    var bytes: [5]u8 = .{ 'U', 1, 0, 0, 0 };
    try std.testing.expect(!try state.apply(&bytes, 100));
    try std.testing.expectEqual(@as(i64, 30_100), state.empty_after);
    bytes = .{ 'P', 2, 0, 0, 0 };
    try std.testing.expect(try state.apply(&bytes, 200));
    try std.testing.expect(state.pinned);
    try std.testing.expectEqual(std.math.maxInt(i64), state.empty_after);
    bytes = .{ 'U', 1, 0, 0, 0 };
    try std.testing.expectError(error.InvalidControl, state.apply(&bytes, 300));
    bytes = .{ 'X', 2, 0, 0, 0 };
    try std.testing.expectError(error.InvalidControl, state.apply(&bytes, 300));
    try std.testing.expect(state.pinned);
}

test "held watcher retirement drains pins irreversibly with the same grace" {
    var state: Control = .{};
    try std.testing.expect(!try state.apply(&.{ 'D', 1, 0, 0, 0 }, 100));
    try std.testing.expect(state.draining);
    try std.testing.expect(!state.pinned);
    try std.testing.expectEqual(@as(i64, 30_100), state.empty_after);
    try std.testing.expectError(error.InvalidControl, state.apply(&.{ 'P', 2, 0, 0, 0 }, 200));
}
