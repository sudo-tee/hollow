//! Universal Linux agent. Stdout is exclusively framed RPC, never diagnostics.
const std = @import("std");
const builtin = @import("builtin");
const p = @import("protocol.zig");
const fs = @import("fs.zig");
const ex = @import("exec.zig");
const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
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
    nonce: [32]u8 = undefined,
    data_limit: usize = p.max_data,
    payload_limit: usize = p.max_payload,
    job_limit: usize = max_jobs,
    worker: bool = false,
    signal_fd: c_int = -1,
    agent_pid: c_int = -1,
    experimental_pty: bool = false,

    fn frame(self: *Agent, kind: p.Kind, id: u64, sid: u64, payload: []const u8) !void {
        if (payload.len > self.payload_limit) return error.ResourceExhausted;
        const header = try (p.Header{ .kind = kind, .request_id = id, .stream_id = sid, .payload_len = @intCast(payload.len) }).encode();
        if (self.output.items.len + header.len + payload.len > queue_limit) return error.ResourceExhausted;
        if (self.output.items.len == self.sent) self.last_write = nowMs();
        try self.output.ensureUnusedCapacity(A, header.len + payload.len);
        self.output.appendSliceAssumeCapacity(&header);
        self.output.appendSliceAssumeCapacity(payload);
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
        for (&self.jobs) |*entry| if (entry.*) |*job| job.cancel(.cancelled, now);
    }

    fn dispatch(self: *Agent, h: p.Header, bytes: []const u8, now: u64) !void {
        if (self.greeted and self.experimental_pty and h.kind == .window_update) {
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
        var arena = std.heap.ArenaAllocator.init(A);
        defer arena.deinit();
        const a = arena.allocator();
        const parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{ .max_value_len = p.max_payload }) catch return error.InvalidArgument;
        const value = parsed.value;
        const op = try string(value, "op");
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
            return self.frame(.response, id, 0, "{}");
        };
        return error.NotFound;
    }

    fn streamPty(self: *Agent, job: *ex.Job) !void {
        if (!job.pty or job.reason != null or self.closing) return;
        while (job.stdout.items.len > 0 and job.credit > 0 and self.output.items.len < 1024 * 1024) {
            const count = @min(job.credit, @min(self.data_limit, job.stdout.items.len));
            try self.frame(.data, job.id, job.streams[0], job.stdout.items[0..count]);
            job.credit -= count;
            std.mem.copyForwards(u8, job.stdout.items, job.stdout.items[count..]);
            job.stdout.items.len -= count;
        }
    }

    fn finish(self: *Agent, job: *ex.Job) !void {
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
                try self.frame(.data, job.id, sid, bytes[offset..][0..count]);
                offset += count;
            }
        }
        var buf: [256]u8 = undefined;
        const body = try std.fmt.bufPrint(&buf, "{{\"exit_code\":{d},\"stdout_bytes\":{d},\"stderr_bytes\":{d},\"truncated\":false}}", .{ job.exitCode(), job.stdout.items.len, job.stderr.items.len });
        try self.frame(.response, job.id, 0, body);
    }
};

pub fn main() !void {
    var agent = Agent{ .agent_pid = c.getpid() };
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
        var active: usize = 0;
        for (&agent.jobs) |*entry| if (entry.*) |*job| {
            active += 1;
            job.tick(now);
        };
        if (agent.closing and active == 0 and agent.output.items.len == agent.sent) break;
        var fds: [3 + max_jobs * 3]c.struct_pollfd = undefined;
        fds[0] = .{ .fd = if (agent.closing) -1 else 0, .events = c.POLLIN, .revents = 0 };
        fds[1] = .{ .fd = 1, .events = if (agent.output.items.len > agent.sent) c.POLLOUT else 0, .revents = 0 };
        fds[2] = .{ .fd = signal_fd, .events = c.POLLIN, .revents = 0 };
        for (agent.jobs, 0..) |entry, i| for (0..3) |j| {
            const events: c_short = if (entry) |job| if (job.pty and j == 0) @as(c_short, if (job.stdout.items.len < 65536 or job.reason != null) c.POLLIN else 0) | @as(c_short, if (job.input.items.len > 0 and job.reason == null) c.POLLOUT else 0) else c.POLLIN else c.POLLIN;
            fds[3 + i * 3 + j] = .{ .fd = if (entry) |job| if (job.pty and j == 0 and events == 0) -1 else job.fds[j] else -1, .events = events, .revents = 0 };
        };
        const polled = c.poll(&fds, fds.len, 20);
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
            try agent.streamPty(job);
            if (job.done(now) and (agent.closing or agent.output.items.len < 1024 * 1024)) {
                if (!agent.closing) try agent.finish(job);
                job.deinit();
                entry.* = null;
            }
        };
        if ((fds[1].revents & (c.POLLERR | c.POLLHUP)) != 0) agent.disconnect(now);
        if ((fds[1].revents & c.POLLOUT) != 0 and agent.output.items.len > agent.sent) {
            const n = c.write(1, agent.output.items.ptr + agent.sent, @min(65536, agent.output.items.len - agent.sent));
            if (n > 0) {
                agent.sent += @intCast(n);
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

fn cleanup(agent: *Agent) void {
    const start = nowMs();
    for (&agent.jobs) |*entry| if (entry.*) |*job| job.cancel(.cancelled, start);
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
        for (&agent.jobs) |*entry| if (entry.*) |*job| if (job.pid == pid) {
            job.reaped = true;
            job.status = status;
        };
    }
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
