//! Opt-in multi-PTY transport. One poll owner, no thread per pane. Output
//! frames share one bounded staging buffer; control precedes the next batch.
const std = @import("std");
const p = @import("mux_protocol.zig");
const pty = @import("pty.zig");
const read_pool = @import("pty_read_pool.zig");
var stopping: std.atomic.Value(bool) = .init(false);
const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("pty.h");
    @cInclude("poll.h");
    @cInclude("signal.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/prctl.h");
    @cInclude("sys/wait.h");
    @cInclude("sys/resource.h");
    @cInclude("errno.h");
    @cInclude("stdlib.h");
});

const Counters = struct {
    polls: u64 = 0,
    pty_reads: u64 = 0,
    output_frames: u64 = 0,
    output_bytes: u64 = 0,
    transport_writes: u64 = 0,
    transport_bytes: u64 = 0,
    credit_frames: u64 = 0,
    tx_high_water: usize = 0,
    control_high_water: usize = 0,
    stream_input_high_water: usize = 0,
    reader_high_water: usize = 0,
    poll_ns: u64 = 0,
    pty_read_ns: u64 = 0,
    transport_write_ns: u64 = 0,
    user_us: i64 = 0,
    system_us: i64 = 0,
    read_workers: usize = 0,
    read_pool_reserved_high_water: usize = 0,
};

const Stream = struct {
    id: u32,
    pid: c.pid_t,
    master: c_int,
    launch: c_int,
    input: std.ArrayList(u8) = .empty,
    output_credit: u32 = p.window,
    output_uncredited: u32 = 0,
    read_job: ?usize = null,
    status: ?u32 = null,
    eof: bool = false,
    closing: ?i64 = null,
    failed: bool = false,
    started: i64,

    fn stop(self: *Stream) void {
        if (self.closing != null) return;
        self.closing = nowMs();
        self.input.clearRetainingCapacity();
        self.eof = true; // Explicit close is an abort: unread PTY bytes discarded.
        if (self.master >= 0) _ = c.close(self.master);
        self.master = -1;
        signalGroup(self.pid, c.SIGHUP);
    }

    fn deinit(self: *Stream, a: std.mem.Allocator) void {
        if (self.master >= 0) _ = c.close(self.master);
        if (self.launch >= 0) _ = c.close(self.launch);
        self.input.deinit(a);
    }
};

/// Background byte DRR with alternating focus-first turns. Focus receives
/// twice the byte quantum; unused deficit never accumulates beyond one turn.
/// Priority turns preserve the background cursor. Frames never exceed max_data.
const Scheduler = struct {
    cursor: usize = 0,
    deficit: [p.max_streams]usize = .{0} ** p.max_streams,
    focus_pending: bool = true,
    priority_slot: ?usize = null,

    fn choose(self: *Scheduler, ready: [p.max_streams]bool, focused: ?usize) ?usize {
        self.priority_slot = null;
        // A focused echo must not wait behind every bulk stream. Alternate a
        // focus-first turn with normal background DRR; never move the background
        // cursor for that priority turn, so a flooding focus cannot starve it.
        if (focused) |i| {
            if (ready[i] and self.focus_pending) {
                self.focus_pending = false;
                self.priority_slot = i;
                if (self.deficit[i] == 0) self.deficit[i] = p.max_data * 2;
                return i;
            }
        }
        var background = ready;
        if (focused) |i| background[i] = false;
        const has_background = std.mem.indexOfScalar(bool, &background, true) != null;
        for (0..p.max_streams) |_| {
            const i = self.cursor;
            if (!ready[i] or (has_background and focused == i)) {
                self.deficit[i] = 0;
                self.cursor = (i + 1) % p.max_streams;
                continue;
            }
            self.focus_pending = true;
            if (self.deficit[i] == 0) self.deficit[i] = p.max_data * @as(usize, if (focused == i) 2 else 1);
            return i;
        }
        return null;
    }

    fn used(self: *Scheduler, i: usize, count: usize) void {
        self.deficit[i] -= count;
        if (self.priority_slot == i) {
            if (count == 0) self.deficit[i] = 0;
            return;
        }
        if (self.deficit[i] == 0 or count == 0) {
            self.deficit[i] = 0;
            self.cursor = (i + 1) % p.max_streams;
        }
    }
};

const Agent = struct {
    a: std.mem.Allocator,
    io: std.Io,
    streams: [p.max_streams]?Stream = .{null} ** p.max_streams,
    last_id: u32 = 0,
    negotiated: bool = false,
    focused: ?usize = null,
    control: std.ArrayList(u8) = .empty,
    // A partially sent frame is never interrupted by another frame.
    tx: [p.header_len + p.max_data]u8 = undefined,
    tx_len: usize = 0,
    sent: usize = 0,
    last_write: i64 = 0,
    scheduler: Scheduler = .{},
    counters: Counters = .{},
    diagnostics: bool = false,
    pool: ?*read_pool.Pool = null,

    fn frame(self: *Agent, kind: p.pty.Kind, id: u32, payload: []const u8) !void {
        if (self.control.items.len + p.header_len + payload.len > p.control_limit) return error.ControlQueueFull;
        try self.control.appendSlice(self.a, &(p.Header{ .kind = kind, .stream = id, .len = @intCast(payload.len) }).encode());
        try self.control.appendSlice(self.a, payload);
        self.counters.control_high_water = @max(self.counters.control_high_water, self.control.items.len);
    }

    fn number(self: *Agent, kind: p.pty.Kind, id: u32, value: u32) !void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        try self.frame(kind, id, &bytes);
    }

    fn spawn(self: *Agent, id: u32, payload: []const u8) !void {
        const parsed = try std.json.parseFromSlice(p.Spawn, self.a, payload, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        if (parsed.value.cols == 0 or parsed.value.rows == 0) return error.InvalidSize;
        try validateSpawn(parsed.value);
        var slot: ?usize = null;
        for (self.streams, 0..) |entry, i| if (entry == null) {
            slot = i;
            break;
        };
        const index = slot orelse return error.StreamLimit;
        var launch: [2]c_int = undefined;
        if (c.pipe2(&launch, c.O_CLOEXEC | c.O_NONBLOCK) != 0) return error.PipeFailed;
        errdefer _ = c.close(launch[0]);
        defer _ = c.close(launch[1]);
        var size = std.mem.zeroes(c.struct_winsize);
        size.ws_col = parsed.value.cols;
        size.ws_row = parsed.value.rows;
        var master: c_int = -1;
        const parent = c.getpid();
        const pid = c.forkpty(&master, null, null, &size);
        if (pid < 0) return error.ForkFailed;
        if (pid == 0) {
            // Keep only PTY stdio and the exec-status pipe. This also closes
            // inherited PTY masters and the connector's transport descriptors.
            if (launch[1] != 3 and c.dup3(launch[1], 3, c.O_CLOEXEC) < 0) c._exit(126);
            if (std.os.linux.errno(std.os.linux.close_range(4, std.math.maxInt(c_int), .{ .UNSHARE = false, .CLOEXEC = false })) != .SUCCESS) {
                _ = c.write(3, "CloseRangeFailed", 16);
                c._exit(126);
            }
            _ = c.prctl(c.PR_SET_PDEATHSIG, @as(c_ulong, c.SIGKILL), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0));
            if (c.getppid() != parent) c._exit(126);
            pty.execSpawn(self.a, self.io, parsed.value) catch |err| {
                const name = @errorName(err);
                _ = c.write(3, name.ptr, name.len);
            };
            c._exit(127);
        }
        nonblocking(master) catch {
            _ = c.close(master);
            signalGroup(pid, c.SIGKILL);
            _ = c.waitpid(pid, null, 0);
            return error.NonblockingFailed;
        };
        self.streams[index] = .{ .id = id, .pid = pid, .master = master, .launch = launch[0], .started = nowMs() };
        self.scheduler.deficit[index] = 0;
    }

    fn dispatch(self: *Agent, h: p.Header, payload: []const u8) !void {
        if (!self.negotiated) {
            if (h.kind != p.negotiate) return error.NegotiationFailed;
            const ack = try std.json.parseFromSlice(struct { protocol: []const u8, version: u16 }, self.a, payload, .{ .ignore_unknown_fields = true });
            defer ack.deinit();
            if (!std.mem.eql(u8, ack.value.protocol, "hollow-mux") or ack.value.version != 1) return error.NegotiationFailed;
            self.negotiated = true;
            return;
        }
        if (h.kind == p.negotiate) return error.AlreadyNegotiated;
        if (h.kind == .spawn) {
            if (h.stream <= self.last_id) return error.ReusedStream;
            self.last_id = h.stream; // Failed spawns consume their ID, too.
            self.spawn(h.stream, payload) catch |err| try self.frame(.@"error", h.stream, @errorName(err));
            return;
        }
        for (&self.streams, 0..) |*entry, i| if (entry.*) |*s| {
            if (s.id != h.stream) continue;
            if (s.closing != null or (s.eof and h.kind != .close)) return;
            switch (h.kind) {
                .input => {
                    if (s.launch >= 0 or s.eof or payload.len > p.window - s.input.items.len) return error.InputWindowExceeded;
                    try s.input.appendSlice(self.a, payload);
                    self.counters.stream_input_high_water = @max(self.counters.stream_input_high_water, s.input.items.len);
                },
                .resize => {
                    const size = try p.pty.decodeResize(payload);
                    var winsize = std.mem.zeroes(c.struct_winsize);
                    winsize.ws_col = size.cols;
                    winsize.ws_row = size.rows;
                    _ = c.ioctl(s.master, c.TIOCSWINSZ, &winsize);
                },
                .close => {
                    if (payload.len != 0) return error.InvalidClose;
                    s.stop();
                },
                p.credit => {
                    const amount = try p.amount(payload);
                    if (amount > s.output_uncredited) return error.InvalidCredit;
                    s.output_credit = try p.addCredit(s.output_credit, payload);
                    s.output_uncredited -= amount;
                    self.counters.credit_frames += 1;
                },
                p.focus => self.focused = i,
                else => return error.InvalidKind,
            }
            return;
        };
        // Retired IDs can never be allocated again. Ignore in-flight late frames;
        // a reference to an ID that has never been allocated is a protocol error.
        if (h.stream > self.last_id) return error.UnknownStream;
    }

    fn stageControl(self: *Agent) void {
        if (self.tx_len != 0 or self.control.items.len == 0) return;
        // Batch complete control frames by bytes, never by a timer. Draining
        // several credit updates together avoids a syscall per tiny update.
        var count: usize = 0;
        while (count < self.control.items.len) {
            const h = p.Header.decode(self.control.items[count..][0..p.header_len]) catch unreachable;
            const next = count + p.header_len + h.len;
            if (next > self.tx.len) break;
            count = next;
        }
        @memcpy(self.tx[0..count], self.control.items[0..count]);
        self.tx_len = count;
        std.mem.copyForwards(u8, self.control.items, self.control.items[count..]);
        self.control.items.len -= count;
    }

    fn stageOutput(self: *Agent, ready: *[p.max_streams]bool) void {
        std.debug.assert(self.tx_len == 0);
        // Drain immediately ready PTYs into the existing 16 KiB staging bound.
        // Never wait to fill a batch. Bound both syscall work and elapsed time
        // before returning to input/control handling; retain byte DRR per read.
        const deadline = nowNs() + 250_000;
        for (0..32) |turn| {
            const capacity = self.tx.len - self.tx_len;
            if (capacity <= p.header_len or (turn > 0 and nowNs() >= deadline)) break;
            const i = self.scheduler.choose(ready.*, self.focused) orelse break;
            const s = &self.streams[i].?;
            const limit = @min(capacity - p.header_len, @min(s.output_credit, self.scheduler.deficit[i]));
            const before = if (self.diagnostics) nowNs() else 0;
            const n = c.read(s.master, self.tx[self.tx_len + p.header_len ..].ptr, limit);
            if (self.diagnostics) self.counters.pty_read_ns += @intCast(nowNs() - before);
            self.counters.pty_reads += 1;
            if (n > 0) {
                const count: usize = @intCast(n);
                @memcpy(self.tx[self.tx_len..][0..p.header_len], &(p.Header{ .kind = .output, .stream = s.id, .len = @intCast(count) }).encode());
                self.tx_len += p.header_len + count;
                self.counters.output_frames += 1;
                self.counters.output_bytes += count;
                self.counters.tx_high_water = @max(self.counters.tx_high_water, self.tx_len);
                s.output_credit -= @intCast(count);
                s.output_uncredited += @intCast(count);
                self.scheduler.used(i, count);
                if (s.output_credit == 0) ready[i] = false;
            } else {
                self.scheduler.used(i, 0);
                ready[i] = false;
                if (n == 0 or (errno() != c.EINTR and errno() != c.EAGAIN)) {
                    s.eof = true;
                    s.input.clearRetainingCapacity();
                }
            }
        }
    }

    fn collectReads(self: *Agent) !void {
        const pool = self.pool orelse return;
        for (pool.workers[0..pool.count], 0..) |*worker, index| {
            if (worker.state.load(.acquire) != .ready) continue;
            const s = &self.streams[worker.slot].?;
            std.debug.assert(s.id == worker.stream_id and s.read_job == index);
            if (!worker.collected) {
                const unused: u32 = @intCast(worker.allowance - worker.len);
                if (s.output_credit > p.window - unused) return error.InvalidCredit;
                s.output_credit += unused;
                self.counters.pty_reads += worker.reads;
                self.counters.pty_read_ns += worker.read_ns;
                if (worker.eof) {
                    s.eof = true;
                    s.input.clearRetainingCapacity();
                }
                worker.collected = true;
            }
            if (s.closing != null or worker.len == 0) {
                s.read_job = null;
                pool.release(index);
            }
        }
    }

    fn dispatchReads(self: *Agent, ready: *[p.max_streams]bool) !void {
        const pool = self.pool.?;
        while (pool.idle()) |index| {
            const slot = self.scheduler.choose(ready.*, self.focused) orelse break;
            const s = &self.streams[slot].?;
            const quantum = self.scheduler.deficit[slot] * 2;
            const allowance = @min(quantum, s.output_credit);
            pool.submit(index, s.master, slot, s.id, allowance, self.diagnostics) catch |err| {
                try self.frame(.@"error", s.id, @errorName(err));
                s.stop();
                ready[slot] = false;
                continue;
            };
            // Async jobs use bounded byte-quantum round robin: focus has twice
            // the read allowance. Short reads discard unused quantum instead
            // of accumulating it; only this job may read this stream at a time.
            self.scheduler.used(slot, self.scheduler.deficit[slot]);
            s.output_credit -= @intCast(allowance);
            s.read_job = index;
            ready[slot] = false;
            var reserved: usize = 0;
            for (pool.workers[0..pool.count]) |*worker| {
                if (worker.state.load(.acquire) != .idle) reserved += worker.allowance;
            }
            self.counters.read_pool_reserved_high_water = @max(self.counters.read_pool_reserved_high_water, reserved);
        }
    }

    fn stageReadResults(self: *Agent) void {
        const pool = self.pool.?;
        std.debug.assert(self.tx_len == 0);
        for (0..read_pool.max_workers * 2) |_| {
            const capacity = self.tx.len - self.tx_len;
            if (capacity <= p.header_len) break;
            const index = pool.output() orelse break;
            const worker = &pool.workers[index];
            const s = &self.streams[worker.slot].?;
            const count = @min(p.max_data, @min(capacity - p.header_len, worker.len - worker.offset));
            @memcpy(self.tx[self.tx_len..][0..p.header_len], &(p.Header{ .kind = .output, .stream = s.id, .len = @intCast(count) }).encode());
            @memcpy(self.tx[self.tx_len + p.header_len ..][0..count], worker.buffer[worker.offset..][0..count]);
            self.tx_len += p.header_len + count;
            worker.offset += count;
            s.output_uncredited += @intCast(count);
            self.counters.output_frames += 1;
            self.counters.output_bytes += count;
            self.counters.tx_high_water = @max(self.counters.tx_high_water, self.tx_len);
            if (worker.offset == worker.len) {
                s.read_job = null;
                pool.release(index);
            }
        }
    }
};

pub fn run(a: std.mem.Allocator, io: std.Io) !void {
    _ = c.signal(c.SIGPIPE, ignoreSignal);
    _ = c.signal(c.SIGTERM, stopSignal);
    _ = c.signal(c.SIGINT, stopSignal);
    try nonblocking(0);
    try nonblocking(1);
    var agent = Agent{ .a = a, .io = io, .last_write = nowMs() };
    const diagnostics = c.getenv("HOLLOW_MUX_DIAGNOSTICS") != null;
    agent.diagnostics = diagnostics;
    defer if (diagnostics) {
        var usage: c.struct_rusage = undefined;
        if (c.getrusage(c.RUSAGE_SELF, &usage) == 0) {
            agent.counters.user_us = usage.ru_utime.tv_sec * 1_000_000 + usage.ru_utime.tv_usec;
            agent.counters.system_us = usage.ru_stime.tv_sec * 1_000_000 + usage.ru_stime.tv_usec;
        }
        var buf: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "mux diagnostics: {f}\n", .{std.json.fmt(agent.counters, .{})}) catch "mux diagnostics: formatting failed\n";
        _ = c.write(2, text.ptr, text.len);
    };
    defer {
        // No transport writes during cleanup. Bounded grace, then group kill.
        for (&agent.streams) |*entry| if (entry.*) |*s| s.stop();
        const deadline = nowMs() + 1500;
        while (nowMs() < deadline) {
            var active = false;
            for (&agent.streams) |*entry| if (entry.*) |*s| {
                reap(s);
                if (s.status == null) active = true;
            };
            if (!active) break;
            _ = c.poll(null, 0, 10);
        }
        for (&agent.streams) |*entry| if (entry.*) |*s| {
            if (s.status == null) signalGroup(s.pid, c.SIGKILL);
        };
        const kill_deadline = nowMs() + 250;
        while (nowMs() < kill_deadline) {
            var active = false;
            for (&agent.streams) |*entry| if (entry.*) |*s| {
                reap(s);
                if (s.status == null) active = true;
            };
            if (!active) break;
            _ = c.poll(null, 0, 5);
        }
        for (&agent.streams) |*entry| if (entry.*) |*s| s.deinit(a);
        agent.control.deinit(a);
    }
    // Explicit experiment only; zero retains the inline implementation for A/B
    // runs. Spawn preparation stays on the owner/forked child, never workers.
    const worker_count = if (c.getenv("HOLLOW_MUX_READ_WORKERS")) |value| try std.fmt.parseInt(usize, std.mem.span(value), 10) else 0;
    if (worker_count > read_pool.max_workers) return error.InvalidWorkerCount;
    if (worker_count > 0) {
        const pool = try a.create(read_pool.Pool);
        pool.* = .{};
        pool.start(worker_count) catch |err| {
            a.destroy(pool);
            return err;
        };
        agent.pool = pool;
    }
    defer if (agent.pool) |pool| {
        // Join before stream teardown; no worker references streams. Inline
        // mode never allocates/touches the worker buffers or thread stacks.
        pool.deinit();
        for (&agent.streams) |*entry| if (entry.*) |*s| {
            s.read_job = null; // Joined jobs are discarded by connection abort.
        };
        a.destroy(pool);
    };
    agent.counters.read_workers = worker_count;
    var reader: p.Reader = .{};
    defer reader.deinit(a);
    try agent.frame(.hello, 0, p.hello);
    const started = nowMs();
    while (true) {
        if (stopping.load(.monotonic)) return;
        agent.stageControl();
        var fds: [3 + p.max_streams * 2]c.struct_pollfd = undefined;
        fds[0] = .{ .fd = 0, .events = c.POLLIN, .revents = 0 };
        fds[1] = .{ .fd = 1, .events = if (agent.tx_len > 0) c.POLLOUT else 0, .revents = 0 };
        fds[2] = .{ .fd = if (agent.pool) |pool| pool.completion_fd else -1, .events = c.POLLIN, .revents = 0 };
        const can_read = if (agent.pool) |pool| pool.idle() != null else agent.tx_len == 0 and agent.control.items.len == 0;
        for (agent.streams, 0..) |entry, i| {
            fds[3 + i * 2] = .{ .fd = if (entry) |s| s.master else -1, .events = 0, .revents = 0 };
            fds[4 + i * 2] = .{ .fd = if (entry) |s| s.launch else -1, .events = c.POLLIN, .revents = 0 };
            if (entry) |s| {
                if (!s.eof and s.launch < 0 and s.output_credit > 0 and s.read_job == null and can_read) fds[3 + i * 2].events |= c.POLLIN;
                if (s.input.items.len > 0) fds[3 + i * 2].events |= c.POLLOUT;
                // HUP ignores events: remove blocked/EOF descriptors to avoid
                // a busy loop when a stopped consumer exhausts its window.
                if (fds[3 + i * 2].events == 0) fds[3 + i * 2].fd = -1;
            }
        }
        const poll_started = if (diagnostics) nowNs() else 0;
        const polled = c.poll(&fds, fds.len, 10);
        if (diagnostics) agent.counters.poll_ns += @intCast(nowNs() - poll_started);
        agent.counters.polls += 1;
        if (polled < 0) {
            if (errno() == c.EINTR) continue;
            return error.PollFailed;
        }
        if ((fds[2].revents & c.POLLIN) != 0) read_pool.drainNotification(agent.pool.?.completion_fd);
        if ((fds[1].revents & (c.POLLHUP | c.POLLERR)) != 0) return;
        if ((fds[1].revents & c.POLLOUT) != 0) {
            agent.counters.transport_writes += 1;
            const write_started = if (diagnostics) nowNs() else 0;
            const n = c.write(1, agent.tx[agent.sent..].ptr, agent.tx_len - agent.sent);
            if (diagnostics) agent.counters.transport_write_ns += @intCast(nowNs() - write_started);
            if (n > 0) {
                agent.counters.transport_bytes += @intCast(n);
                agent.sent += @intCast(n);
                agent.last_write = nowMs();
                if (agent.sent == agent.tx_len) {
                    agent.sent = 0;
                    agent.tx_len = 0;
                }
            } else if (n < 0 and errno() != c.EINTR and errno() != c.EAGAIN) return;
        }
        if (agent.tx_len == 0 and agent.control.items.len == 0) agent.last_write = nowMs();
        if (nowMs() - agent.last_write > 10000) return error.StalledTransport;
        if (!agent.negotiated and nowMs() - started > 10000) return error.NegotiationTimeout;
        if ((fds[0].revents & (c.POLLIN | c.POLLHUP | c.POLLERR)) != 0) {
            var bytes: [8192]u8 = undefined;
            const n = c.read(0, &bytes, bytes.len);
            if (n == 0) return;
            if (n < 0) {
                if (errno() != c.EINTR and errno() != c.EAGAIN) return error.ReadFailed;
            } else {
                try reader.push(a, bytes[0..@intCast(n)]);
                agent.counters.reader_high_water = @max(agent.counters.reader_high_water, reader.buffered());
            }
        }
        // Validate header limits before waiting for/allocating its payload.
        while (reader.buffered() >= p.header_len) {
            const h = try p.Header.decode(reader.buffer.items[reader.start..][0..p.header_len]);
            try p.validateHeader(h);
            const frame = (try reader.next()) orelse break;
            try agent.dispatch(frame.header, frame.payload);
        }
        try agent.collectReads();
        var ready: [p.max_streams]bool = .{false} ** p.max_streams;
        for (&agent.streams, 0..) |*entry, i| if (entry.*) |*s| {
            reap(s);
            if (s.closing) |start| {
                if (s.status == null and nowMs() - start >= 1500) signalGroup(s.pid, c.SIGKILL);
            }
            if (s.launch >= 0 and s.closing == null and nowMs() - s.started > 10000) {
                try agent.frame(.@"error", s.id, "SpawnTimeout");
                s.failed = true;
                s.stop();
            }
            if (s.launch >= 0 and (fds[4 + i * 2].revents & (c.POLLIN | c.POLLHUP | c.POLLERR)) != 0) {
                var message: [256]u8 = undefined;
                const n = c.read(s.launch, &message, message.len);
                if (n >= 0) {
                    _ = c.close(s.launch);
                    s.launch = -1;
                    if (n > 0) {
                        try agent.frame(.@"error", s.id, message[0..@intCast(n)]);
                        s.failed = true;
                        s.stop();
                    } else if (s.closing == null) try agent.number(p.spawned, s.id, p.window);
                }
            }
            if (s.input.items.len > 0 and (fds[3 + i * 2].revents & c.POLLOUT) != 0) {
                const n = c.write(s.master, s.input.items.ptr, @min(p.max_data, s.input.items.len));
                if (n > 0) {
                    const count: usize = @intCast(n);
                    std.mem.copyForwards(u8, s.input.items, s.input.items[count..]);
                    s.input.items.len -= count;
                    try agent.number(p.credit, s.id, @intCast(count));
                } else if (n < 0 and errno() != c.EINTR and errno() != c.EAGAIN) {
                    try agent.frame(.@"error", s.id, "PtyInputFailed");
                    s.stop();
                }
            }
            ready[i] = !s.eof and s.launch < 0 and s.output_credit > 0 and s.read_job == null and (fds[3 + i * 2].revents & (c.POLLIN | c.POLLHUP | c.POLLERR)) != 0;
            if (s.status != null and s.eof and s.launch < 0 and s.read_job == null) {
                // The one staged data frame precedes these queued exit bytes.
                if (!s.failed) try agent.number(.exit, s.id, s.status.?);
                s.deinit(a);
                entry.* = null;
                ready[i] = false;
                if (agent.focused == i) agent.focused = null;
            }
        };
        if (agent.pool != null) {
            try agent.dispatchReads(&ready);
            if (agent.tx_len == 0 and agent.control.items.len == 0) agent.stageReadResults();
        } else if (agent.tx_len == 0 and agent.control.items.len == 0) {
            agent.stageOutput(&ready);
        }
    }
}

fn validateSpawn(spawn: p.Spawn) !void {
    for (spawn.argv) |arg| if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidArgv;
    if (spawn.cwd) |cwd| if (std.mem.indexOfScalar(u8, cwd, 0) != null) return error.InvalidCwd;
    if (spawn.command) |cmd| if (std.mem.indexOfScalar(u8, cmd, 0) != null) return error.InvalidCommand;
    for (spawn.env) |env| {
        if (env.key.len == 0 or std.mem.indexOfAny(u8, env.key, "=\x00") != null or std.mem.indexOfScalar(u8, env.value, 0) != null) return error.InvalidEnv;
    }
}

fn reap(s: *Stream) void {
    if (s.status != null or !s.eof or s.read_job != null) return;
    // Keep the zombie's PID reserved until output drains (or close aborts it).
    // Otherwise a stopped consumer could retain a reaped PID long enough for
    // a later process-group signal to hit an unrelated, recycled process ID.
    var info = std.mem.zeroes(c.siginfo_t);
    if (c.waitid(c.P_PID, @intCast(s.pid), &info, c.WEXITED | c.WNOHANG | c.WNOWAIT) != 0 or info.si_signo == 0) return;
    signalGroup(s.pid, c.SIGKILL);
    var status: c_int = 0;
    if (c.waitpid(s.pid, &status, c.WNOHANG) == s.pid) {
        s.status = if (c.WIFEXITED(status)) @intCast(c.WEXITSTATUS(status)) else if (c.WIFSIGNALED(status)) 128 + @as(u32, @intCast(c.WTERMSIG(status))) else 1;
    }
}

fn signalGroup(pid: c.pid_t, sig: c_int) void {
    _ = c.kill(-pid, sig);
    // Close can race forkpty's child before it has created its process group.
    _ = c.kill(pid, sig);
}

fn nonblocking(fd: c_int) !void {
    const flags = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    if (flags < 0 or c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) < 0) return error.NonblockingFailed;
}

fn ignoreSignal(_: c_int) callconv(.c) void {}
fn stopSignal(_: c_int) callconv(.c) void {
    stopping.store(true, .monotonic);
}
fn errno() c_int {
    return c.__errno_location().*;
}
fn nowMs() i64 {
    return @divTrunc(nowNs(), 1_000_000);
}
fn nowNs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return ts.sec * 1_000_000_000 + ts.nsec;
}

test "byte scheduler bounds focused preference and guarantees background progress" {
    var scheduler: Scheduler = .{};
    var ready = [_]bool{false} ** p.max_streams;
    ready[0] = true;
    ready[1] = true;
    const expected = [_]usize{ 0, 1, 0, 1, 0, 1 };
    for (expected) |i| {
        try std.testing.expectEqual(i, scheduler.choose(ready, 0).?);
        scheduler.used(i, p.max_data);
    }
    ready[0] = false;
    try std.testing.expectEqual(@as(usize, 1), scheduler.choose(ready, 0).?);
}

test "scheduler accounts partial reads by bytes and drops idle deficit" {
    var scheduler: Scheduler = .{};
    var ready = [_]bool{false} ** p.max_streams;
    ready[0] = true;
    ready[1] = true;
    try std.testing.expectEqual(@as(usize, 0), scheduler.choose(ready, null).?);
    scheduler.used(0, 123);
    try std.testing.expectEqual(@as(usize, p.max_data - 123), scheduler.deficit[0]);
    ready[0] = false;
    try std.testing.expectEqual(@as(usize, 1), scheduler.choose(ready, null).?);
    try std.testing.expectEqual(@as(usize, 0), scheduler.deficit[0]);
}

test "focus-first turns preserve every background position within bounded round" {
    var scheduler: Scheduler = .{};
    const ready = [_]bool{true} ** p.max_streams;
    var counts = [_]usize{0} ** p.max_streams;
    for (0..2 * (p.max_streams - 1)) |turn| {
        const i = scheduler.choose(ready, 17).?;
        if (turn % 2 == 0) try std.testing.expectEqual(@as(usize, 17), i);
        counts[i] += 1;
        scheduler.used(i, p.max_data);
    }
    for (counts, 0..) |count, i| try std.testing.expectEqual(@as(usize, if (i == 17) p.max_streams - 1 else 1), count);
}

test "partial focused reads do not move background cursor or spend its deficit" {
    var scheduler: Scheduler = .{};
    var ready = [_]bool{false} ** p.max_streams;
    ready[0] = true;
    ready[31] = true;
    try std.testing.expectEqual(@as(usize, 31), scheduler.choose(ready, 31).?);
    scheduler.used(31, 1);
    try std.testing.expectEqual(@as(usize, 0), scheduler.cursor);
    try std.testing.expectEqual(@as(usize, 0), scheduler.choose(ready, 31).?);
    scheduler.used(0, 123);
    try std.testing.expectEqual(@as(usize, 31), scheduler.choose(ready, 31).?);
    scheduler.used(31, 1);
    try std.testing.expectEqual(@as(usize, p.max_data - 123), scheduler.deficit[0]);
    try std.testing.expectEqual(@as(usize, 0), scheduler.choose(ready, 31).?);
}

test "focus-only and no-ready scheduling remain live without background work" {
    var scheduler: Scheduler = .{};
    var ready = [_]bool{false} ** p.max_streams;
    try std.testing.expect(scheduler.choose(ready, 31) == null);
    ready[31] = true;
    for (0..8) |_| {
        try std.testing.expectEqual(@as(usize, 31), scheduler.choose(ready, 31).?);
        scheduler.used(31, p.max_data);
    }
    ready[31] = false;
    try std.testing.expect(scheduler.choose(ready, 31) == null);
}

test {
    _ = p;
    _ = read_pool;
}
