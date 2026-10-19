//! Bounded fs/exec interference source for the headless PTY experiment only.
//! No deployment, file writes, PTY policy or new protocol handlers.
const std = @import("std");
const transport = @import("host/transport.zig");
const operations = @import("host/operations.zig");

pub const Mode = enum { off, fs, exec, mixed };
pub const fs_bytes = 16384;

pub const Latency = struct {
    count: u64 = 0,
    total_ns: u64 = 0,
    max_ns: u64 = 0,
    // Bucket i contains [2^i, 2^(i+1)) nanoseconds. Not exact percentiles.
    ns_log2: [64]u64 = @splat(0),
    fn record(self: *Latency, elapsed: u64) void {
        self.count += 1;
        self.total_ns += elapsed;
        self.max_ns = @max(self.max_ns, elapsed);
        self.ns_log2[std.math.log2_int(u64, @max(1, elapsed))] += 1;
    }
};

pub const Stats = struct {
    fs: Latency = .{},
    exec: Latency = .{},
    fs_bytes: u64 = 0,
    exec_bytes: u64 = 0,
    deferred_admissions: u64 = 0,
};

pub const Bulk = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mode: Mode,
    path: ?[]const u8,
    exec_bytes: u32,
    connection: ?*transport.Connection = null,
    owned: bool = false,
    pending: [2]?u64 = .{ null, null },
    submitted_ns: [2]i128 = .{ 0, 0 },
    stats: Stats = .{},
    priming: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, mode: Mode, path: ?[]const u8, exec_bytes: u32, argv: []const []const u8, options: transport.Options, shared: ?*transport.Connection) !Bulk {
        if (exec_bytes == 0 or exec_bytes > 1048576) return error.InvalidArgument;
        if ((mode == .fs or mode == .mixed) and path == null) return error.InvalidArgument;
        return .{
            .allocator = allocator,
            .io = io,
            .mode = mode,
            .path = path,
            .exec_bytes = exec_bytes,
            .connection = if (mode == .off) null else shared orelse try transport.Connection.createWithOptions(allocator, io, argv, options),
            .owned = mode != .off and shared == null,
        };
    }

    fn clock(self: *const Bulk) i128 {
        return std.Io.Clock.awake.now(self.io).toNanoseconds();
    }

    pub fn service(self: *Bulk) !bool {
        const connection = self.connection orelse return false;
        switch (connection.status()) {
            .connecting => return false,
            .disconnected => return error.BulkDisconnected,
            .ready => {},
        }
        var progress = false;
        for (0..2) |index| {
            if ((index == 0 and self.mode == .exec) or (index == 1 and self.mode == .fs)) continue;
            if (self.pending[index]) |id| {
                if (connection.pollFor(id)) |completion| {
                    defer connection.freeCompletion(completion);
                    var result = try operations.decode(self.allocator, if (index == 0) .read else .exec, completion);
                    defer result.deinit();
                    const bytes = if (index == 0) blk: {
                        if (result.value != .read or result.value.read.bytes.len != fs_bytes or !result.value.read.eof) return error.InvalidBulkRead;
                        break :blk result.value.read.bytes;
                    } else blk: {
                        if (result.value != .exec or result.value.exec.exit_code != 0 or result.value.exec.stderr.len != 0 or result.value.exec.stdout.len != self.exec_bytes) return error.InvalidBulkExec;
                        break :blk result.value.exec.stdout;
                    };
                    for (bytes) |byte| if (byte != 0) return error.CorruptBulkOutput;
                    const elapsed: u64 = @intCast(@max(1, self.clock() - self.submitted_ns[index]));
                    if (index == 0) {
                        self.stats.fs.record(elapsed);
                        self.stats.fs_bytes += bytes.len;
                    } else {
                        self.stats.exec.record(elapsed);
                        self.stats.exec_bytes += bytes.len;
                    }
                    self.pending[index] = null;
                    progress = true;
                }
            }
            const completed = if (index == 0) self.stats.fs.count else self.stats.exec.count;
            if (self.pending[index] == null and !(self.priming and completed > 0)) {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const a = arena.allocator();
                const request = if (index == 0)
                    try operations.encode(a, .{ .read = .{ .path = self.path.?, .limit = fs_bytes } }, null)
                else blk: {
                    const command = try std.fmt.allocPrint(a, "head -c {d} /dev/zero", .{self.exec_bytes});
                    break :blk try operations.encode(a, .{ .exec = .{ .argv = &.{ "/bin/sh", "-c", command } } }, try connection.allocateStreams());
                };
                const start = self.clock();
                self.pending[index] = connection.request(request, 30000) catch |err| {
                    if (err == error.ResourceExhausted) {
                        self.stats.deferred_admissions += 1;
                        continue;
                    }
                    return err;
                };
                self.submitted_ns[index] = start;
            }
        }
        return progress;
    }

    pub fn requireProgress(self: *const Bulk) !void {
        if ((self.mode == .fs or self.mode == .mixed) and self.stats.fs.count == 0) return error.BulkStarved;
        if ((self.mode == .exec or self.mode == .mixed) and self.stats.exec.count == 0) return error.BulkStarved;
    }

    pub fn deinit(self: *Bulk) void {
        if (self.connection) |connection| {
            for (self.pending) |entry| if (entry) |id| connection.abandon(id);
            if (self.owned) connection.destroy();
        }
        self.connection = null;
        self.pending = .{ null, null };
    }
};

test "bulk latency telemetry stays fixed-size and records every completion" {
    var latency: Latency = .{};
    for ([_]u64{ 1, 3, 4, 17 }) |duration| latency.record(duration);
    try std.testing.expectEqual(@as(u64, 4), latency.count);
    try std.testing.expectEqual(@as(u64, 25), latency.total_ns);
    try std.testing.expectEqual(@as(u64, 17), latency.max_ns);
    try std.testing.expectEqual(@as(u64, 1), latency.ns_log2[0]);
    try std.testing.expectEqual(@as(u64, 1), latency.ns_log2[1]);
    try std.testing.expectEqual(@as(u64, 1), latency.ns_log2[2]);
    try std.testing.expectEqual(@as(u64, 1), latency.ns_log2[4]);
}
