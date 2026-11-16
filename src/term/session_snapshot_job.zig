//! Network-backed READY decode runs off the GUI thread. After READY the worker
//! never touches the terminal again: it only collects the remaining raw bytes.
//! Once EOF is known, GUI history steps cannot wait on network I/O. This keeps
//! one terminal owner at a time without cloning terminal state or hiding the
//! screen during a blocked history read.
const std = @import("std");
const g = @import("ghostty_c");
const Decoder = @import("session_snapshot.zig").Decoder;
const frames = @import("../session/client.zig");
const Wake = @import("../pty/wake.zig").Wake;
const p = frames.p;

pub const max_snapshot_bytes = 64 * 1024 * 1024;

pub const Job = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    wake: Wake,
    format: p.SnapshotFormat,
    cols: u16,
    rows: u16,
    scrollback: usize,
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    queue: frames.Queue = .{},
    current: ?frames.Message = null,
    offset: usize = 0,
    received: usize = 0,
    eof: bool = false,
    stopping: bool = false,
    complete: bool = false,
    failure: ?anyerror = null,
    pending_terminal: ?*anyopaque = null,
    taken: bool = false,
    decoder: ?Decoder = null,
    tail: std.ArrayList(u8) = .empty,
    tail_offset: usize = 0,
    future: ?std.Io.Future(void) = null,

    pub fn create(a: std.mem.Allocator, io: std.Io, format: p.SnapshotFormat, cols: u16, rows: u16, scrollback: usize, wake: Wake) !*Job {
        if (cols == 0 or rows == 0) return error.InvalidSize;
        const self = try a.create(Job);
        errdefer a.destroy(self);
        self.* = .{ .allocator = a, .io = io, .wake = wake, .format = format, .cols = cols, .rows = rows, .scrollback = scrollback };
        self.future = try io.concurrent(run, .{self});
        return self;
    }

    /// Ownership transfers only on success. Queue pressure is retryable; a
    /// failed offer never frees the caller's message or blocks the GUI.
    pub fn offer(self: *Job, message: frames.Message) !void {
        if (message.kind != .snapshot) return error.InvalidKind;
        if (message.payload.len > p.max_data) return error.PayloadTooLarge;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.eof or self.stopping or self.failure != null) return error.SnapshotClosed;
        if (message.payload.len > max_snapshot_bytes - self.received) return error.SnapshotTooLarge;
        try self.queue.append(self.allocator, message);
        self.received += message.payload.len;
        self.changed.signal(self.io);
    }

    pub fn end(self: *Job) void {
        self.mutex.lockUncancelable(self.io);
        self.eof = true;
        self.changed.signal(self.io);
        self.mutex.unlock(self.io);
    }

    /// The GUI now owns this terminal. Destroy the job (which borrows it for
    /// history) BEFORE freeing/replacing that terminal.
    pub fn takeReady(self: *Job) ?*anyopaque {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const terminal = self.pending_terminal orelse return null;
        self.pending_terminal = null;
        self.taken = true;
        return terminal;
    }

    /// GUI thread only, serialized with terminal rendering/parsing. Null means
    /// more bytes are needed; true restored one record; false finished. The
    /// worker only buffers bytes after READY, never mutates the GUI terminal.
    pub fn nextHistory(self: *Job) !?bool {
        self.mutex.lockUncancelable(self.io);
        const complete = self.complete;
        const failure = self.failure;
        const taken = self.taken;
        self.mutex.unlock(self.io);
        if (failure) |err| return err;
        if (!taken or !complete) return null;
        const decoder = if (self.decoder) |*value| value else return false;
        const progress = try decoder.next();
        if (!progress) {
            decoder.deinit();
            self.decoder = null;
            self.tail.deinit(self.allocator);
            self.tail = .empty;
        }
        return progress;
    }

    pub fn destroy(self: *Job) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.changed.signal(self.io);
        self.mutex.unlock(self.io);
        if (self.future) |*future| future.cancel(self.io);
        if (self.decoder) |*decoder| decoder.deinit();
        if (self.pending_terminal) |terminal| g.ghostty_terminal_free(@ptrCast(terminal));
        if (self.current) |message| message.deinit();
        self.queue.deinit(self.allocator);
        self.tail.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn run(self: *Job) void {
        self.decode() catch |err| {
            self.mutex.lockUncancelable(self.io);
            self.failure = if (self.stopping) null else err;
            self.complete = true;
            self.mutex.unlock(self.io);
            self.wake.signal();
            return;
        };
        self.mutex.lockUncancelable(self.io);
        self.complete = true;
        self.mutex.unlock(self.io);
        self.wake.signal();
    }

    fn decode(self: *Job) !void {
        var buffer: [64 * 1024]u8 = undefined;
        if (self.format == .binary) {
            self.decoder = try Decoder.initReader(.{ .read = read, .userdata = self });
            const terminal = try self.decoder.?.ready(self.scrollback);
            self.publish(terminal);
            // From this point onward the decoder and terminal belong to the
            // GUI. Store raw tail bytes without calling any decoder method.
            while (true) {
                const n = try self.readNetwork(&buffer);
                if (n == 0) break;
                try self.tail.appendSlice(self.allocator, buffer[0..n]);
            }
        } else {
            var terminal: g.GhosttyTerminal = null;
            try check(g.ghostty_terminal_new(null, &terminal, self.cols, self.rows));
            errdefer g.ghostty_terminal_free(terminal);
            try check(g.ghostty_terminal_set(terminal, @intCast(g.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES), &self.scrollback));
            try check(g.ghostty_terminal_set(terminal, @intCast(g.GHOSTTY_TERMINAL_OPT_WRITE_PTY), @ptrCast(&discardReply)));
            while (true) {
                const n = try self.readNetwork(&buffer);
                if (n == 0) break;
                g.ghostty_terminal_vt_write(terminal, &buffer, n);
            }
            self.publish(@ptrCast(terminal.?));
        }
    }

    fn publish(self: *Job, terminal: *anyopaque) void {
        self.mutex.lockUncancelable(self.io);
        self.pending_terminal = terminal;
        self.mutex.unlock(self.io);
        self.wake.signal();
    }

    fn read(ctx: ?*anyopaque, out: [*c]u8, capacity: usize, out_read: [*c]usize) callconv(.c) bool {
        const self: *Job = @ptrCast(@alignCast(ctx.?));
        self.mutex.lockUncancelable(self.io);
        const complete = self.complete;
        self.mutex.unlock(self.io);
        if (complete) {
            // Only GUI history decode reaches this branch, after immutable
            // tail publication. Never wait for a connector from this callback.
            const n = @min(capacity, self.tail.items.len - self.tail_offset);
            @memcpy(out[0..n], self.tail.items[self.tail_offset..][0..n]);
            self.tail_offset += n;
            out_read.* = n;
            return true;
        }
        out_read.* = self.readNetwork(out[0..capacity]) catch return false;
        return true;
    }

    fn readNetwork(self: *Job, out: []u8) !usize {
        if (out.len == 0) return 0;
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        while (true) {
            if (self.stopping) return error.Canceled;
            if (self.current) |message| {
                const n = @min(out.len, message.payload.len - self.offset);
                @memcpy(out[0..n], message.payload[self.offset..][0..n]);
                self.offset += n;
                if (self.offset == message.payload.len) {
                    message.deinit();
                    self.current = null;
                    self.offset = 0;
                }
                if (n > 0) return n;
            }
            if (self.queue.pop()) |message| {
                self.current = message;
                continue;
            }
            if (self.eof) return 0;
            try self.changed.wait(self.io, &self.mutex);
        }
    }
};

fn check(result: anytype) !void {
    if (result != g.GHOSTTY_SUCCESS) return error.InvalidSnapshot;
}

fn discardReply(_: g.GhosttyTerminal, _: ?*anyopaque, _: [*c]const u8, _: usize) callconv(.c) void {}

const testing = struct {
    const a = std.testing.allocator;
    const ghostty = @import("ghostty.zig");
    const io = @import("../io.zig");

    fn offer(job: *Job, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const n = @min(p.max_data, bytes.len - offset);
            const message: frames.Message = .{ .kind = .snapshot, .pane = 1, .payload = try a.dupe(u8, bytes[offset..][0..n]), .allocator = a };
            var accepted = false;
            defer if (!accepted) message.deinit();
            const deadline = io.nanoTimestamp() + 5 * std.time.ns_per_s;
            while (true) {
                job.offer(message) catch |err| {
                    if (err != error.ResourceExhausted) return err;
                    if (io.nanoTimestamp() >= deadline) return error.Timeout;
                    try std.Io.sleep(io.get(), .fromMilliseconds(1), .awake);
                    continue;
                };
                accepted = true;
                break;
            }
            offset += n;
        }
    }

    fn ready(job: *Job) !*anyopaque {
        const deadline = io.nanoTimestamp() + 5 * std.time.ns_per_s;
        while (io.nanoTimestamp() < deadline) {
            if (job.takeReady()) |terminal| return terminal;
            job.mutex.lockUncancelable(job.io);
            const failure = job.failure;
            job.mutex.unlock(job.io);
            if (failure) |err| return err;
            try std.Io.sleep(io.get(), .fromMilliseconds(1), .awake);
        }
        return error.Timeout;
    }

    fn complete(job: *Job) !void {
        const deadline = io.nanoTimestamp() + 5 * std.time.ns_per_s;
        while (io.nanoTimestamp() < deadline) {
            job.mutex.lockUncancelable(job.io);
            const done = job.complete;
            job.mutex.unlock(job.io);
            if (done) return;
            try std.Io.sleep(io.get(), .fromMilliseconds(1), .awake);
        }
        return error.Timeout;
    }

    fn prefix(bytes: []const u8) !usize {
        var decoder = try Decoder.initBuffer(bytes);
        const terminal = try decoder.ready(1 << 20);
        defer g.ghostty_terminal_free(@ptrCast(terminal));
        defer decoder.deinit();
        var offset: usize = 0;
        try check(g.ghostty_snapshot_decoder_get(decoder.handle, @intCast(g.GHOSTTY_SNAPSHOT_DECODER_DATA_SOURCE_OFFSET), &offset));
        return offset;
    }

    fn snapshot() ![]u8 {
        const vt = try @import("../agent/session_vt.zig").Vt.create(a, 40, 6, 1 << 20);
        defer vt.destroy();
        for (0..5000) |_| vt.write("old history\r\n");
        vt.write("main screen\x1b[?1049halt screen\x1b]0;kept title\x07");
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(a);
        try vt.snapshot(a, &bytes);
        return bytes.toOwnedSlice(a);
    }
};

test "session snapshot job hands READY to GUI while history bytes are still absent" {
    const t = testing;
    var runtime = try t.ghostty.Runtime.init(t.a, null);
    defer runtime.deinit();
    const bytes = try t.snapshot();
    defer t.a.free(bytes);
    const prefix = try t.prefix(bytes);
    try std.testing.expect(prefix < bytes.len);
    const job = try Job.create(t.a, t.io.get(), .binary, 40, 6, 1 << 20, .{});
    try t.offer(job, bytes[0..prefix]);
    const terminal = try t.ready(job);
    defer runtime.freeTerminal(terminal);
    defer job.destroy();
    try std.testing.expect(job.takeReady() == null);
    try std.testing.expect(try job.nextHistory() == null);
    const state = try runtime.createRenderState();
    defer runtime.freeRenderState(state);
    try runtime.updateRenderState(state, terminal);
    runtime.terminalWrite(terminal, " live");
    try t.offer(job, bytes[prefix..]);
    job.end();
    try t.complete(job);
    var pages: usize = 0;
    while ((try job.nextHistory()).?) pages += 1;
    try std.testing.expect(pages > 0);
    const vt = @import("../agent/session_vt.zig");
    const alt = try vt.plain(@ptrCast(terminal), t.a);
    defer t.a.free(alt);
    try std.testing.expect(std.mem.indexOf(u8, alt, "alt screen live") != null);
    runtime.terminalWrite(terminal, "\x1b[?1049l");
    const main = try vt.plain(@ptrCast(terminal), t.a);
    defer t.a.free(main);
    try std.testing.expect(std.mem.indexOf(u8, main, "old history") != null);
}

test "session snapshot job truncated history leaves the READY terminal usable" {
    const t = testing;
    var runtime = try t.ghostty.Runtime.init(t.a, null);
    defer runtime.deinit();
    const bytes = try t.snapshot();
    defer t.a.free(bytes);
    const prefix = try t.prefix(bytes);
    const job = try Job.create(t.a, t.io.get(), .binary, 40, 6, 4096, .{});
    try t.offer(job, bytes[0..prefix]);
    const terminal = try t.ready(job);
    defer runtime.freeTerminal(terminal);
    defer job.destroy();
    job.end();
    try t.complete(job);
    try std.testing.expectError(error.InvalidSnapshot, job.nextHistory());
    runtime.terminalWrite(terminal, " still usable");
    const text = try @import("../agent/session_vt.zig").plain(@ptrCast(terminal), t.a);
    defer t.a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "still usable") != null);
}

test "session snapshot job cancels a starved reader before and after READY" {
    const t = testing;
    const waiting = try Job.create(t.a, t.io.get(), .binary, 40, 6, 4096, .{});
    try t.offer(waiting, "GH");
    waiting.destroy();
    const bytes = try t.snapshot();
    defer t.a.free(bytes);
    const job = try Job.create(t.a, t.io.get(), .binary, 40, 6, 4096, .{});
    try t.offer(job, bytes[0..try t.prefix(bytes)]);
    const terminal = try t.ready(job);
    defer g.ghostty_terminal_free(@ptrCast(terminal));
    job.destroy();
}

test "session snapshot job streams VT fallback off thread and bounds snapshot admission" {
    const t = testing;
    const job = try Job.create(t.a, t.io.get(), .vt, 40, 6, 4096, .{});
    try t.offer(job, "\x1b[31mfallback\x1b[0m\x1b[5n");
    job.end();
    const terminal = try t.ready(job);
    defer g.ghostty_terminal_free(@ptrCast(terminal));
    defer job.destroy();
    try t.complete(job);
    try std.testing.expectEqual(@as(?bool, false), try job.nextHistory());
    const text = try @import("../agent/session_vt.zig").plain(@ptrCast(terminal), t.a);
    defer t.a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "fallback") != null);
    const capped = try Job.create(t.a, t.io.get(), .binary, 40, 6, 4096, .{});
    defer capped.destroy();
    capped.mutex.lockUncancelable(capped.io);
    capped.received = max_snapshot_bytes;
    capped.mutex.unlock(capped.io);
    const message: frames.Message = .{ .kind = .snapshot, .pane = 1, .payload = try t.a.dupe(u8, "x"), .allocator = t.a };
    defer message.deinit();
    try std.testing.expectError(error.SnapshotTooLarge, capped.offer(message));
}
