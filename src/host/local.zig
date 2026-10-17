//! Native local host operations. Each Job owns its input and result storage.
const std = @import("std");
const builtin = @import("builtin");
const operations = @import("operations.zig");

pub const Job = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    input_arena: std.heap.ArenaAllocator,
    operation: operations.Operation,
    environ: std.process.Environ,
    timeout_ms: u64,
    done: std.atomic.Value(bool) = .init(false),
    cancelled: std.atomic.Value(bool) = .init(false),
    future: ?std.Io.Future(void) = null,
    result: ?operations.Result = null,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, operation: operations.Operation, timeout_ms: u64) !*Job {
        if (timeout_ms == 0 or timeout_ms > 86400000) return error.InvalidArgument;
        const job = try allocator.create(Job);
        errdefer allocator.destroy(job);
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        // Reuse protocol validation for the exact public limits; execution itself is native.
        const probe = try operations.encode(a, operation, if (operation == .exec) .{ .stdout = 2, .stderr = 4 } else null);
        a.free(probe);
        const copied = try copyOperation(a, operation);
        job.* = .{ .allocator = allocator, .io = io, .input_arena = arena, .operation = copied, .environ = environ, .timeout_ms = timeout_ms };
        job.future = try io.concurrent(run, .{job});
        return job;
    }

    pub fn ready(self: *Job) bool {
        return self.done.load(.acquire);
    }

    pub fn takeResult(self: *Job) ?operations.Result {
        if (!self.ready()) return null;
        const result = self.result;
        self.result = null;
        return result;
    }

    pub fn cancel(self: *Job) void {
        self.cancelled.store(true, .release);
    }

    pub fn destroy(self: *Job) void {
        self.cancel();
        if (self.future) |*future| future.cancel(self.io);
        if (self.result) |*result| result.deinit();
        self.input_arena.deinit();
        self.allocator.destroy(self);
    }

    fn run(self: *Job) void {
        self.supervise() catch |err| {
            if (self.result) |*result| result.deinit();
            self.result = failureResult(self.allocator, mapError(err));
        };
        self.done.store(true, .release);
    }

    fn supervise(self: *Job) !void {
        if (self.cancelled.load(.acquire)) return error.Canceled;
        const Tasks = union(enum) { work: anyerror!void, watchdog: anyerror!void };
        var results: [2]Tasks = undefined;
        var select = std.Io.Select(Tasks).init(self.io, &results);
        // Work owns result storage through self, not the Select queue: if both
        // tasks finish together, dropping the losing task cannot leak an arena.
        defer select.cancelDiscard();
        try select.concurrent(.work, work, .{self});
        try select.concurrent(.watchdog, watchdog, .{self});
        switch (try select.await()) {
            inline else => |value| try value,
        }
    }

    fn work(self: *Job) !void {
        if (self.cancelled.load(.acquire)) return error.Canceled;
        self.result = try perform(self);
    }

    fn watchdog(self: *Job) !void {
        const deadline = std.Io.Clock.awake.now(self.io).toNanoseconds() + @as(i128, self.timeout_ms) * std.time.ns_per_ms;
        while (true) {
            if (self.cancelled.load(.acquire)) return error.Canceled;
            if (std.Io.Clock.awake.now(self.io).toNanoseconds() >= deadline) return error.Timeout;
            try std.Io.sleep(self.io, .fromMilliseconds(5), .awake);
        }
    }
};

const Failure = struct { code: []const u8, message: []const u8 };
fn failureResult(allocator: std.mem.Allocator, failure: Failure) operations.Result {
    return .{ .arena = std.heap.ArenaAllocator.init(allocator), .value = .{ .failure = .{ .code = failure.code, .message = failure.message } } };
}
fn mapError(err: anyerror) Failure {
    if (err == error.FileNotFound or err == error.NotDir) return .{ .code = "not_found", .message = "path not found" };
    if (err == error.AccessDenied or err == error.PermissionDenied) return .{ .code = "permission_denied", .message = "permission denied" };
    if (err == error.Unsupported) return .{ .code = "unsupported", .message = "operation unsupported" };
    if (err == error.InvalidArgument) return .{ .code = "invalid_argument", .message = "invalid operation arguments" };
    if (err == error.StreamTooLong) return .{ .code = "output_limit", .message = "output limit exceeded" };
    if (err == error.Timeout) return .{ .code = "timeout", .message = "request timed out" };
    if (err == error.Canceled) return .{ .code = "cancelled", .message = "request cancelled" };
    if (err == error.OutOfMemory or err == error.ConcurrencyUnavailable) return .{ .code = "resource_exhausted", .message = "native resource limit" };
    return .{ .code = "io_error", .message = "native operation failed" };
}

fn copyOperation(a: std.mem.Allocator, op: operations.Operation) !operations.Operation {
    return switch (op) {
        .info => .{ .info = {} },
        .stat => |path| .{ .stat = try a.dupe(u8, path) },
        .list => |v| .{ .list = .{ .path = try a.dupe(u8, v.path), .offset = v.offset, .limit = v.limit } },
        .read => |v| .{ .read = .{ .path = try a.dupe(u8, v.path), .offset = v.offset, .limit = v.limit } },
        .exec => |v| blk: {
            const argv = try a.alloc([]const u8, v.argv.len);
            for (v.argv, 0..) |arg, i| argv[i] = try a.dupe(u8, arg);
            const env = try a.alloc(operations.Env, v.env.len);
            for (v.env, 0..) |item, i| env[i] = .{ .key = try a.dupe(u8, item.key), .value = try a.dupe(u8, item.value) };
            break :blk .{ .exec = .{ .argv = argv, .cwd = if (v.cwd) |cwd| try a.dupe(u8, cwd) else null, .env = env, .timeout_ms = v.timeout_ms, .output_limit = v.output_limit } };
        },
    };
}

fn perform(job: *Job) !operations.Result {
    var result_arena = std.heap.ArenaAllocator.init(job.allocator);
    errdefer result_arena.deinit();
    const a = result_arena.allocator();
    const value: operations.Value = switch (job.operation) {
        .info => .{ .info = try info(a, job.io, job.environ) },
        .stat => |path| .{ .stat = try stat(job.io, path) },
        .list => |opts| .{ .list = try list(a, job.io, opts) },
        .read => |opts| .{ .read = try read(a, job.io, opts) },
        .exec => |opts| .{ .exec = try exec(job, a, opts) },
    };
    return .{ .arena = result_arena, .value = value };
}

fn info(a: std.mem.Allocator, io: std.Io, environ: std.process.Environ) !operations.Info {
    const cwd = try std.process.currentPathAlloc(io, a);
    const home: []const u8 = if (builtin.os.tag == .windows) blk: {
        if (environ.getWindows(&.{ 'U', 'S', 'E', 'R', 'P', 'R', 'O', 'F', 'I', 'L', 'E', 0 })) |wide| break :blk try std.unicode.wtf16LeToWtf8Alloc(a, wide);
        if (environ.getWindows(&.{ 'H', 'O', 'M', 'E', 0 })) |wide| break :blk try std.unicode.wtf16LeToWtf8Alloc(a, wide);
        break :blk "";
    } else environ.getPosix("HOME") orelse "";
    return .{ .os = @tagName(builtin.os.tag), .arch = @tagName(builtin.cpu.arch), .cwd = cwd, .home = try a.dupe(u8, home), .protocol_major = 1, .protocol_minor = 0, .build = "local" };
}
fn stat(io: std.Io, path: []const u8) !operations.Stat {
    const s = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    const kind: []const u8 = switch (s.kind) {
        .file => "file",
        .directory => "directory",
        .sym_link => "symlink",
        else => "other",
    };
    // Return native POSIX mode where available; Windows attributes are not
    // POSIX mode bits, so mode is explicitly unavailable (0) on that backend.
    return .{ .kind = kind, .mode = if (@hasDecl(std.Io.File.Permissions, "toMode")) @intCast(s.permissions.toMode()) else 0, .size = s.size, .mtime = std.math.cast(i64, @divTrunc(s.mtime.nanoseconds, std.time.ns_per_s)) orelse 0 };
}
fn list(a: std.mem.Allocator, io: std.Io, opts: operations.ListOptions) !operations.List {
    const dir = try std.Io.Dir.cwd().openDir(io, opts.path, .{ .iterate = true });
    defer dir.close(io);
    var iter = dir.iterate();
    var entries: std.ArrayList(operations.Entry) = .empty;
    var index: u64 = 0;
    var seen: u64 = 0;
    while (try iter.next(io)) |entry| : (index += 1) {
        if (index < opts.offset) continue;
        if (seen == opts.limit) return .{ .entries = try entries.toOwnedSlice(a), .next_offset = opts.offset + seen, .eof = false };
        const kind: []const u8 = switch (entry.kind) {
            .file => "file",
            .directory => "directory",
            .sym_link => "symlink",
            else => "other",
        };
        try entries.append(a, .{ .name = try a.dupe(u8, entry.name), .kind = kind });
        seen += 1;
    }
    return .{ .entries = try entries.toOwnedSlice(a), .next_offset = null, .eof = true };
}
fn read(a: std.mem.Allocator, io: std.Io, opts: operations.ReadOptions) !operations.Read {
    const initial = try std.Io.Dir.cwd().statFile(io, opts.path, .{ .follow_symlinks = true });
    if (initial.kind != .file) return error.Unsupported;
    // Native open is cancellable via std.Io. Recheck the opened handle, not
    // only its pathname, before reading. Do not read FIFOs/devices/directories.
    const file = try std.Io.Dir.cwd().openFile(io, opts.path, .{ .allow_directory = false });
    defer file.close(io);
    const s = try file.stat(io);
    if (s.kind != .file) return error.Unsupported;
    const amount: usize = @intCast(@min(@as(u64, opts.limit), s.size -| opts.offset));
    const bytes = try a.alloc(u8, amount);
    const count = try file.readPositionalAll(io, bytes, opts.offset);
    return .{ .bytes = bytes[0..count], .eof = opts.offset + count >= s.size };
}
fn exec(job: *Job, a: std.mem.Allocator, opts: operations.ExecOptions) !operations.Exec {
    var env = try job.environ.createMap(job.allocator);
    defer env.deinit();
    for (opts.env) |item| try env.put(item.key, item.value);
    const deadline = std.Io.Clock.Timestamp.now(job.io, .awake).addDuration(.{ .raw = .{ .nanoseconds = @as(i96, @intCast(opts.timeout_ms)) * std.time.ns_per_ms }, .clock = .awake });
    const process_result = try std.process.run(job.allocator, job.io, .{ .argv = opts.argv, .cwd = if (opts.cwd) |cwd| .{ .path = cwd } else .inherit, .environ_map = &env, .stdout_limit = .limited(opts.output_limit), .stderr_limit = .limited(opts.output_limit), .timeout = .{ .deadline = deadline }, .create_no_window = true });
    defer job.allocator.free(process_result.stdout);
    defer job.allocator.free(process_result.stderr);
    if (process_result.stdout.len + process_result.stderr.len > opts.output_limit) return error.StreamTooLong;
    return .{ .exit_code = switch (process_result.term) {
        .exited => |code| code,
        .signal => |sig| 128 + @as(i32, @intCast(@intFromEnum(sig))),
        else => -1,
    }, .stdout = try a.dupe(u8, process_result.stdout), .stderr = try a.dupe(u8, process_result.stderr) };
}
