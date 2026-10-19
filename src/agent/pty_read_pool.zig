//! Fixed-size nonblocking PTY read workers. The mux owner reserves stream
//! credit before submitting a job and owns every lifecycle/transport decision.
//! Workers own duplicated descriptors and fixed buffers, never stream pointers.
const std = @import("std");
const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("poll.h");
    @cInclude("sys/eventfd.h");
    @cInclude("sys/prctl.h");
    @cInclude("errno.h");
});

pub const max_workers = 4;
pub const max_bytes = 64 * 1024;
pub const State = enum(u8) { idle, running, ready };

pub const Worker = struct {
    thread: ?std.Thread = null,
    wake_fd: c_int = -1,
    notify_fd: c_int = -1,
    stopping: std.atomic.Value(bool) = .init(false),
    state: std.atomic.Value(State) = .init(.idle),
    // Job/result fields are published through state's release/acquire pair.
    fd: c_int = -1,
    slot: usize = 0,
    stream_id: u32 = 0,
    allowance: usize = 0,
    diagnostics: bool = false,
    buffer: [max_bytes]u8 = undefined,
    len: usize = 0,
    eof: bool = false,
    reads: u64 = 0,
    read_ns: u64 = 0,
    // Owner-only fields: result collected, and bytes already staged to wire.
    collected: bool = false,
    offset: usize = 0,

    fn run(self: *Worker) void {
        _ = c.prctl(c.PR_SET_NAME, @as(c_ulong, @intFromPtr("hollow-pty-read")), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0));
        while (true) {
            var fds = [_]c.struct_pollfd{.{ .fd = self.wake_fd, .events = c.POLLIN, .revents = 0 }};
            if (c.poll(&fds, 1, -1) < 0) continue;
            drainNotification(self.wake_fd);
            if (self.stopping.load(.acquire)) return;
            if (self.state.load(.acquire) != .running) continue;
            self.readJob();
            _ = c.close(self.fd);
            self.fd = -1;
            self.state.store(.ready, .release);
            notify(self.notify_fd);
        }
    }

    fn readJob(self: *Worker) void {
        // This budget runs off the transport owner. Amortize job hand-off
        // over bounded 32/64 KiB byte quanta, without waiting for more output.
        const deadline = nowNs() + 750_000;
        for (0..32) |turn| {
            if (self.len == self.allowance or self.stopping.load(.monotonic) or (turn > 0 and nowNs() >= deadline)) break;
            const before = if (self.diagnostics) nowNs() else 0;
            const n = c.read(self.fd, self.buffer[self.len..].ptr, self.allowance - self.len);
            const err = if (n < 0) c.__errno_location().* else 0;
            if (self.diagnostics) self.read_ns += @intCast(nowNs() - before);
            self.reads += 1;
            if (n > 0) {
                self.len += @intCast(n);
            } else if (n < 0 and err == c.EINTR) {
                continue;
            } else {
                self.eof = n == 0 or err != c.EAGAIN;
                break;
            }
        }
    }
};

pub const Pool = struct {
    workers: [max_workers]Worker = .{Worker{}} ** max_workers,
    count: usize = 0,
    completion_fd: c_int = -1,
    output_cursor: usize = 0,

    /// Start in place: running threads retain pointers into this struct.
    pub fn start(self: *Pool, count: usize) !void {
        if (count > max_workers) return error.InvalidWorkerCount;
        if (count == 0) return;
        self.completion_fd = c.eventfd(0, c.EFD_CLOEXEC | c.EFD_NONBLOCK);
        if (self.completion_fd < 0) return error.EventFdFailed;
        errdefer self.deinit();
        for (0..count) |i| {
            const worker = &self.workers[i];
            worker.wake_fd = c.eventfd(0, c.EFD_CLOEXEC | c.EFD_NONBLOCK);
            if (worker.wake_fd < 0) return error.EventFdFailed;
            self.count = i + 1;
            worker.notify_fd = self.completion_fd;
            worker.thread = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, Worker.run, .{worker});
        }
    }

    pub fn deinit(self: *Pool) void {
        for (self.workers[0..self.count]) |*worker| {
            worker.stopping.store(true, .release);
            notify(worker.wake_fd);
        }
        for (self.workers[0..self.count]) |*worker| {
            if (worker.thread) |thread| thread.join();
            // A failed thread start can leave an unclaimed job descriptor.
            if (worker.fd >= 0) _ = c.close(worker.fd);
            _ = c.close(worker.wake_fd);
        }
        if (self.completion_fd >= 0) _ = c.close(self.completion_fd);
        self.count = 0;
        self.completion_fd = -1;
    }

    pub fn idle(self: *Pool) ?usize {
        for (self.workers[0..self.count], 0..) |*worker, i| {
            if (worker.state.load(.acquire) == .idle) return i;
        }
        return null;
    }

    pub fn submit(self: *Pool, index: usize, master: c_int, slot: usize, id: u32, allowance: usize, diagnostics: bool) !void {
        const worker = &self.workers[index];
        std.debug.assert(worker.state.load(.acquire) == .idle);
        std.debug.assert(allowance > 0 and allowance <= max_bytes);
        // The worker owns this duplicate until readJob finishes. Pane close
        // cannot recycle a descriptor underneath an in-flight read.
        const fd = c.fcntl(master, c.F_DUPFD_CLOEXEC, @as(c_int, 3));
        if (fd < 0) return error.ReadDescriptorFailed;
        worker.fd = fd;
        worker.slot = slot;
        worker.stream_id = id;
        worker.allowance = allowance;
        worker.diagnostics = diagnostics;
        worker.len = 0;
        worker.offset = 0;
        worker.eof = false;
        worker.reads = 0;
        worker.read_ns = 0;
        worker.collected = false;
        worker.state.store(.running, .release);
        notify(worker.wake_fd);
    }

    pub fn output(self: *Pool) ?usize {
        for (0..self.count) |_| {
            const i = self.output_cursor;
            self.output_cursor = (i + 1) % self.count;
            const worker = &self.workers[i];
            if (worker.state.load(.acquire) == .ready and worker.collected and worker.offset < worker.len) return i;
        }
        return null;
    }

    pub fn release(self: *Pool, index: usize) void {
        const worker = &self.workers[index];
        std.debug.assert(worker.state.load(.acquire) == .ready);
        worker.state.store(.idle, .release);
    }
};

pub fn drainNotification(fd: c_int) void {
    var value: u64 = undefined;
    while (c.read(fd, &value, @sizeOf(u64)) > 0) {}
}

fn notify(fd: c_int) void {
    const value: u64 = 1;
    while (c.write(fd, &value, @sizeOf(u64)) < 0 and c.__errno_location().* == c.EINTR) {}
}

fn nowNs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return ts.sec * 1_000_000_000 + ts.nsec;
}

test "pool count is bounded and zero workers own no descriptors" {
    var pool: Pool = .{};
    try pool.start(0);
    try std.testing.expect(pool.idle() == null);
    try std.testing.expectEqual(@as(c_int, -1), pool.completion_fd);
    try std.testing.expectError(error.InvalidWorkerCount, pool.start(max_workers + 1));
    pool.deinit();
}
