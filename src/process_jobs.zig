const std = @import("std");
const io = @import("io.zig");

/// Owned process work. Only the owner accesses Future; workers never enter Lua.
pub const Job = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
    environment: ?std.process.Environ.Map,
    output_limit: usize,
    deadline_ns: i128,
    done: std.atomic.Value(bool) = .init(false),
    future: ?std.Io.Future(void) = null,
    result: ?std.process.RunResult = null,
    failure: ?anyerror = null,
    canceled: bool = false,

    pub fn create(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8, timeout_ms: usize, output_limit: usize, environment: ?*const std.process.Environ.Map) !*Job {
        if (argv.len == 0 or argv[0].len == 0) return error.EmptyCommand;
        const job = try allocator.create(Job);
        errdefer allocator.destroy(job);
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const owned = try arena.allocator().alloc([]const u8, argv.len);
        for (argv, 0..) |arg, i| {
            if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidArgument;
            owned[i] = try arena.allocator().dupe(u8, arg);
        }
        const owned_cwd = if (cwd) |path| try arena.allocator().dupe(u8, path) else null;
        var owned_environment = if (environment) |value| try value.clone(allocator) else null;
        errdefer if (owned_environment) |*value| value.deinit();
        job.* = .{
            .allocator = allocator,
            .arena = arena,
            .argv = owned,
            .cwd = owned_cwd,
            .environment = owned_environment,
            .output_limit = output_limit,
            .deadline_ns = io.nanoTimestamp() + @as(i128, @intCast(timeout_ms)) * std.time.ns_per_ms,
        };
        job.future = try io.get().concurrent(run, .{job});
        return job;
    }

    fn run(self: *Job) void {
        self.result = std.process.run(self.allocator, io.get(), .{
            .argv = self.argv,
            .cwd = if (self.cwd) |path| .{ .path = path } else .inherit,
            .environ_map = if (self.environment) |*value| value else null,
            .stdout_limit = .limited(self.output_limit),
            .stderr_limit = .limited(self.output_limit),
            .timeout = .{ .deadline = .{ .clock = .awake, .raw = .fromNanoseconds(@intCast(self.deadline_ns)) } },
            .create_no_window = true,
        }) catch |err| blk: {
            self.failure = err;
            break :blk null;
        };
        self.done.store(true, .release);
    }

    pub fn ready(self: *Job) bool {
        if (self.done.load(.acquire)) return true;
        if (io.nanoTimestamp() >= self.deadline_ns) {
            if (self.future) |*future| future.cancel(io.get());
            self.failure = error.Timeout;
            return true;
        }
        return false;
    }

    pub fn cancel(self: *Job) void {
        if (self.done.load(.acquire)) return;
        self.canceled = true;
        if (self.future) |*future| future.cancel(io.get());
        self.failure = error.Canceled;
    }

    pub fn destroy(self: *Job) void {
        if (self.future) |*future| future.cancel(io.get());
        if (self.result) |result| {
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
        }
        if (self.environment) |*value| value.deinit();
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};

test "process jobs collect output without blocking the owner" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const job = try Job.create(std.testing.allocator, &.{ "/bin/sh", "-c", "printf hello; printf problem >&2; exit 7" }, null, 2000, 4096, null);
    defer job.destroy();
    job.future.?.await(io.get());
    try std.testing.expect(job.ready());
    try std.testing.expect(job.failure == null);
    try std.testing.expectEqualStrings("hello", job.result.?.stdout);
    try std.testing.expectEqualStrings("problem", job.result.?.stderr);
    try std.testing.expectEqual(@as(u8, 7), job.result.?.term.exited);
}

test "cancel process with closed output pipes" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const job = try Job.create(std.testing.allocator, &.{ "/bin/sh", "-c", "exec 1>&- 2>&-; exec sleep 30" }, null, 2000, 4096, null);
    defer job.destroy();
    job.cancel();
    try std.testing.expect(job.ready());
    try std.testing.expectEqual(error.Canceled, job.failure.?);
}

test "process output limits and deadlines terminate work" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const verbose = try Job.create(std.testing.allocator, &.{ "/bin/sh", "-c", "printf '12345678901234567890'" }, null, 2000, 4, null);
    defer verbose.destroy();
    verbose.future.?.await(io.get());
    try std.testing.expectEqual(error.StreamTooLong, verbose.failure.?);
    const slow = try Job.create(std.testing.allocator, &.{ "/bin/sh", "-c", "exec sleep 30" }, null, 20, 4096, null);
    defer slow.destroy();
    slow.future.?.await(io.get());
    try std.testing.expectEqual(error.Timeout, slow.failure.?);
}
