//! Fixed-size nonblocking PTY read workers. The mux owner reserves stream
//! credit before submitting a job and owns every lifecycle/transport decision.
//! Workers own duplicated descriptors and fixed buffers, never stream pointers.
//! Optional pairs rotate reads inside the same buffer and worker turn. Each
//! stream's result retires independently; buffer reuse waits for the whole pair.
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
pub const max_jobs = 2;
pub const State = enum(u8) { idle, running, ready };

pub const Job = struct {
    fd: c_int = -1,
    slot: usize = 0,
    stream_id: u32 = 0,
    allowance: usize = 0,
    start: usize = 0,
    len: usize = 0,
    eof: bool = false,
    done: bool = false,
    reads: u64 = 0,
    read_ns: u64 = 0,
    // Owner-only fields, after acquiring ready.
    collected: bool = false,
    released: bool = true,
    offset: usize = 0,
};

pub const Worker = struct {
    thread: ?std.Thread = null,
    wake_fd: c_int = -1,
    notify_fd: c_int = -1,
    stopping: std.atomic.Value(bool) = .init(false),
    state: std.atomic.Value(State) = .init(.idle),
    // All jobs/results are published through state's release/acquire pair.
    jobs: [max_jobs]Job = .{Job{}} ** max_jobs,
    job_count: usize = 0,
    reserved: usize = 0,
    buffer: [max_bytes]u8 = undefined,
    diagnostics: bool = false,
    submitted_ns: i64 = 0,
    started_ns: i64 = 0,
    completed_ns: i64 = 0,
    timing_collected: bool = false,

    fn run(self: *Worker) void {
        _ = c.prctl(c.PR_SET_NAME, @as(c_ulong, @intFromPtr("hollow-pty-read")), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0));
        while (true) {
            var fds = [_]c.struct_pollfd{.{ .fd = self.wake_fd, .events = c.POLLIN, .revents = 0 }};
            if (c.poll(&fds, 1, -1) < 0) continue;
            drainNotification(self.wake_fd);
            if (self.stopping.load(.acquire)) return;
            if (self.state.load(.acquire) != .running) continue;
            if (self.diagnostics) self.started_ns = nowNs();
            self.readJob();
            for (self.jobs[0..self.job_count]) |*job| {
                _ = c.close(job.fd);
                job.fd = -1;
            }
            if (self.diagnostics) self.completed_ns = nowNs();
            self.state.store(.ready, .release);
            notify(self.notify_fd);
        }
    }

    fn readJob(self: *Worker) void {
        // One bounded worker turn, rotating PTYs between syscall attempts.
        // Never wait for more output on an empty member of the batch.
        const deadline = nowNs() + 750_000;
        var cursor: usize = 0;
        for (0..32) |turn| {
            if (self.stopping.load(.monotonic) or (turn > 0 and nowNs() >= deadline)) break;
            const job = self.nextJob(&cursor) orelse break;
            const before = if (self.diagnostics) nowNs() else 0;
            const n = c.read(job.fd, self.buffer[job.start + job.len ..].ptr, job.allowance - job.len);
            const err = if (n < 0) c.__errno_location().* else 0;
            if (self.diagnostics) job.read_ns += @intCast(nowNs() - before);
            job.reads += 1;
            if (n > 0) {
                job.len += @intCast(n);
            } else if (n < 0 and err == c.EINTR) {
                continue;
            } else {
                job.eof = n == 0 or err != c.EAGAIN;
                job.done = true;
            }
        }
    }

    fn nextJob(self: *Worker, cursor: *usize) ?*Job {
        for (0..self.job_count) |_| {
            const item = &self.jobs[cursor.*];
            cursor.* = (cursor.* + 1) % self.job_count;
            if (!item.done and item.len < item.allowance) return item;
        }
        return null;
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
            // Shutdown can leave a submitted batch unclaimed by its reader.
            for (worker.jobs[0..worker.job_count]) |item| {
                if (item.fd >= 0) _ = c.close(item.fd);
            }
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

    pub fn begin(self: *Pool, index: usize, diagnostics: bool) void {
        const worker = &self.workers[index];
        std.debug.assert(worker.state.load(.acquire) == .idle);
        worker.job_count = 0;
        worker.reserved = 0;
        worker.diagnostics = diagnostics;
        worker.timing_collected = false;
    }

    pub fn add(self: *Pool, index: usize, master: c_int, slot: usize, id: u32, allowance: usize) !usize {
        const worker = &self.workers[index];
        std.debug.assert(worker.state.load(.acquire) == .idle);
        std.debug.assert(worker.job_count < max_jobs and allowance > 0 and allowance <= max_bytes - worker.reserved);
        // The worker owns this duplicate until readJob finishes. Pane close
        // cannot recycle a descriptor underneath an in-flight read.
        const fd = c.fcntl(master, c.F_DUPFD_CLOEXEC, @as(c_int, 3));
        if (fd < 0) return error.ReadDescriptorFailed;
        const key = index * max_jobs + worker.job_count;
        worker.jobs[worker.job_count] = .{
            .fd = fd,
            .slot = slot,
            .stream_id = id,
            .allowance = allowance,
            .start = worker.reserved,
            .released = false,
        };
        worker.job_count += 1;
        worker.reserved += allowance;
        return key;
    }

    pub fn startBatch(self: *Pool, index: usize) void {
        const worker = &self.workers[index];
        std.debug.assert(worker.job_count > 0 and worker.state.load(.acquire) == .idle);
        if (worker.diagnostics) worker.submitted_ns = nowNs();
        worker.state.store(.running, .release);
        notify(worker.wake_fd);
    }

    pub fn output(self: *Pool) ?usize {
        for (0..self.count * max_jobs) |_| {
            const i = self.output_cursor;
            self.output_cursor = (i + 1) % (self.count * max_jobs);
            const worker = &self.workers[i / max_jobs];
            const member = i % max_jobs;
            if (worker.state.load(.acquire) != .ready or member >= worker.job_count) continue;
            const item = &worker.jobs[member];
            if (!item.released and item.collected and item.offset < item.len) return i;
        }
        return null;
    }

    pub fn job(self: *Pool, key: usize) *Job {
        return &self.workers[key / max_jobs].jobs[key % max_jobs];
    }

    pub fn bytes(self: *Pool, key: usize) []const u8 {
        const item = self.job(key);
        return self.workers[key / max_jobs].buffer[item.start..][0..item.len];
    }

    /// Reuse the worker's shared buffer only after every member is released.
    /// Released members may retire their stream independently of other members.
    pub fn release(self: *Pool, key: usize) bool {
        const worker = &self.workers[key / max_jobs];
        std.debug.assert(worker.state.load(.acquire) == .ready);
        const item = self.job(key);
        std.debug.assert(!item.released);
        item.released = true;
        for (worker.jobs[0..worker.job_count]) |other| {
            if (!other.released) return false;
        }
        worker.state.store(.idle, .release);
        return true;
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

test "batch rotates read attempts and skips empty or exhausted members" {
    var worker: Worker = .{ .job_count = 2 };
    worker.jobs[0] = .{ .slot = 7, .allowance = 10 };
    worker.jobs[1] = .{ .slot = 19, .allowance = 10 };
    var cursor: usize = 0;
    for ([_]usize{ 7, 19, 7, 19 }) |slot| {
        try std.testing.expectEqual(slot, worker.nextJob(&cursor).?.slot);
    }
    worker.jobs[0].done = true;
    try std.testing.expectEqual(@as(usize, 19), worker.nextJob(&cursor).?.slot);
    worker.jobs[1].len = 10;
    try std.testing.expect(worker.nextJob(&cursor) == null);
}

test "two members share one bounded buffer and release independently" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe2(&fds, c.O_CLOEXEC | c.O_NONBLOCK));
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);
    var pool: Pool = .{ .count = 1 };
    defer pool.deinit();
    pool.begin(0, false);
    const first = try pool.add(0, fds[0], 7, 11, max_bytes / 2);
    const second = try pool.add(0, fds[0], 19, 23, max_bytes / 2);
    try std.testing.expectEqual(@as(usize, 0), pool.job(first).start);
    try std.testing.expectEqual(@as(usize, max_bytes / 2), pool.job(second).start);
    try std.testing.expectEqual(@as(usize, max_bytes), pool.workers[0].reserved);
    try std.testing.expect(pool.job(first).fd != pool.job(second).fd);
    try std.testing.expect(c.fcntl(pool.job(first).fd, c.F_GETFD) & c.FD_CLOEXEC != 0);
    pool.workers[0].state.store(.ready, .release);
    pool.job(first).collected = true;
    pool.job(second).collected = true;
    pool.job(first).len = 1;
    pool.job(second).len = 1;
    try std.testing.expect(!pool.release(first));
    try std.testing.expect(pool.idle() == null);
    try std.testing.expectEqual(second, pool.output().?);
    try std.testing.expect(pool.release(second));
    try std.testing.expectEqual(@as(usize, 0), pool.idle().?);
}
