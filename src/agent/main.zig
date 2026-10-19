//! Universal Linux agent. Stdout is exclusively framed RPC, never diagnostics.
const std = @import("std");
const builtin = @import("builtin");
const p = @import("protocol.zig");
const fs = @import("fs.zig");
const ex = @import("exec.zig");
const queue_profile = @import("queue_profile.zig");
const bulk_delivery = @import("bulk_delivery.zig");
const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("poll.h");
    @cInclude("signal.h");
    @cInclude("sys/signalfd.h");
    @cInclude("sys/wait.h");
    @cInclude("sys/prctl.h");
    @cInclude("errno.h");
    @cInclude("stdlib.h");
});
const A = std.heap.page_allocator;
const max_jobs = 16;
const queue_limit = 4 * 1024 * 1024;
// Bound bulk DATA ahead of newly dispatched control responses. Partial frames
// remain serialized by the existing single stdout writer.
const pty_batch_limit = 65536 + 4 * p.header_len;

const Profile = struct {
    polls: u64 = 0,
    poll_ns: u64 = 0,
    ready_polls: u64 = 0,
    ready_poll_ns: u64 = 0,
    ready_stalls: u64 = 0,
    writes: u64 = 0,
    bytes_written: u64 = 0,
    data_frames: u64 = 0,
    window_updates: u64 = 0,
    max_queued: usize = 0,
    max_pty_buffered: usize = 0,
};

fn profileClock() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const Agent = struct {
    input: std.ArrayList(u8) = .empty,
    output: std.ArrayList(u8) = .empty,
    sent: usize = 0,
    jobs: [max_jobs]?ex.Job = .{null} ** max_jobs,
    greeted: bool = false,
    closing: bool = false,
    last_id: u64 = 0,
    last_stream: u64 = 0,
    last_write: u64 = 0,
    next_pty: usize = 0,
    nonce: [32]u8 = undefined,
    data_limit: usize = p.max_data,
    payload_limit: usize = p.max_payload,
    job_limit: usize = max_jobs,
    worker: bool = false,
    signal_fd: c_int = -1,
    agent_pid: c_int = -1,
    experimental_pty: bool = false,
    profiling: bool = false,
    profile: Profile = .{},
    queue_profile: ?*queue_profile.Profiler = null,
    bounded_bulk: bool = false,
    deliveries: [max_jobs]bulk_delivery.State = @splat(.{}),
    next_output: usize = 0,

    fn usesBoundedBulk(self: *const Agent) bool {
        return self.bounded_bulk and self.experimental_pty;
    }

    fn releaseJob(self: *Agent, index: usize) void {
        self.jobs[index].?.deinit();
        self.jobs[index] = null;
        self.deliveries[index] = .{};
    }

    fn tickJob(self: *Agent, index: usize, now: u64) void {
        const job = &self.jobs[index].?;
        if (self.deliveries[index].ready) {
            // This child and its containment have already completed. Retaining
            // captured bytes must not extend process-group/PID ownership.
            std.debug.assert(job.reaped);
            if (job.reason == null and now >= job.deadline) job.cancel(.timeout, now);
        } else job.tick(now);
    }

    fn frame(self: *Agent, kind: p.Kind, id: u64, sid: u64, payload: []const u8) !void {
        return self.frameClass(kind, id, sid, payload, .other);
    }

    fn frameClass(self: *Agent, kind: p.Kind, id: u64, sid: u64, payload: []const u8, class: queue_profile.Class) !void {
        if (payload.len > self.payload_limit) return error.ResourceExhausted;
        const header = try (p.Header{ .kind = kind, .request_id = id, .stream_id = sid, .payload_len = @intCast(payload.len) }).encode();
        if (self.output.items.len + header.len + payload.len > queue_limit) return error.ResourceExhausted;
        if (self.output.items.len == self.sent) self.last_write = nowMs();
        try self.output.ensureUnusedCapacity(A, header.len + payload.len);
        self.output.appendSliceAssumeCapacity(&header);
        self.output.appendSliceAssumeCapacity(payload);
        if (self.queue_profile) |profile| profile.enqueue(class, header.len + payload.len, profileClock());
        if (self.profiling) {
            self.profile.max_queued = @max(self.profile.max_queued, self.output.items.len - self.sent);
            if (kind == .data) self.profile.data_frames += 1;
        }
    }

    fn sendError(self: *Agent, id: u64, err: anyerror) !void {
        const code = errorCode(err);
        var buf: [256]u8 = undefined;
        const body = try std.fmt.bufPrint(&buf, "{{\"code\":\"{s}\",\"message\":\"request failed\",\"truncated\":true}}", .{code});
        try self.frame(.error_response, id, 0, body);
    }

    fn disconnect(self: *Agent, now: u64) void {
        self.closing = true;
        self.output.clearRetainingCapacity();
        self.sent = 0;
        if (self.queue_profile) |profile| profile.discard();
        for (&self.jobs) |*entry| if (entry.*) |*job| job.cancel(.cancelled, now);
    }

    fn dispatch(self: *Agent, h: p.Header, bytes: []const u8, now: u64) !void {
        const started = if (self.queue_profile != null) profileClock() else 0;
        defer if (self.queue_profile) |profile| profile.stats.dispatch_ns.record(profileClock() - started);
        if (self.greeted and self.experimental_pty and h.kind == .window_update) {
            if (self.profiling) self.profile.window_updates += 1;
            if (bytes.len != 8) return error.ProtocolMismatch;
            const amount = try p.decodeWindowUpdate(@ptrCast(bytes.ptr));
            for (&self.jobs) |*entry| if (entry.*) |*job| {
                if (job.id == h.request_id) {
                    if (!job.pty or job.streams[0] != h.stream_id) return error.ProtocolMismatch;
                    if (amount > 1024 * 1024 - job.credit) return error.ProtocolMismatch;
                    job.credit += @intCast(amount);
                    return;
                }
            };
            // Consumed-byte acknowledgements can race the terminal response.
            if (h.request_id > 0 and h.request_id <= self.last_id and h.stream_id > 0 and h.stream_id <= self.last_stream) return;
            return error.ProtocolMismatch;
        }
        if (h.stream_id != 0) return error.ProtocolMismatch;
        if (!self.greeted) {
            if (h.kind != .hello or h.request_id != 0) return error.ProtocolMismatch;
            var arena = std.heap.ArenaAllocator.init(A);
            defer arena.deinit();
            const hello = std.json.parseFromSlice(std.json.Value, arena.allocator(), bytes, .{}) catch return error.ProtocolMismatch;
            if (try integer(hello.value, "major", 0) != 1) return error.ProtocolMismatch;
            _ = try integer(hello.value, "minor", 0);
            const payload_limit = @min(p.max_payload, try integer(hello.value, "max_payload", p.max_payload));
            const data_limit = @min(p.max_data, try integer(hello.value, "max_data", p.max_data));
            const streams = @min(@as(u64, 128), try integer(hello.value, "max_streams", 128));
            const requests = @min(@as(u64, 256), try integer(hello.value, "max_in_flight", 256));
            if (payload_limit < 1024 or data_limit < 1024 or streams < 2 or requests == 0) return error.ProtocolMismatch;
            self.payload_limit = @intCast(payload_limit);
            self.data_limit = @intCast(@min(data_limit, payload_limit));
            self.job_limit = @intCast(@min(max_jobs, @min(streams / 2, requests)));
            if (hello.value.object.get("experimental_pty")) |enabled| {
                if (enabled != .bool) return error.ProtocolMismatch;
                self.experimental_pty = enabled.bool;
            }
            var ack: [768]u8 = undefined;
            const body = try std.fmt.bufPrint(&ack, "{{\"major\":1,\"minor\":0,\"connection_nonce\":\"{s}\",\"max_payload\":{d},\"max_data\":{d},\"max_streams\":{d},\"max_in_flight\":{d},\"max_exec\":{d},\"monotonic_ids\":true,\"capabilities\":[\"fs.stat\",\"fs.list\",\"fs.read\",\"exec\",\"cancel\"{s}]}}", .{ self.nonce, self.payload_limit, self.data_limit, streams, requests, self.job_limit, if (self.experimental_pty) ",\"experimental.pty\"" else "" });
            try self.frame(.hello_ack, 0, 0, body);
            self.greeted = true;
            if (self.queue_profile) |profile| profile.stats.bounded_bulk = self.usesBoundedBulk();
            return;
        }
        switch (h.kind) {
            .ping => {
                if (bytes.len > 64) return error.ProtocolMismatch;
                try self.frame(.pong, h.request_id, 0, bytes);
            },
            .cancel => {
                if (h.request_id == 0 or bytes.len != 0) return error.ProtocolMismatch;
                // A completed/unknown cancellation is a harmless race, not a
                // second terminal response for the original request.
                for (&self.jobs) |*entry| if (entry.*) |*job| {
                    if (job.id == h.request_id) job.cancel(.cancelled, now);
                };
            },
            .request => {
                if (h.request_id == 0 or h.request_id <= self.last_id) return error.ProtocolMismatch;
                self.last_id = h.request_id;
                if (self.output.items.len > 2 * 1024 * 1024) {
                    try self.sendError(h.request_id, error.ResourceExhausted);
                    return;
                }
                self.request(h.request_id, bytes, now) catch |err| try self.sendError(h.request_id, err);
            },
            else => return error.ProtocolMismatch,
        }
    }

    fn request(self: *Agent, id: u64, bytes: []const u8, now: u64) anyerror!void {
        const started = if (self.queue_profile != null) profileClock() else 0;
        var arena = std.heap.ArenaAllocator.init(A);
        defer arena.deinit();
        const a = arena.allocator();
        const parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{ .max_value_len = p.max_payload }) catch return error.InvalidArgument;
        const value = parsed.value;
        const op = try string(value, "op");
        defer if (self.queue_profile) |profile| {
            const class: queue_profile.Request = if (std.mem.eql(u8, op, "PTY_INPUT")) .pty_input else if (std.mem.eql(u8, op, "PTY_RESIZE")) .pty_resize else if (std.mem.eql(u8, op, "PTY_CLOSE")) .pty_close else if (std.mem.eql(u8, op, "EXEC")) .exec else .filesystem;
            // PTY_SPAWN is covered by dispatch_ns, not filesystem dispatch.
            if (!std.mem.eql(u8, op, "PTY_SPAWN")) profile.stats.request_handler_ns[@intFromEnum(class)].record(profileClock() - started);
        };
        if (std.mem.startsWith(u8, op, "PTY_")) {
            if (!self.experimental_pty) return error.Unsupported;
            if (std.mem.eql(u8, op, "PTY_SPAWN")) return self.execRequest(a, id, value, now);
            return self.ptyControl(a, id, op, value, now);
        }
        if (std.mem.eql(u8, op, "EXEC")) return self.execRequest(a, id, value, now);
        // Bounded worker processes keep slow/network filesystem syscalls off
        // the transport loop. They run these exact same operation handlers.
        if (!self.worker) return self.spawnFilesystem(id, bytes, now);
        if (std.mem.eql(u8, op, "HOST_INFO")) {
            var cwd_buf: [4096]u8 = undefined;
            const cwd = c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.IoError;
            const home_ptr = c.getenv("HOME");
            const home = if (home_ptr) |ptr| std.mem.span(ptr) else "";
            const body = try std.fmt.allocPrint(a, "{{\"os\":\"linux\",\"arch\":\"{s}\",\"protocol_major\":1,\"protocol_minor\":0,\"build\":\"agent-v1\",\"agent_pid\":{d},\"exec_supervised\":true,\"cwd_b64\":\"{s}\",\"home_b64\":\"{s}\",\"max_exec\":16,\"max_output\":1048576}}", .{ @tagName(builtin.cpu.arch), self.agent_pid, try encode(a, std.mem.span(cwd)), try encode(a, home) });
            return self.frame(.response, id, 0, body);
        }
        if (!std.mem.eql(u8, op, "FS_STAT") and !std.mem.eql(u8, op, "FS_LIST") and !std.mem.eql(u8, op, "FS_READ")) return error.Unsupported;
        const path = decode(a, try string(value, "path_b64"), 4096) catch return error.InvalidPath;
        if (std.mem.eql(u8, op, "FS_STAT")) {
            const st = try fs.stat(path);
            const body = try std.fmt.allocPrint(a, "{{\"kind\":\"{s}\",\"mode\":{d},\"size\":{d},\"mtime\":{d}}}", .{ st.kind, st.mode, st.size, st.mtime });
            return self.frame(.response, id, 0, body);
        }
        const offset = try integer(value, "offset", 0);
        if (std.mem.eql(u8, op, "FS_LIST")) {
            const names = try fs.list(a, path, @intCast(offset), @intCast(try integer(value, "limit", 256)));
            var body: std.Io.Writer.Allocating = .init(a);
            try body.writer.writeAll("{\"entries\":[");
            for (names, 0..) |name, i| {
                if (i != 0) try body.writer.writeAll(",");
                try body.writer.print("{{\"name_b64\":\"{s}\"}}", .{try encode(a, name)});
            }
            try body.writer.print("],\"next_offset\":{d},\"done\":{}}}", .{ offset + names.len, names.len < try integer(value, "limit", 256) });
            return self.frame(.response, id, 0, body.written());
        }
        const limit = try integer(value, "limit", p.max_data);
        const data = try fs.read(a, path, offset, @intCast(limit));
        const st = try fs.stat(path);
        const eof = data.len < limit or (st.size >= 0 and offset + data.len >= @as(u64, @intCast(st.size)));
        var data_offset: usize = 0;
        while (data_offset < data.len) {
            const count = @min(self.data_limit, data.len - data_offset);
            try self.frame(.data, id, 0, data[data_offset..][0..count]);
            data_offset += count;
        }
        const body = try std.fmt.allocPrint(a, "{{\"bytes\":{d},\"eof\":{}}}", .{ data.len, eof });
        try self.frame(.response, id, 0, body);
    }

    fn spawnFilesystem(self: *Agent, id: u64, bytes: []const u8, now: u64) !void {
        var active: usize = 0;
        for (self.jobs) |entry| if (entry != null) {
            active += 1;
        };
        if (active >= self.job_limit) return error.ResourceExhausted;
        var pair: [2]c_int = undefined;
        if (c.pipe2(&pair, c.O_CLOEXEC) != 0) return error.ResourceExhausted;
        errdefer {
            _ = c.close(pair[0]);
            _ = c.close(pair[1]);
        }
        const parent = c.getpid();
        const pid = c.fork();
        if (pid < 0) return error.ResourceExhausted;
        if (pid == 0) {
            _ = c.setpgid(0, 0);
            _ = c.prctl(c.PR_SET_PDEATHSIG, @as(c_ulong, c.SIGKILL), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0));
            if (c.getppid() != parent) c._exit(126);
            var mask: c.sigset_t = undefined;
            _ = c.sigemptyset(&mask);
            _ = c.sigprocmask(c.SIG_SETMASK, &mask, null);
            _ = c.signal(c.SIGPIPE, null);
            _ = c.close(0);
            _ = c.dup2(pair[1], 1);
            _ = c.close(pair[0]);
            _ = c.close(pair[1]);
            if (self.signal_fd >= 0) _ = c.close(self.signal_fd);
            for (self.jobs) |entry| if (entry) |job| for (job.fds) |fd| {
                if (fd >= 0) _ = c.close(fd);
            };
            var child = Agent{ .worker = true, .payload_limit = self.payload_limit, .data_limit = self.data_limit, .agent_pid = self.agent_pid };
            child.request(id, bytes, now) catch |err| child.sendError(id, err) catch c._exit(126);
            var sent: usize = 0;
            while (sent < child.output.items.len) {
                const n = c.write(1, child.output.items.ptr + sent, child.output.items.len - sent);
                if (n < 0) {
                    if (c.__errno_location().* == c.EINTR) continue;
                    c._exit(126);
                }
                sent += @intCast(n);
            }
            c._exit(0);
        }
        _ = c.close(pair[1]);
        _ = c.setpgid(pid, pid);
        // A pipe read end has separate status flags from its blocking writer.
        const flags = c.fcntl(pair[0], c.F_GETFL, @as(c_int, 0));
        _ = c.fcntl(pair[0], c.F_SETFL, flags | c.O_NONBLOCK);
        for (&self.jobs) |*entry| if (entry.* == null) {
            entry.* = .{ .id = id, .pid = pid, .fds = .{ pair[0], -1, -1 }, .limit = p.max_payload, .streams = .{ 0, 0 }, .deadline = now + 30000, .rpc_worker = true };
            return;
        };
        unreachable;
    }

    fn execRequest(self: *Agent, a: std.mem.Allocator, id: u64, value: std.json.Value, now: u64) !void {
        const is_pty = std.mem.eql(u8, try string(value, "op"), "PTY_SPAWN");
        const av = value.object.get("argv_b64") orelse return error.InvalidArgv;
        if (av != .array or av.array.items.len == 0 or av.array.items.len > 4096) return error.InvalidArgv;
        const argv = try a.alloc([]const u8, av.array.items.len);
        for (av.array.items, 0..) |arg, i| {
            if (arg != .string) return error.InvalidArgv;
            argv[i] = decode(a, arg.string, 131072) catch return error.InvalidArgv;
        }
        const cwd = if (value.object.get("cwd_b64")) |v| blk: {
            if (v != .string) return error.InvalidPath;
            break :blk decode(a, v.string, 4096) catch return error.InvalidPath;
        } else null;
        var env: std.ArrayList(ex.Env) = .empty;
        if (value.object.get("env_b64")) |v| {
            if (v != .array or v.array.items.len > 4096) return error.InvalidArgv;
            for (v.array.items) |item| try env.append(a, .{
                .key = decode(a, string(item, "key_b64") catch return error.InvalidArgv, 131072) catch return error.InvalidArgv,
                .value = decode(a, string(item, "value_b64") catch return error.InvalidArgv, 131072) catch return error.InvalidArgv,
            });
        }
        const osid = try integer(value, "stdout_stream_id", 0);
        const esid = try integer(value, "stderr_stream_id", 0);
        if (osid == 0 or esid == 0 or osid % 2 != 0 or esid % 2 != 0 or osid == esid or @min(osid, esid) <= self.last_stream) return error.InvalidArgument;
        const timeout = try integer(value, "timeout_ms", if (is_pty) 86400000 else 30000);
        const limit = try integer(value, "output_limit", 1024 * 1024);
        if (timeout == 0 or timeout > 86400000 or limit > 1024 * 1024) return error.InvalidArgument;
        const rows = try integer(value, "rows", 24);
        const cols = try integer(value, "cols", 80);
        const credit = try integer(value, "output_credit", 65536);
        if (is_pty and (rows == 0 or rows > 65535 or cols == 0 or cols > 65535 or credit > 1024 * 1024)) return error.InvalidArgument;
        var active: usize = 0;
        for (self.jobs) |entry| if (entry != null) {
            active += 1;
        };
        if (active >= self.job_limit) return error.ResourceExhausted;
        var inherited_fds: [1 + max_jobs * 3]c_int = undefined;
        inherited_fds[0] = self.signal_fd;
        for (self.jobs, 0..) |entry, i| for (0..3) |j| {
            inherited_fds[1 + i * 3 + j] = if (entry) |job| job.fds[j] else -1;
        };
        for (&self.jobs) |*entry| if (entry.* == null) {
            const job = try ex.spawn(id, .{ .argv = argv, .cwd = cwd, .env = env.items, .timeout_ms = timeout, .output_limit = @intCast(limit), .stdout_stream = osid, .stderr_stream = esid, .inherited_fds = &inherited_fds, .pty_size = if (is_pty) .{ .rows = @intCast(rows), .cols = @intCast(cols) } else null, .output_credit = @intCast(if (is_pty) credit else 0) }, now);
            entry.* = job;
            self.last_stream = @max(osid, esid);
            return;
        };
        return error.ResourceExhausted;
    }

    fn ptyControl(self: *Agent, a: std.mem.Allocator, id: u64, op: []const u8, value: std.json.Value, now: u64) !void {
        const session = try integer(value, "session_id", 0);
        for (&self.jobs) |*entry| if (entry.*) |*job| {
            if (!job.pty or job.id != session) continue;
            if (job.reason != null or job.reaped or job.fds[0] < 0) return error.NotFound;
            if (std.mem.eql(u8, op, "PTY_INPUT")) {
                const text = try string(value, "bytes_b64");
                const decoder = std.base64.standard.Decoder;
                const size = decoder.calcSizeForSlice(text) catch return error.InvalidArgument;
                if (size > 16384) return error.InvalidArgument;
                if (size > 65536 - job.input.items.len) return error.ResourceExhausted;
                const data = try a.alloc(u8, size);
                decoder.decode(data, text) catch return error.InvalidArgument;
                try job.input.appendSlice(A, data);
            } else if (std.mem.eql(u8, op, "PTY_RESIZE")) {
                const rows = try integer(value, "rows", 0);
                const cols = try integer(value, "cols", 0);
                if (rows == 0 or rows > 65535 or cols == 0 or cols > 65535) return error.InvalidArgument;
                try job.resize(@intCast(rows), @intCast(cols));
            } else if (std.mem.eql(u8, op, "PTY_CLOSE")) {
                job.cancel(.cancelled, now);
            } else return error.Unsupported;
            const class: queue_profile.Class = if (std.mem.eql(u8, op, "PTY_INPUT")) .pty_input_ack else if (std.mem.eql(u8, op, "PTY_RESIZE")) .pty_resize_ack else .pty_close_ack;
            return self.frameClass(.response, id, 0, "{}", class);
        };
        return error.NotFound;
    }

    fn streamPty(self: *Agent, job: *ex.Job, quantum: usize) !void {
        if (!job.pty or job.reason != null or self.closing) return;
        if (self.profiling) self.profile.max_pty_buffered = @max(self.profile.max_pty_buffered, job.stdout.items.len);
        var budget = quantum;
        while (job.stdout.items.len > 0 and job.credit > 0 and budget > 0 and self.output.items.len + p.header_len < pty_batch_limit) {
            const count = @min(@min(self.data_limit, budget), @min(pty_batch_limit - self.output.items.len - p.header_len, @min(job.credit, job.stdout.items.len)));
            try self.frameClass(.data, job.id, job.streams[0], job.stdout.items[0..count], .pty_data);
            job.credit -= count;
            budget -= count;
            std.mem.copyForwards(u8, job.stdout.items, job.stdout.items[count..]);
            job.stdout.items.len -= count;
        }
    }

    fn schedulePtys(self: *Agent) !void {
        var count: usize = 0;
        for (self.jobs) |entry| if (entry) |job| {
            if (job.pty and job.reason == null and job.stdout.items.len > 0 and job.credit > 0) count += 1;
        };
        const start = self.next_pty;
        for (0..max_jobs) |offset| {
            const index = (start + offset) % max_jobs;
            if (self.jobs[index]) |*job| {
                const before = self.output.items.len;
                try self.streamPty(job, if (count <= 1) 65536 else 16384);
                if (self.output.items.len > before) self.next_pty = (index + 1) % max_jobs;
            }
            if (self.output.items.len + p.header_len >= pty_batch_limit) break;
        }
    }

    fn bulkFits(self: *Agent, size: usize) bool {
        const fits = bulk_delivery.fitsBatch(self.output.items.len, size, pty_batch_limit, queue_limit);
        if (self.queue_profile) |profile| if (!fits) {
            profile.stats.bulk_deferred += 1;
        };
        return fits;
    }

    fn bulkQueued(self: *Agent, size: usize) void {
        if (self.queue_profile) |profile| {
            profile.stats.bulk_frames += 1;
            if (size > pty_batch_limit) profile.stats.bulk_oversized_frames += 1;
            profile.stats.bulk_max_queued_bytes = @max(profile.stats.bulk_max_queued_bytes, self.output.items.len - self.sent);
        }
    }

    // Return false only when the next whole frame needs output to drain first.
    fn streamBulk(self: *Agent, index: usize) !bool {
        const job = &self.jobs[index].?;
        const state = &self.deliveries[index];
        if (job.reason != null or job.launch_error != null or (job.rpc_worker and (job.exitCode() != 0 or job.stdout.items.len == 0))) {
            if (!self.bulkFits(p.header_len + 256)) return false;
            try self.finish(job);
            self.releaseJob(index);
            return true;
        }
        if (job.rpc_worker) {
            const next = bulk_delivery.workerFrame(job.stdout.items, state.worker_offset, job.id, self.payload_limit, self.data_limit) catch {
                if (!self.bulkFits(p.header_len + 256)) return false;
                try self.sendError(job.id, error.IoError);
                self.releaseJob(index);
                return true;
            };
            if (!self.bulkFits(next.bytes.len)) return false;
            if (self.output.items.len == self.sent) self.last_write = nowMs();
            try self.output.appendSlice(A, next.bytes);
            if (self.queue_profile) |profile| profile.enqueue(.filesystem_reply, next.bytes.len, profileClock());
            self.bulkQueued(next.bytes.len);
            state.worker_offset += next.bytes.len;
            if (next.terminal) self.releaseJob(index);
            return true;
        }
        const streams = [_][]const u8{ job.stdout.items, job.stderr.items };
        const offsets = [_]*usize{ &state.stdout_offset, &state.stderr_offset };
        for (streams, job.streams, offsets) |bytes, sid, offset| {
            if (offset.* >= bytes.len) continue;
            const count = @min(self.data_limit, bytes.len - offset.*);
            if (!self.bulkFits(p.header_len + count)) return false;
            try self.frameClass(.data, job.id, sid, bytes[offset.*..][0..count], .exec_data);
            self.bulkQueued(p.header_len + count);
            offset.* += count;
            return true;
        }
        if (!self.bulkFits(p.header_len + 256)) return false;
        const before = self.output.items.len;
        try self.execResponse(job);
        self.bulkQueued(self.output.items.len - before);
        self.releaseJob(index);
        return true;
    }

    fn scheduleOutputs(self: *Agent) !void {
        if (!self.usesBoundedBulk()) return self.schedulePtys();
        if (self.closing) return;
        var ready: usize = 0;
        for (self.jobs, self.deliveries) |entry, state| if (entry) |job| {
            if (state.ready or (job.pty and job.reason == null and job.stdout.items.len > 0 and job.credit > 0)) ready += 1;
        };
        const start = self.next_output;
        for (0..max_jobs) |offset| {
            const index = (start + offset) % max_jobs;
            if (self.jobs[index]) |*job| {
                const before = self.output.items.len;
                if (job.pty) {
                    try self.streamPty(job, if (ready <= 1) 65536 else 16384);
                } else if (self.deliveries[index].ready) {
                    if (!try self.streamBulk(index)) {
                        // Do not let small PTY chunks continually steal space from
                        // an indivisible filesystem metadata frame.
                        self.next_output = index;
                        break;
                    }
                }
                if (self.output.items.len > before) self.next_output = (index + 1) % max_jobs;
            }
            if (self.output.items.len + p.header_len >= pty_batch_limit) break;
        }
    }

    fn preparePoll(self: *Agent, now: u64) !usize {
        var active: usize = 0;
        for (&self.jobs, 0..) |*entry, index| if (entry.* != null) {
            active += 1;
            self.tickJob(index, now);
            // WINDOW_UPDATE is dispatched at the end of the previous turn.
            // A full PTY capture is not polled for more input, so restored credit
            // must make buffered DATA writable before we can block in poll().
        };
        try self.scheduleOutputs();
        return active;
    }

    fn finish(self: *Agent, job: *ex.Job) !void {
        if (self.queue_profile) |profile| if (job.pty) {
            // Snapshot precedes the terminal response; queued records are censored.
            // Diagnostic serialization failure must never change RPC semantics.
            var storage: [65536]u8 = undefined;
            var output: std.Io.Writer = .fixed(&storage);
            output.writeAll("AGENT_QUEUE_PROFILE ") catch unreachable;
            std.json.Stringify.value(profile.stats, .{}, &output) catch return self.finishWithoutQueueProfile(job);
            output.writeAll("\n") catch return self.finishWithoutQueueProfile(job);
            _ = c.write(2, output.buffered().ptr, output.buffered().len);
        };
        return self.finishWithoutQueueProfile(job);
    }

    fn finishWithoutQueueProfile(self: *Agent, job: *ex.Job) !void {
        if (self.profiling and job.pty) {
            // Explicit diagnostic opt-in; never write telemetry to protocol stdout.
            var storage: [1024]u8 = undefined;
            var output: std.Io.Writer = .fixed(&storage);
            try output.writeAll("AGENT_PROFILE ");
            try std.json.Stringify.value(self.profile, .{}, &output);
            try output.writeAll("\n");
            _ = c.write(2, output.buffered().ptr, output.buffered().len);
        }
        if (job.reason) |reason| return self.sendError(job.id, switch (reason) {
            .cancelled => error.Cancelled,
            .timeout => error.Timeout,
            .output_limit => error.OutputLimit,
        });
        if (job.launch_error) |e| return self.sendError(job.id, switch (e) {
            c.ENOENT, c.ENOTDIR => error.NotFound,
            c.EACCES, c.EPERM => error.PermissionDenied,
            else => error.InvalidArgv,
        });
        if (job.rpc_worker) {
            if (job.exitCode() != 0 or job.stdout.items.len == 0) return self.sendError(job.id, error.IoError);
            if (self.output.items.len + job.stdout.items.len > queue_limit) return error.ResourceExhausted;
            if (self.output.items.len == self.sent) self.last_write = nowMs();
            try self.output.appendSlice(A, job.stdout.items);
            if (self.queue_profile) |profile| profile.enqueue(.filesystem_reply, job.stdout.items.len, profileClock());
            return;
        }
        if (job.pty) {
            var exit: [64]u8 = undefined;
            return self.frame(.response, job.id, 0, try std.fmt.bufPrint(&exit, "{{\"exit_code\":{d}}}", .{job.exitCode()}));
        }
        const streams = [_][]const u8{ job.stdout.items, job.stderr.items };
        for (streams, job.streams) |bytes, sid| {
            var offset: usize = 0;
            while (offset < bytes.len) {
                const count = @min(self.data_limit, bytes.len - offset);
                try self.frameClass(.data, job.id, sid, bytes[offset..][0..count], .exec_data);
                offset += count;
            }
        }
        return self.execResponse(job);
    }

    fn execResponse(self: *Agent, job: *const ex.Job) !void {
        var buf: [256]u8 = undefined;
        const body = try std.fmt.bufPrint(&buf, "{{\"exit_code\":{d},\"stdout_bytes\":{d},\"stderr_bytes\":{d},\"truncated\":false}}", .{ job.exitCode(), job.stdout.items.len, job.stderr.items.len });
        try self.frame(.response, job.id, 0, body);
    }
};

pub fn main() !void {
    var agent = Agent{ .agent_pid = c.getpid() };
    agent.bounded_bulk = c.getenv("HOLLOW_AGENT_BOUNDED_BULK") != null;
    if (c.getenv("HOLLOW_AGENT_QUEUE_PROFILE") != null) {
        agent.queue_profile = try A.create(queue_profile.Profiler);
        agent.queue_profile.?.* = .{};
    }
    defer if (agent.queue_profile) |profile| A.destroy(profile);
    agent.profiling = c.getenv("HOLLOW_AGENT_PROFILE") != null;
    var random: [16]u8 = undefined;
    var random_count: usize = 0;
    while (random_count < random.len) {
        const result = std.os.linux.getrandom(random[random_count..].ptr, random.len - random_count, 0);
        const err = std.os.linux.errno(result);
        if (err == .INTR) continue;
        if (err != .SUCCESS or result == 0) return error.IoError;
        random_count += result;
    }
    agent.nonce = std.fmt.bytesToHex(random, .lower);
    defer agent.input.deinit(A);
    defer agent.output.deinit(A);
    // Block before spawning children; signalfd is the only SIGCHLD consumer.
    var signals: c.sigset_t = undefined;
    _ = c.sigemptyset(&signals);
    _ = c.sigaddset(&signals, c.SIGCHLD);
    _ = c.sigaddset(&signals, c.SIGTERM);
    _ = c.sigaddset(&signals, c.SIGINT);
    if (c.sigprocmask(c.SIG_BLOCK, &signals, null) != 0) return error.IoError;
    const signal_fd = c.signalfd(-1, &signals, c.SFD_CLOEXEC | c.SFD_NONBLOCK);
    if (signal_fd < 0) return error.IoError;
    defer _ = c.close(signal_fd);
    agent.signal_fd = signal_fd;
    _ = c.signal(c.SIGPIPE, ignoreSignal);
    _ = c.prctl(c.PR_SET_CHILD_SUBREAPER, @as(c_ulong, 1), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0));
    try nonblocking(0);
    try nonblocking(1);
    // Fatal parser/allocator failures must also terminate and reap jobs.
    defer cleanup(&agent);
    agent.last_write = nowMs();
    while (true) {
        const now = nowMs();
        const active = try agent.preparePoll(now);
        if (agent.closing and active == 0 and agent.output.items.len == agent.sent) break;
        var fds: [3 + max_jobs * 3]c.struct_pollfd = undefined;
        fds[0] = .{ .fd = if (agent.closing) -1 else 0, .events = c.POLLIN, .revents = 0 };
        fds[1] = .{ .fd = 1, .events = if (agent.output.items.len > agent.sent) c.POLLOUT else 0, .revents = 0 };
        fds[2] = .{ .fd = signal_fd, .events = c.POLLIN, .revents = 0 };
        for (agent.jobs, 0..) |entry, i| for (0..3) |j| {
            const events: c_short = if (entry) |job| if (job.pty and j == 0) @as(c_short, if (job.stdout.items.len < 65536 or job.reason != null) c.POLLIN else 0) | @as(c_short, if (job.input.items.len > 0 and job.reason == null) c.POLLOUT else 0) else c.POLLIN else c.POLLIN;
            fds[3 + i * 3 + j] = .{ .fd = if (entry) |job| if (job.pty and j == 0 and events == 0) -1 else job.fds[j] else -1, .events = events, .revents = 0 };
        };
        var sendable = false;
        if (agent.profiling and !agent.closing and agent.output.items.len + p.header_len < pty_batch_limit) {
            for (agent.jobs) |entry| if (entry) |job| {
                if (job.pty and job.reason == null and job.stdout.items.len > 0 and job.credit > 0) sendable = true;
            };
        }
        const buffered_command = agent.queue_profile != null and hasCompleteCommand(agent.input.items);
        const poll_start = if (agent.profiling or agent.queue_profile != null) profileClock() else 0;
        const polled = c.poll(&fds, fds.len, 20);
        if (agent.queue_profile) |profile| {
            const duration = profileClock() - poll_start;
            profile.stats.poll_ns.record(duration);
            if (buffered_command) profile.stats.poll_with_complete_command_ns.record(duration);
        }
        if (agent.profiling) {
            const duration = profileClock() - poll_start;
            agent.profile.polls += 1;
            agent.profile.poll_ns += duration;
            if (sendable) {
                agent.profile.ready_polls += 1;
                agent.profile.ready_poll_ns += duration;
                if (duration >= std.time.ns_per_ms) agent.profile.ready_stalls += 1;
            }
        }
        if (polled < 0) {
            if (c.__errno_location().* == c.EINTR) continue;
            return error.IoError;
        }
        if ((fds[2].revents & c.POLLIN) != 0) {
            var siginfo: c.struct_signalfd_siginfo = undefined;
            while (c.read(signal_fd, &siginfo, @sizeOf(@TypeOf(siginfo))) > 0) {
                if (siginfo.ssi_signo == c.SIGTERM or siginfo.ssi_signo == c.SIGINT) agent.disconnect(now);
            }
        }
        reap(&agent);
        for (&agent.jobs, 0..) |*entry, i| if (entry.*) |*job| {
            if (job.pty and (fds[3 + i * 3].revents & c.POLLOUT) != 0) try job.writeInput();
            for (0..3) |j| if ((fds[3 + i * 3 + j].revents & (c.POLLIN | c.POLLHUP | c.POLLERR)) != 0) try job.drain(j, now);
            if ((agent.deliveries[i].ready or job.done(now)) and (agent.closing or agent.output.items.len < 1024 * 1024)) {
                if (!agent.closing and agent.usesBoundedBulk() and !job.pty) {
                    agent.deliveries[i].ready = true;
                } else {
                    if (!agent.closing) try agent.finish(job);
                    agent.releaseJob(i);
                }
            }
        };
        try agent.scheduleOutputs();
        if ((fds[1].revents & (c.POLLERR | c.POLLHUP)) != 0) agent.disconnect(now);
        if ((fds[1].revents & c.POLLOUT) != 0 and agent.output.items.len > agent.sent) {
            const n = c.write(1, agent.output.items.ptr + agent.sent, @min(65536, agent.output.items.len - agent.sent));
            if (n > 0) {
                if (agent.profiling) {
                    agent.profile.writes += 1;
                    agent.profile.bytes_written += @intCast(n);
                }
                agent.sent += @intCast(n);
                if (agent.queue_profile) |profile| profile.wrote(@intCast(n), profileClock());
                agent.last_write = now;
                if (agent.sent == agent.output.items.len) {
                    agent.output.clearRetainingCapacity();
                    agent.sent = 0;
                }
                if (agent.sent >= 65536) {
                    std.mem.copyForwards(u8, agent.output.items, agent.output.items[agent.sent..]);
                    agent.output.items.len -= agent.sent;
                    agent.sent = 0;
                }
            } else if (n < 0 and c.__errno_location().* != c.EAGAIN and c.__errno_location().* != c.EINTR) agent.disconnect(now);
        }
        if (agent.output.items.len > agent.sent and now >= agent.last_write and now - agent.last_write >= 10000) agent.disconnect(now);
        if (agent.closing) continue;
        if ((fds[0].revents & (c.POLLIN | c.POLLHUP | c.POLLERR)) != 0) {
            var buf: [8192]u8 = undefined;
            const n = c.read(0, &buf, buf.len);
            if (n == 0) {
                agent.disconnect(now);
                continue;
            }
            if (n < 0) {
                if (c.__errno_location().* == c.EAGAIN or c.__errno_location().* == c.EINTR) continue;
                agent.disconnect(now);
                continue;
            }
            if (agent.input.items.len + @as(usize, @intCast(n)) > p.max_payload + p.header_len + buf.len) return error.ResourceExhausted;
            try agent.input.appendSlice(A, buf[0..@intCast(n)]);
        }
        var consumed: usize = 0;
        var dispatched: usize = 0;
        while (agent.input.items.len - consumed >= p.header_len and dispatched < 64) : (dispatched += 1) {
            const raw: *const [p.header_len]u8 = @ptrCast(agent.input.items.ptr + consumed);
            const header = p.Header.decode(raw) catch {
                try agent.sendError(0, error.ProtocolMismatch);
                agent.closing = true;
                for (&agent.jobs) |*entry| if (entry.*) |*job| job.cancel(.cancelled, now);
                break;
            };
            const total = p.header_len + header.payload_len;
            if (agent.input.items.len - consumed < total) break;
            const payload = agent.input.items[consumed + p.header_len ..][0..header.payload_len];
            agent.dispatch(header, payload, now) catch {
                try agent.sendError(0, error.ProtocolMismatch);
                agent.closing = true;
                for (&agent.jobs) |*entry| if (entry.*) |*job| job.cancel(.cancelled, now);
            };
            consumed += total;
            if (agent.closing) break;
        }
        if (consumed != 0) {
            std.mem.copyForwards(u8, agent.input.items, agent.input.items[consumed..]);
            agent.input.items.len -= consumed;
        }
    }
}

fn hasCompleteCommand(input: []const u8) bool {
    if (input.len < p.header_len) return false;
    const header = p.Header.decode(@ptrCast(input.ptr)) catch return false;
    return input.len - p.header_len >= header.payload_len;
}

fn completedCapture(id: u64) ex.Job {
    return .{
        .id = id,
        .pid = 0,
        .fds = .{ -1, -1, -1 },
        .limit = 1024 * 1024,
        .streams = .{ id * 4 + 2, id * 4 + 4 },
        .deadline = std.math.maxInt(u64),
        .reaped = true,
        .supervised = true,
    };
}

test "bounded bulk requires experimental PTY negotiation as well as environment opt-in" {
    var agent: Agent = .{ .bounded_bulk = true };
    try std.testing.expect(!agent.usesBoundedBulk());
    agent.experimental_pty = true;
    try std.testing.expect(agent.usesBoundedBulk());
    agent.bounded_bulk = false;
    try std.testing.expect(!agent.usesBoundedBulk());
}

test "bounded outputs rotate all sixteen PTY and completed exec slots within batch limits" {
    var agent: Agent = .{ .bounded_bulk = true, .experimental_pty = true };
    defer agent.output.deinit(A);
    defer for (&agent.jobs) |*entry| if (entry.*) |*job| job.deinit();
    for (&agent.jobs, 0..) |*entry, index| {
        entry.* = completedCapture(index + 1);
        const job = &entry.*.?;
        job.pty = index % 2 == 0;
        job.credit = 65536;
        try job.stdout.appendNTimes(A, @intCast(index), if (job.pty) 65536 else 131072);
        agent.deliveries[index].ready = !job.pty;
    }
    var received: [max_jobs]usize = @splat(0);
    var terminal: [max_jobs]bool = @splat(false);
    for (0..40) |_| {
        try agent.scheduleOutputs();
        try std.testing.expect(agent.output.items.len <= pty_batch_limit);
        var offset: usize = 0;
        while (offset < agent.output.items.len) {
            const h = try p.Header.decode(@ptrCast(agent.output.items.ptr + offset));
            const index: usize = @intCast(h.request_id - 1);
            try std.testing.expect(!terminal[index]);
            const bytes = agent.output.items[offset + p.header_len ..][0..h.payload_len];
            if (h.kind == .data) {
                try std.testing.expect(bytes.len <= 16384);
                for (bytes) |byte| try std.testing.expectEqual(@as(u8, @intCast(index)), byte);
                received[index] += bytes.len;
            } else {
                try std.testing.expectEqual(p.Kind.response, h.kind);
                try std.testing.expectEqual(@as(usize, 131072), received[index]);
                terminal[index] = true;
            }
            offset += p.header_len + bytes.len;
        }
        agent.output.clearRetainingCapacity();
    }
    for (received, 0..) |count, index| {
        try std.testing.expectEqual(@as(usize, if (index % 2 == 0) 65536 else 131072), count);
        try std.testing.expectEqual(index % 2 != 0, terminal[index]);
        try std.testing.expectEqual(index % 2 != 0, agent.jobs[index] == null);
    }
}

test "bounded exec keeps both streams and terminal totals in order without duplication" {
    var agent: Agent = .{ .bounded_bulk = true, .experimental_pty = true };
    defer agent.output.deinit(A);
    agent.jobs[0] = completedCapture(1);
    defer if (agent.jobs[0]) |*job| job.deinit();
    try agent.jobs[0].?.stdout.appendNTimes(A, 'A', 40000);
    try agent.jobs[0].?.stderr.appendNTimes(A, 'B', 50000);
    agent.deliveries[0].ready = true;
    var counts: [2]usize = .{ 0, 0 };
    var ended = false;
    for (0..20) |_| {
        try agent.scheduleOutputs();
        if (agent.output.items.len == 0) continue;
        try std.testing.expect(!ended);
        const h = try p.Header.decode(@ptrCast(agent.output.items.ptr));
        try std.testing.expectEqual(p.header_len + h.payload_len, agent.output.items.len);
        const payload = agent.output.items[p.header_len..];
        if (h.kind == .data) {
            const index: usize = if (h.stream_id == 6) 0 else 1;
            if (index == 1) try std.testing.expectEqual(@as(usize, 40000), counts[0]);
            for (payload) |byte| try std.testing.expectEqual(@as(u8, if (index == 0) 'A' else 'B'), byte);
            counts[index] += payload.len;
        } else {
            try std.testing.expectEqual(p.Kind.response, h.kind);
            var parsed = try std.json.parseFromSlice(std.json.Value, A, payload, .{});
            defer parsed.deinit();
            try std.testing.expectEqual(@as(u64, 40000), try integer(parsed.value, "stdout_bytes", 0));
            try std.testing.expectEqual(@as(u64, 50000), try integer(parsed.value, "stderr_bytes", 0));
            ended = true;
        }
        agent.output.clearRetainingCapacity();
    }
    try std.testing.expectEqual([2]usize{ 40000, 50000 }, counts);
    try std.testing.expect(ended and agent.jobs[0] == null);
}

test "bounded exec cancellation after DATA emits one truncation and clears delivery state" {
    var agent: Agent = .{ .bounded_bulk = true, .experimental_pty = true };
    defer agent.output.deinit(A);
    agent.jobs[0] = completedCapture(1);
    defer if (agent.jobs[0]) |*job| job.deinit();
    try agent.jobs[0].?.stdout.appendNTimes(A, 'X', 131072);
    agent.deliveries[0].ready = true;
    try agent.scheduleOutputs();
    const first = try p.Header.decode(@ptrCast(agent.output.items.ptr));
    try std.testing.expectEqual(p.Kind.data, first.kind);
    try std.testing.expectEqual(@as(usize, 16384), agent.deliveries[0].stdout_offset);
    agent.jobs[0].?.cancel(.cancelled, 0);
    try agent.scheduleOutputs();
    const offset = p.header_len + first.payload_len;
    const last = try p.Header.decode(@ptrCast(agent.output.items.ptr + offset));
    try std.testing.expectEqual(p.Kind.error_response, last.kind);
    try std.testing.expectEqual(offset + p.header_len + last.payload_len, agent.output.items.len);
    try std.testing.expect(agent.jobs[0] == null);
    try std.testing.expectEqual(bulk_delivery.State{}, agent.deliveries[0]);
    const size = agent.output.items.len;
    try agent.scheduleOutputs();
    try std.testing.expectEqual(size, agent.output.items.len);
}

test "oversized filesystem metadata waits for empty output and cannot starve behind PTYs" {
    var agent: Agent = .{ .bounded_bulk = true, .experimental_pty = true };
    defer agent.output.deinit(A);
    defer for (&agent.jobs) |*entry| if (entry.*) |*job| job.deinit();
    agent.jobs[0] = completedCapture(1);
    agent.jobs[0].?.pty = true;
    agent.jobs[0].?.credit = 65536;
    try agent.jobs[0].?.stdout.appendNTimes(A, 'P', 65536);
    agent.jobs[1] = completedCapture(2);
    agent.jobs[1].?.rpc_worker = true;
    const raw = try (p.Header{ .kind = .response, .request_id = 2, .payload_len = 100000 }).encode();
    try agent.jobs[1].?.stdout.appendSlice(A, &raw);
    try agent.jobs[1].?.stdout.appendNTimes(A, 'M', 100000);
    agent.deliveries[1].ready = true;
    try agent.scheduleOutputs();
    try std.testing.expectEqual(@as(usize, 1), agent.next_output);
    try std.testing.expect(agent.jobs[1] != null);
    try std.testing.expectEqual(@as(usize, 16384 + p.header_len), agent.output.items.len);
    agent.output.clearRetainingCapacity();
    try agent.scheduleOutputs();
    try std.testing.expectEqual(@as(usize, 100000 + p.header_len), agent.output.items.len);
    try std.testing.expect(agent.jobs[1] == null);
    const h = try p.Header.decode(@ptrCast(agent.output.items.ptr));
    try std.testing.expectEqual(@as(u64, 2), h.request_id);
    agent.output.clearRetainingCapacity();
    try agent.scheduleOutputs();
    try std.testing.expect(agent.output.items.len > 0);
}

test "queue diagnostics distinguish complete buffered commands from partial frames" {
    const raw = try (p.Header{ .kind = .request, .request_id = 1, .payload_len = 2 }).encode();
    var frame: [p.header_len + 2]u8 = undefined;
    @memcpy(frame[0..p.header_len], &raw);
    @memcpy(frame[p.header_len..], "{}");
    try std.testing.expect(!hasCompleteCommand(frame[0 .. p.header_len - 1]));
    try std.testing.expect(!hasCompleteCommand(frame[0..p.header_len]));
    try std.testing.expect(hasCompleteCommand(&frame));
}

test "queue diagnostics account for opaque filesystem replies and control ACKs" {
    var profile: queue_profile.Profiler = .{};
    var agent: Agent = .{ .greeted = true, .experimental_pty = true, .queue_profile = &profile };
    defer agent.output.deinit(A);
    try agent.frameClass(.data, 1, 2, "data", .pty_data);
    var worker: ex.Job = .{
        .id = 2,
        .pid = 0,
        .fds = .{ -1, -1, -1 },
        .limit = 1024,
        .streams = .{ 0, 0 },
        .deadline = 0,
        .rpc_worker = true,
    };
    defer worker.deinit();
    const raw = try (p.Header{ .kind = .response, .request_id = 2, .payload_len = 2 }).encode();
    try worker.stdout.appendSlice(A, &raw);
    try worker.stdout.appendSlice(A, "{}");
    try agent.finishWithoutQueueProfile(&worker);
    const fd = c.dup(1);
    if (fd < 0) return error.IoError;
    agent.jobs[0] = .{
        .id = 1,
        .pid = 0,
        .fds = .{ fd, -1, -1 },
        .limit = 0,
        .streams = .{ 2, 4 },
        .deadline = std.math.maxInt(u64),
        .pty = true,
    };
    defer agent.jobs[0].?.deinit();
    const input = "{\"op\":\"PTY_INPUT\",\"session_id\":1,\"bytes_b64\":\"WA==\"}";
    try agent.dispatch(.{ .kind = .request, .request_id = 3, .payload_len = input.len }, input, 0);
    try std.testing.expectEqualStrings("X", agent.jobs[0].?.input.items);
    try std.testing.expectEqual(@as(u64, 1), profile.stats.classes[@intFromEnum(queue_profile.Class.filesystem_reply)].enqueued);
    try std.testing.expectEqual(@as(u64, 1), profile.stats.classes[@intFromEnum(queue_profile.Class.pty_input_ack)].enqueued);
    try std.testing.expectEqual(@as(u64, 1), profile.stats.request_handler_ns[@intFromEnum(queue_profile.Request.pty_input)].count);
    profile.wrote(agent.output.items.len, profileClock());
    try std.testing.expectEqual(@as(u64, @intCast(agent.output.items.len)), profile.stats.written_wire_bytes);
    try std.testing.expectEqual(@as(usize, 0), profile.count);
}

test "restored PTY credit schedules full buffered output before poll" {
    var agent: Agent = .{ .greeted = true, .experimental_pty = true };
    defer agent.output.deinit(A);
    agent.jobs[0] = .{
        .id = 1,
        .pid = 0,
        .fds = .{ -1, -1, -1 },
        .limit = 0,
        .streams = .{ 2, 4 },
        .deadline = std.math.maxInt(u64),
        .pty = true,
        .supervised = true,
    };
    const job = &agent.jobs[0].?;
    defer job.deinit();
    try job.stdout.appendNTimes(A, 0xab, 65536);
    try std.testing.expectEqual(@as(usize, 1), try agent.preparePoll(0));
    try std.testing.expectEqual(@as(usize, 0), agent.output.items.len);
    var credit: [8]u8 = undefined;
    std.mem.writeInt(u64, &credit, 65536, .little);
    try agent.dispatch(.{ .kind = .window_update, .request_id = 1, .stream_id = 2, .payload_len = 8 }, &credit, 0);
    _ = try agent.preparePoll(0);
    try std.testing.expectEqual(@as(usize, 0), job.stdout.items.len);
    try std.testing.expectEqual(@as(usize, 0), job.credit);
    var offset: usize = 0;
    var total: usize = 0;
    while (offset < agent.output.items.len) {
        const header = try p.Header.decode(@ptrCast(agent.output.items.ptr + offset));
        try std.testing.expectEqual(p.Kind.data, header.kind);
        try std.testing.expectEqual(@as(u64, 1), header.request_id);
        try std.testing.expectEqual(@as(u64, 2), header.stream_id);
        try std.testing.expect(header.payload_len <= p.max_data);
        offset += p.header_len;
        for (agent.output.items[offset..][0..header.payload_len]) |byte| try std.testing.expectEqual(@as(u8, 0xab), byte);
        total += header.payload_len;
        offset += header.payload_len;
    }
    try std.testing.expectEqual(@as(usize, 65536), total);
}

test "shared PTY scheduling bounds queued bulk and rotates across all credited jobs" {
    var agent: Agent = .{ .greeted = true, .experimental_pty = true };
    defer agent.output.deinit(A);
    defer for (&agent.jobs) |*entry| if (entry.*) |*job| job.deinit();
    for (&agent.jobs, 0..) |*entry, index| {
        entry.* = .{
            .id = index + 1,
            .pid = 0,
            .fds = .{ -1, -1, -1 },
            .limit = 0,
            .streams = .{ 2 + index * 4, 4 + index * 4 },
            .deadline = std.math.maxInt(u64),
            .pty = true,
            .supervised = true,
            .credit = 65536,
        };
        try entry.*.?.stdout.appendNTimes(A, @intCast(index), 65536);
    }
    var delivered: [max_jobs]usize = @splat(0);
    for (0..4) |_| {
        _ = try agent.preparePoll(0);
        try std.testing.expect(agent.output.items.len <= pty_batch_limit);
        var offset: usize = 0;
        while (offset < agent.output.items.len) {
            const header = try p.Header.decode(@ptrCast(agent.output.items.ptr + offset));
            const index: usize = @intCast(header.request_id - 1);
            try std.testing.expectEqual(p.Kind.data, header.kind);
            try std.testing.expectEqual(@as(u64, 2 + index * 4), header.stream_id);
            offset += p.header_len;
            for (agent.output.items[offset..][0..header.payload_len]) |byte| try std.testing.expectEqual(@as(u8, @intCast(index)), byte);
            delivered[index] += header.payload_len;
            offset += header.payload_len;
        }
        agent.output.clearRetainingCapacity(); // Emulate successful stdout drain.
    }
    for (delivered) |bytes| try std.testing.expectEqual(@as(usize, 16384), bytes);
    // A non-consuming stream cannot prevent the remaining streams progressing.
    agent.jobs[0].?.credit = 0;
    for (0..4) |_| {
        _ = try agent.preparePoll(0);
        try std.testing.expect(agent.output.items.len <= pty_batch_limit);
        agent.output.clearRetainingCapacity();
    }
    try std.testing.expectEqual(@as(usize, 49152), agent.jobs[0].?.stdout.items.len);
    for (agent.jobs[1..]) |entry| try std.testing.expect(entry.?.stdout.items.len < 49152);
}

fn cleanup(agent: *Agent) void {
    const start = nowMs();
    for (&agent.jobs, 0..) |*entry, index| if (entry.*) |*job| {
        if (agent.deliveries[index].ready) agent.releaseJob(index) else job.cancel(.cancelled, start);
    };
    while (true) {
        reap(agent);
        var active = false;
        const now = nowMs();
        for (&agent.jobs) |*entry| if (entry.*) |*job| {
            job.tick(now);
            if (job.reaped and (job.killed or now - start > 1500)) {
                job.deinit();
                entry.* = null;
            } else active = true;
        };
        if (!active) break;
        _ = c.poll(null, 0, 10);
    }
    reap(agent);
}

fn reap(agent: *Agent) void {
    while (true) {
        var status: c_int = 0;
        const pid = c.waitpid(-1, &status, c.WNOHANG);
        if (pid <= 0) break;
        recordReaped(agent, pid, status);
    }
}

fn recordReaped(agent: *Agent, pid: c.pid_t, status: c_int) void {
    for (&agent.jobs) |*entry| if (entry.*) |*job| if (!job.reaped and job.pid == pid) {
        job.reaped = true;
        job.status = status;
        return;
    };
}

test "retained completion never claims a newly reaped child with the same PID" {
    var agent: Agent = .{};
    agent.jobs[0] = completedCapture(1);
    agent.jobs[0].?.pid = 123;
    agent.jobs[0].?.status = 7;
    agent.deliveries[0].ready = true;
    agent.jobs[1] = completedCapture(2);
    agent.jobs[1].?.pid = 123;
    agent.jobs[1].?.reaped = false;
    recordReaped(&agent, 123, 41);
    try std.testing.expectEqual(@as(c_int, 7), agent.jobs[0].?.status);
    try std.testing.expectEqual(@as(c_int, 41), agent.jobs[1].?.status);
    try std.testing.expect(agent.jobs[1].?.reaped);
}

test "retained completion skips process cleanup ticks but retains delivery deadline" {
    var agent: Agent = .{};
    agent.jobs[0] = completedCapture(1);
    agent.jobs[0].?.cancel(.cancelled, 0);
    agent.deliveries[0].ready = true;
    agent.tickJob(0, 2000);
    try std.testing.expect(!agent.jobs[0].?.killed);
    agent.jobs[1] = completedCapture(2);
    agent.jobs[1].?.deadline = 1;
    agent.deliveries[1].ready = true;
    agent.tickJob(1, 2);
    try std.testing.expectEqual(ex.Reason.timeout, agent.jobs[1].?.reason.?);
    try std.testing.expect(!agent.jobs[1].?.killed);
}

fn nonblocking(fd: c_int) !void {
    const flags = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    if (flags < 0 or c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) < 0) return error.IoError;
}

fn ignoreSignal(_: c_int) callconv(.c) void {}

fn nowMs() u64 {
    var time: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &time);
    return @as(u64, @intCast(time.sec)) * 1000 + @as(u64, @intCast(time.nsec)) / 1000000;
}

fn string(value: std.json.Value, key: []const u8) ![]const u8 {
    if (value != .object) return error.InvalidArgument;
    const item = value.object.get(key) orelse return error.InvalidArgument;
    if (item != .string) return error.InvalidArgument;
    return item.string;
}

fn integer(value: std.json.Value, key: []const u8, default: u64) !u64 {
    if (value != .object) return error.InvalidArgument;
    const item = value.object.get(key) orelse return default;
    if (item != .integer or item.integer < 0) return error.InvalidArgument;
    return @intCast(item.integer);
}

fn decode(a: std.mem.Allocator, text: []const u8, max: usize) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const size = try decoder.calcSizeForSlice(text);
    if (size > max) return error.InvalidArgument;
    const out = try a.alloc(u8, size);
    try decoder.decode(out, text);
    if (std.mem.indexOfScalar(u8, out, 0) != null) return error.InvalidArgument;
    return out;
}

fn encode(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const encoder = std.base64.standard.Encoder;
    return encoder.encode(try a.alloc(u8, encoder.calcSize(bytes.len)), bytes);
}

fn errorCode(err: anyerror) []const u8 {
    return switch (err) {
        error.NotFound => "not_found",
        error.PermissionDenied => "permission_denied",
        error.InvalidPath => "invalid_path",
        error.InvalidArgv => "invalid_argv",
        error.Unsupported, error.NotRegularFile => "unsupported",
        error.Timeout => "timeout",
        error.Cancelled => "cancelled",
        error.OutputLimit => "output_limit",
        error.ResourceExhausted, error.OutOfMemory, error.LimitExceeded => "resource_exhausted",
        error.ProtocolMismatch => "protocol_mismatch",
        error.InvalidArgument, error.InvalidOffset => "invalid_argument",
        else => "io_error",
    };
}
