const std = @import("std");
const builtin = @import("builtin");

var runtime_io: std.Io = undefined;
var runtime_environ: std.process.Environ = .empty;

pub const Mutex = struct {
    inner: std.Io.Mutex = .init,

    pub fn lock(self: *Mutex) void {
        self.inner.lockUncancelable(get());
    }

    pub fn unlock(self: *Mutex) void {
        self.inner.unlock(get());
    }
};

pub const Condition = struct {
    inner: std.Io.Condition = .init,

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        self.inner.waitUncancelable(get(), &mutex.inner);
    }

    pub fn signal(self: *Condition) void {
        self.inner.signal(get());
    }

    pub fn broadcast(self: *Condition) void {
        self.inner.broadcast(get());
    }
};

pub fn init(io_value: std.Io, environ_value: std.process.Environ) void {
    runtime_io = io_value;
    runtime_environ = environ_value;
}

pub fn get() std.Io {
    return if (builtin.is_test) std.testing.io else runtime_io;
}

pub fn environ() std.process.Environ {
    return if (builtin.is_test) std.testing.environ else runtime_environ;
}

pub fn getEnvVarOwned(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    return environ().getAlloc(allocator, key);
}

pub fn nanoTimestamp() i128 {
    return std.Io.Clock.awake.now(get()).toNanoseconds();
}

pub fn milliTimestamp() i64 {
    return @intCast(@divFloor(nanoTimestamp(), std.time.ns_per_ms));
}

pub fn waitTimeout(condition: *std.Io.Condition, mutex: *std.Io.Mutex, timeout_ns: u64) !void {
    const io = get();
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .clock = .awake,
        .raw = .fromNanoseconds(@intCast(timeout_ns)),
    });
    var epoch = condition.epoch.load(.acquire);
    const previous = condition.state.fetchAdd(.{ .waiters = 1, .signals = 0 }, .monotonic);
    std.debug.assert(previous.waiters < std.math.maxInt(u16));

    mutex.unlock(io);
    defer mutex.lockUncancelable(io);

    while (true) {
        const result = io.futexWaitTimeout(u32, &condition.epoch.raw, epoch, .{ .deadline = deadline });
        epoch = condition.epoch.load(.acquire);

        var state = condition.state.load(.monotonic);
        while (state.signals > 0) {
            state = condition.state.cmpxchgWeak(state, .{
                .waiters = state.waiters - 1,
                .signals = state.signals - 1,
            }, .acquire, .monotonic) orelse return;
        }

        result catch |err| {
            var withdrawal_state = condition.state.load(.monotonic);
            while (true) {
                std.debug.assert(withdrawal_state.waiters > 0);
                var next = withdrawal_state;
                next.waiters -= 1;
                if (next.signals > 0) next.signals -= 1;
                withdrawal_state = condition.state.cmpxchgWeak(withdrawal_state, next, .acquire, .monotonic) orelse {
                    if (withdrawal_state.signals > 0) return;
                    return err;
                };
            }
        };
        if (deadline.untilNow(io).raw.nanoseconds >= 0) {
            const removed = condition.state.fetchSub(.{ .waiters = 1, .signals = 0 }, .monotonic);
            std.debug.assert(removed.waiters > 0);
            return error.Timeout;
        }
    }
}

pub fn argsAlloc(allocator: std.mem.Allocator, args: std.process.Args) ![][]u8 {
    var iterator = try std.process.Args.Iterator.initAllocator(args, allocator);
    defer iterator.deinit();
    var result: std.ArrayList([]u8) = .empty;
    errdefer {
        for (result.items) |arg| allocator.free(arg);
        result.deinit(allocator);
    }
    while (iterator.next()) |arg| try result.append(allocator, try allocator.dupe(u8, arg));
    return result.toOwnedSlice(allocator);
}

pub fn argsFree(allocator: std.mem.Allocator, args: [][]u8) void {
    for (args) |arg| allocator.free(arg);
    allocator.free(args);
}
