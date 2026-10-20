//! Opt-in multi-PTY transport. One poll owner, no thread per pane. Output
//! frames share one bounded staging buffer; control precedes the next batch.
const std = @import("std");
const p = @import("mux_protocol.zig");
const pty = @import("pty.zig");
const pty_readers = @import("pty_readers.zig");
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
    inline_reads: u64 = 0,
    read_batch_jobs: usize = 1,
    reader_wakes: u64 = 0,
    reader_parks: u64 = 0,
    owner_wakes: u64 = 0,
};

const Stream = struct {
    id: u32,
    pid: c.pid_t,
    master: c_int,
    launch: c_int,
    input: std.ArrayList(u8) = .empty,
    output_credit: u32 = p.window,
    output_uncredited: u32 = 0,
    /// Master is pinned to a reader thread, which owns closing it.
    attached: bool = false,
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
    // Transport state: control, tx, sent, and the counters they update are
    // touched only under `lock`, since reader threads flush, too.
    lock: pty_readers.Mutex = .{},
    // A partially sent frame is never interrupted by another frame.
    tx: [p.header_len + p.max_data]u8 = undefined,
    tx_len: usize = 0,
    sent: usize = 0,
    out_fd: c_int = 1,
    shutdown: bool = false,
    last_write: std.atomic.Value(i64) = .init(0),
    /// A flusher found the lock taken; the holder retries after unlocking.
    flush_pending: std.atomic.Value(bool) = .init(false),
    /// Write hit EAGAIN or was partial: only the owner retries, on POLLOUT.
    blocked: std.atomic.Value(bool) = .init(false),
    transport_failed: std.atomic.Value(bool) = .init(false),
    scheduler: Scheduler = .{},
    counters: Counters = .{},
    diagnostics: bool = false,
    readers: ?*pty_readers.Set = null,

    fn frame(self: *Agent, kind: p.pty.Kind, id: u32, payload: []const u8) !void {
        self.lock.lock();
        defer self.lock.unlock();
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
        self.lock.lock();
        self.scheduler.deficit[index] = 0;
        self.lock.unlock();
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
                    self.stopStream(i);
                },
                p.credit => {
                    const amount = try p.amount(payload);
                    if (s.attached) {
                        const slot = &self.readers.?.slots[i];
                        if (amount > slot.uncredited.load(.acquire)) return error.InvalidCredit;
                        try self.readers.?.grant(i, amount);
                        _ = slot.uncredited.fetchSub(amount, .release);
                    } else {
                        if (amount > s.output_uncredited) return error.InvalidCredit;
                        s.output_credit = try p.addCredit(s.output_credit, payload);
                        s.output_uncredited -= amount;
                    }
                    self.counters.credit_frames += 1;
                },
                p.focus => {
                    self.focused = i;
                    if (self.readers) |set| set.focused.store(@intCast(i), .monotonic);
                },
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
            self.counters.inline_reads += 1;
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

    /// Stop a stream. A reader-pinned master is closed by its reader once
    /// it acknowledges the detach; the owner stops using it immediately.
    fn stopStream(self: *Agent, i: usize) void {
        const s = &self.streams[i].?;
        if (s.attached) {
            s.master = -1;
            // Under the lock, so no flusher frames this stream after close.
            self.lock.lock();
            self.readers.?.requestDetach(i);
            self.lock.unlock();
        }
        s.stop();
    }

    /// Frame reader ring bytes behind any already staged bytes. Callers
    /// stage control first, so control frames keep preceding output.
    /// Alternate focus-first turns with background DRR, retaining the cursor
    /// across full staging buffers so a flood cannot monopolize the transport.
    /// Runs under the transport lock on any thread, so it reads only slots.
    fn stageRings(self: *Agent) void {
        const set = self.readers.?;
        const focus = set.focused.load(.monotonic);
        var ready: [p.max_streams]bool = .{false} ** p.max_streams;
        for (&set.slots, 0..) |*slot, i| {
            ready[i] = slot.attached.load(.acquire) and !slot.detach.load(.acquire) and slot.pending() > 0;
        }
        while (true) {
            const capacity = self.tx.len - self.tx_len;
            if (capacity <= p.header_len) return;
            const i = self.scheduler.choose(ready, if (focus < p.max_streams) focus else null) orelse return;
            const slot = &set.slots[i];
            const limit = @min(p.max_data, @min(capacity - p.header_len, self.scheduler.deficit[i]));
            const body = self.tx[self.tx_len + p.header_len ..];
            var count: usize = 0;
            // At most two pieces: up to the ring end, then from its start.
            for (0..2) |_| {
                const piece = set.readable(i, limit - count);
                if (piece.len == 0) break;
                @memcpy(body[count..][0..piece.len], piece);
                set.consume(i, @intCast(piece.len));
                count += piece.len;
            }
            self.scheduler.used(i, count);
            ready[i] = slot.pending() > 0;
            if (count == 0) continue;
            @memcpy(self.tx[self.tx_len..][0..p.header_len], &(p.Header{ .kind = .output, .stream = slot.stream_id, .len = @intCast(count) }).encode());
            self.tx_len += p.header_len + count;
            _ = slot.uncredited.fetchAdd(@intCast(count), .release);
            self.counters.output_frames += 1;
            self.counters.output_bytes += count;
            self.counters.tx_high_water = @max(self.counters.tx_high_water, self.tx_len);
        }
    }

    /// Try a staged transport write without waiting for poll readiness. Returns
    /// false only when connection must close. EAGAIN preserves the frame and
    /// leaves POLLOUT polling responsible for retrying it.
    fn flushTransport(self: *Agent, fd: c_int) bool {
        if (self.tx_len == 0) return true;
        self.counters.transport_writes += 1;
        const write_started = if (self.diagnostics) nowNs() else 0;
        const n = c.write(fd, self.tx[self.sent..].ptr, self.tx_len - self.sent);
        if (self.diagnostics) self.counters.transport_write_ns += @intCast(nowNs() - write_started);
        if (n > 0) {
            self.counters.transport_bytes += @intCast(n);
            self.sent += @intCast(n);
            self.last_write.store(nowMs(), .monotonic);
            if (self.sent == self.tx_len) {
                self.sent = 0;
                self.tx_len = 0;
            }
            return true;
        }
        if (n < 0 and (errno() == c.EINTR or errno() == c.EAGAIN)) return true;
        return false;
    }

    /// Lock held: stage and write until nothing is staged or the transport
    /// blocks. A fresh frame gets one immediate nonblocking attempt; after
    /// EAGAIN or a partial write, only the owner retries, on POLLOUT.
    /// Terminates: ringed bytes are bounded by every stream's credit.
    fn pumpLocked(self: *Agent) bool {
        if (self.shutdown) return true;
        while (!self.blocked.load(.seq_cst)) {
            self.stageControl();
            if (self.readers != null and self.control.items.len == 0) self.stageRings();
            if (self.tx_len == 0) return true;
            if (!self.flushTransport(self.out_fd)) return false;
            if (self.tx_len > 0) self.blocked.store(true, .seq_cst);
        }
        return true;
    }

    /// Lock held: pump, unlock, and retake the lock for flushes requested
    /// while it was held. Returns false when the transport failed.
    fn pumpAndUnlock(self: *Agent) bool {
        while (true) {
            self.flush_pending.store(false, .seq_cst);
            const ok = self.pumpLocked();
            self.lock.unlock();
            if (!ok) {
                self.transport_failed.store(true, .seq_cst);
                return false;
            }
            if (!self.flush_pending.load(.seq_cst) or !self.lock.tryLock()) return true;
        }
    }

    fn pump(self: *Agent) bool {
        self.lock.lock();
        return self.pumpAndUnlock();
    }

    /// Reader callback. Never waits for the lock: a busy holder sees
    /// `flush_pending` after unlocking and flushes these bytes itself.
    fn readerFlush(ctx: *anyopaque) bool {
        const self: *Agent = @ptrCast(@alignCast(ctx));
        self.flush_pending.store(true, .seq_cst);
        if (!self.lock.tryLock()) return false;
        return !self.pumpAndUnlock() or self.blocked.load(.seq_cst);
    }
};

pub fn run(a: std.mem.Allocator, io: std.Io) !void {
    _ = c.signal(c.SIGPIPE, ignoreSignal);
    _ = c.signal(c.SIGTERM, stopSignal);
    _ = c.signal(c.SIGINT, stopSignal);
    try nonblocking(0);
    try nonblocking(1);
    var agent = Agent{ .a = a, .io = io, .last_write = .init(nowMs()) };
    const diagnostics = c.getenv("HOLLOW_MUX_DIAGNOSTICS") != null;
    agent.diagnostics = diagnostics;
    defer if (diagnostics) {
        var usage: c.struct_rusage = undefined;
        if (c.getrusage(c.RUSAGE_SELF, &usage) == 0) {
            agent.counters.user_us = usage.ru_utime.tv_sec * 1_000_000 + usage.ru_utime.tv_usec;
            agent.counters.system_us = usage.ru_stime.tv_sec * 1_000_000 + usage.ru_stime.tv_usec;
        }
        var buf: [2048]u8 = undefined;
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
    // Zero keeps every PTY read on the owner. Nonzero pins each stream to one
    // of that many persistent reader threads. Spawn preparation stays on the
    // owner/forked child, never readers.
    const worker_count = if (c.getenv("HOLLOW_MUX_READ_WORKERS")) |value| try std.fmt.parseInt(usize, std.mem.span(value), 10) else 0;
    if (worker_count > pty_readers.max_readers) return error.InvalidWorkerCount;
    // Accepted for configuration compatibility; persistent readers have no
    // job batches, so the value no longer changes scheduling.
    const batch_jobs = if (c.getenv("HOLLOW_MUX_READ_BATCH_JOBS")) |value| try std.fmt.parseInt(usize, std.mem.span(value), 10) else 1;
    if (batch_jobs == 0 or batch_jobs > 2) return error.InvalidBatchSize;
    agent.counters.read_batch_jobs = batch_jobs;
    if (worker_count > 0) {
        const set = try a.create(pty_readers.Set);
        set.* = .{ .flush = Agent.readerFlush, .flush_ctx = &agent };
        set.start(worker_count, diagnostics) catch |err| {
            a.destroy(set);
            return err;
        };
        agent.readers = set;
    }
    defer if (agent.readers) |set| {
        agent.lock.lock();
        agent.shutdown = true;
        agent.lock.unlock();
        // Join before stream teardown. Joined readers released nothing, so
        // the set closes descriptors of still-attached streams itself.
        set.deinit();
        for (&agent.streams) |*entry| if (entry.*) |*s| if (s.attached) {
            s.master = -1;
            s.attached = false;
        };
        set.freeRings(a);
        agent.counters.pty_reads += set.final.reads;
        agent.counters.pty_read_ns += set.final.read_ns;
        agent.counters.reader_wakes = set.final.wakes;
        agent.counters.reader_parks = set.final.parks;
        agent.counters.owner_wakes = set.final.owner_wakes;
        a.destroy(set);
    };
    agent.counters.read_workers = worker_count;
    var reader: p.Reader = .{};
    defer reader.deinit(a);
    try agent.frame(.hello, 0, p.hello);
    const started = nowMs();
    while (true) {
        if (stopping.load(.monotonic)) return;
        if (!agent.pump()) return;
        const write_blocked = agent.blocked.load(.seq_cst);
        var fds: [3 + p.max_streams * 2]c.struct_pollfd = undefined;
        fds[0] = .{ .fd = 0, .events = c.POLLIN, .revents = 0 };
        fds[1] = .{ .fd = 1, .events = if (write_blocked) c.POLLOUT else 0, .revents = 0 };
        fds[2] = .{ .fd = if (agent.readers) |set| set.wake_fd else -1, .events = c.POLLIN, .revents = 0 };
        // Inline only: no other thread touches the transport.
        const can_read = agent.readers == null and !write_blocked;
        for (agent.streams, 0..) |entry, i| {
            fds[3 + i * 2] = .{ .fd = if (entry) |s| s.master else -1, .events = 0, .revents = 0 };
            fds[4 + i * 2] = .{ .fd = if (entry) |s| s.launch else -1, .events = c.POLLIN, .revents = 0 };
            if (entry) |s| {
                if (!s.eof and s.launch < 0 and s.output_credit > 0 and can_read) fds[3 + i * 2].events |= c.POLLIN;
                if (s.input.items.len > 0) fds[3 + i * 2].events |= c.POLLOUT;
                // HUP ignores events: remove blocked/EOF descriptors to avoid
                // a busy loop when a stopped consumer exhausts its window.
                if (fds[3 + i * 2].events == 0) fds[3 + i * 2].fd = -1;
            }
        }
        const poll_started = if (diagnostics) nowNs() else 0;
        // Pumping leaves control queued only behind a blocked transport. With
        // readers, announce the sleep so EOF, detach, or a reader that blocks
        // the transport wakes us; while blocked, POLLOUT is the wakeup.
        var timeout: c_int = 10;
        if (agent.readers) |set| {
            if (!write_blocked and (!set.prepareSleep() or agent.flush_pending.load(.seq_cst) or agent.blocked.load(.seq_cst))) {
                set.awake();
                timeout = 0;
            }
        }
        const polled = c.poll(&fds, fds.len, timeout);
        if (agent.readers) |set| set.awake();
        if (diagnostics) agent.counters.poll_ns += @intCast(nowNs() - poll_started);
        agent.counters.polls += 1;
        if (polled < 0) {
            if (errno() == c.EINTR) continue;
            return error.PollFailed;
        }
        if ((fds[2].revents & c.POLLIN) != 0) agent.readers.?.drainWake();
        if ((fds[1].revents & (c.POLLHUP | c.POLLERR)) != 0) return;
        if (agent.transport_failed.load(.seq_cst)) return;
        if ((fds[1].revents & c.POLLOUT) != 0) {
            agent.blocked.store(false, .seq_cst);
            if (!agent.pump()) return;
        }
        if (!agent.blocked.load(.seq_cst)) agent.last_write.store(nowMs(), .monotonic);
        if (nowMs() - agent.last_write.load(.monotonic) > 10000) return error.StalledTransport;
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
        var ready: [p.max_streams]bool = .{false} ** p.max_streams;
        for (&agent.streams, 0..) |*entry, i| if (entry.*) |*s| {
            if (s.attached) {
                const set = agent.readers.?;
                // Reader EOF counts once every ringed byte has been framed.
                if (!s.eof and set.slots[i].eof.load(.acquire) and set.slots[i].pending() == 0) {
                    s.eof = true;
                    s.input.clearRetainingCapacity();
                    s.master = -1;
                    set.requestDetach(i);
                }
                if (s.eof and set.released(i)) s.attached = false;
            }
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
                    } else if (s.closing == null) {
                        try agent.number(p.spawned, s.id, p.window);
                        if (agent.readers) |set| {
                            agent.lock.lock();
                            const attached = set.attach(a, i, s.id, s.master, s.output_credit);
                            agent.lock.unlock();
                            if (attached) {
                                s.attached = true;
                            } else |err| {
                                try agent.frame(.@"error", s.id, @errorName(err));
                                s.failed = true;
                                s.stop();
                            }
                        }
                    }
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
                    agent.stopStream(i);
                }
            }
            ready[i] = !s.eof and s.launch < 0 and s.output_credit > 0 and (fds[3 + i * 2].revents & (c.POLLIN | c.POLLHUP | c.POLLERR)) != 0;
            if (s.status != null and s.eof and s.launch < 0 and !s.attached) {
                // Every framed output byte of this stream precedes the exit.
                if (!s.failed) try agent.number(.exit, s.id, s.status.?);
                s.deinit(a);
                entry.* = null;
                ready[i] = false;
                if (agent.focused == i) {
                    agent.focused = null;
                    if (agent.readers) |set| set.focused.store(pty_readers.Set.no_focus, .monotonic);
                }
            }
        };
        if (agent.readers == null and agent.tx_len == 0 and agent.control.items.len == 0) agent.stageOutput(&ready);
        // Bottom-staged data is fresh; make its first write attempt now rather
        // than adding a poll interval. EAGAIN is remembered until POLLOUT.
        if (!agent.pump()) return;
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
    if (s.status != null or !s.eof) return;
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

test "transport flush preserves staged control frame across EAGAIN and partial writes" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe2(&fds, c.O_NONBLOCK | c.O_CLOEXEC));
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);
    try std.testing.expectEqual(@as(c_int, 4096), c.fcntl(fds[1], c.F_SETPIPE_SZ, @as(c_int, 4096)));

    var fill: [4096]u8 = .{0xaa} ** 4096;
    while (true) {
        const n = c.write(fds[1], &fill, fill.len);
        if (n < 0) {
            try std.testing.expectEqual(@as(c_int, c.EAGAIN), errno());
            break;
        }
    }

    var agent: Agent = .{ .a = std.testing.allocator, .io = undefined };
    defer agent.control.deinit(std.testing.allocator);
    try agent.frame(.hello, 0, p.hello);
    agent.stageControl();
    const staged_len = agent.tx_len;
    try std.testing.expect(staged_len > 0);
    try std.testing.expect(agent.flushTransport(fds[1]));
    try std.testing.expectEqual(staged_len, agent.tx_len);
    try std.testing.expectEqual(@as(usize, 0), agent.sent);

    var drained: [8192]u8 = undefined;
    while (c.read(fds[0], &drained, drained.len) > 0) {}
    const expected_control = try std.testing.allocator.dupe(u8, agent.tx[0..staged_len]);
    defer std.testing.allocator.free(expected_control);
    try std.testing.expect(agent.flushTransport(fds[1]));
    try std.testing.expectEqual(@as(usize, 0), agent.tx_len);
    try std.testing.expectEqual(@as(isize, @intCast(staged_len)), c.read(fds[0], &drained, drained.len));
    try std.testing.expectEqualSlices(u8, expected_control, drained[0..staged_len]);
    // Frame is larger than pipe capacity, forcing a successful partial write.
    agent.tx_len = 8192;
    agent.sent = 0;
    @memset(agent.tx[0..agent.tx_len], 0x5a);
    try std.testing.expect(agent.flushTransport(fds[1]));
    try std.testing.expect(agent.sent > 0 and agent.sent < agent.tx_len);
    const sent = agent.sent;
    try std.testing.expect(agent.flushTransport(fds[1]));
    try std.testing.expectEqual(sent, agent.sent); // EAGAIN retains exact offset.
    try std.testing.expectEqual(@as(isize, @intCast(sent)), c.read(fds[0], &drained, drained.len));
    for (drained[0..sent]) |byte| try std.testing.expectEqual(@as(u8, 0x5a), byte);
    try std.testing.expect(agent.flushTransport(fds[1]));
    try std.testing.expectEqual(@as(usize, 0), agent.tx_len);
    try std.testing.expectEqual(@as(usize, 0), agent.sent);
    const remaining = 8192 - sent;
    try std.testing.expectEqual(@as(isize, @intCast(remaining)), c.read(fds[0], &drained, drained.len));
    for (drained[0..remaining]) |byte| try std.testing.expectEqual(@as(u8, 0x5a), byte);
}

test "reader rings rotate full frames across staging buffers" {
    var set: pty_readers.Set = .{};
    var agent: Agent = .{ .a = std.testing.allocator, .io = undefined, .readers = &set };
    var rings: [3][pty_readers.ring_size]u8 = .{.{0} ** pty_readers.ring_size} ** 3;
    for (&rings, 0..) |*ring, i| {
        set.slots[i].ring = ring;
        set.slots[i].stream_id = @intCast(i + 1);
        set.slots[i].head.raw = p.window;
        set.slots[i].attached.raw = true;
    }
    for ([_]u32{ 1, 2, 3, 1, 2, 3 }) |id| {
        agent.stageRings();
        const header = try p.Header.decode(agent.tx[0..p.header_len]);
        try std.testing.expectEqual(id, header.stream);
        try std.testing.expectEqual(p.max_data, header.len);
        try std.testing.expectEqual(agent.tx.len, agent.tx_len);
        agent.tx_len = 0; // Simulate a complete transport write.
    }
}

test "focused reader flood alternates with rotating background frames" {
    var set: pty_readers.Set = .{};
    var agent: Agent = .{ .a = std.testing.allocator, .io = undefined, .readers = &set };
    var rings: [3][pty_readers.ring_size]u8 = .{.{0} ** pty_readers.ring_size} ** 3;
    for (&rings, 0..) |*ring, i| {
        set.slots[i].ring = ring;
        set.slots[i].stream_id = @intCast(i + 1);
        set.slots[i].head.raw = p.window;
        set.slots[i].attached.raw = true;
    }
    set.focused.raw = 2;
    for ([_]u32{ 3, 1, 3, 2, 3, 1, 3, 2 }) |id| {
        agent.stageRings();
        const header = try p.Header.decode(agent.tx[0..p.header_len]);
        try std.testing.expectEqual(id, header.stream);
        try std.testing.expectEqual(p.max_data, header.len);
        agent.tx_len = 0;
    }
}

test {
    _ = p;
    _ = pty_readers;
}
