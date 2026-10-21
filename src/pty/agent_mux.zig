//! Experimental GUI mux transport. One writer, reader and watchdog per live
//! connection, never per pane. Lock order: registry -> connection -> session.
//! Pane methods notify only after releasing the session lock. No transport IO
//! runs under session/connection locks; credits bound unread output per stream.
const std = @import("std");
const io = @import("../io.zig");
const agent = @import("agent.zig");
const deploy = @import("../host/deploy.zig");
const p = @import("../agent/mux_protocol.zig");
const gpa = std.heap.smp_allocator;
pub const window = p.window;
pub const output_limit = 4 * 1024 * 1024;
pub const output_budget = 16 * 1024 * 1024;
const grace = 3 * std.time.ns_per_s;
const max_connections = 16;
var registry_mutex: io.Mutex = .{};
var registry: [max_connections]?*Connection = .{null} ** max_connections;

pub const Stream = struct {
    id: u32 = 0,
    submitted: bool = false,
    spawned: bool = false,
    close_sent: bool = false,
    failed: bool = false,
    closed_at: i128 = 0,
    input_credit: u32 = 0,
    output_credit: u32 = window,
    consumed_pending: u32 = 0,
    queued_bytes: u32 = 0,
    reservation_released: bool = false,
    focused: bool = false,
    focus_pending: bool = false,
    prefer_input: bool = false,

    pub fn consumed(self: *Stream, count: usize) void {
        if (self.reservation_released) return;
        // Terminal failure banners are outside the wire-credit ledger.
        const protocol_bytes: u32 = @intCast(@min(count, self.queued_bytes));
        self.queued_bytes -= protocol_bytes;
        self.consumed_pending += protocol_bytes;
    }
};

pub const Connection = struct {
    arena: std.heap.ArenaAllocator,
    key: []const u8,
    host: agent.Host,
    refs: std.atomic.Value(usize) = .init(1), // worker plus attached sessions
    mutex: io.Mutex = .{},
    changed: io.Condition = .{},
    // Watchdog-only wakeups: lifecycle changes, never per-output frames.
    watch: io.Condition = .{},
    sessions: [p.max_streams]?*agent.Session = .{null} ** p.max_streams,
    next_id: u32 = 1,
    cursor: usize = 0,
    control: deploy.Control = .{},
    child: ?std.process.Child.Id = null,
    hello: bool = false,
    dead: bool = false,
    stopping: bool = false,
    finished: bool = false,
    reader_done: bool = false,
    writing_since: ?i128 = null,
    started: i128 = 0,
    // Sum max(window, queued bytes + grants + pending consumption) per slot.
    // Every slot keeps a baseline window: floods cannot steal a sibling's
    // refill capacity, nor initial credits needed by newly attached panes.
    output_reserved: usize = p.max_streams * window,
    output_high_water: usize = p.max_streams * window,
    ui_notifications: u64 = 0,
    owner_turns: u64 = 0,

    pub fn unref(self: *Connection) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        self.arena.deinit();
        gpa.destroy(self);
    }
};

/// Host serialization includes connector argv/quoting, artifact paths/digests,
/// install policy, and mux tuning. Per-spawn cwd/env/command are NOT pool keys.
pub fn attach(s: *agent.Session) !void {
    const settings = s.host.multiplex.?;
    if (settings.read_workers > 4 or settings.batch_jobs < 1 or settings.batch_jobs > 2) return error.InvalidMuxSettings;
    const key = try std.json.Stringify.valueAlloc(gpa, s.host, .{});
    defer gpa.free(key);
    registry_mutex.lock();
    defer registry_mutex.unlock();
    var vacant: ?usize = null;
    for (&registry, 0..) |entry, i| {
        const c = entry orelse {
            vacant = i;
            continue;
        };
        c.mutex.lock();
        defer c.mutex.unlock();
        if (c.dead or c.stopping or c.reader_done or c.next_id == std.math.maxInt(u32) or !std.mem.eql(u8, key, c.key)) continue;
        var interested = false;
        for (c.sessions) |member| if (member) |session| {
            session.mutex.lock();
            interested = interested or (!session.closing and session.phase != .ended);
            session.mutex.unlock();
        };
        if (!interested) continue; // Last pane's cancellation is irreversible.
        for (&c.sessions) |*slot| if (slot.* == null) {
            register(c, slot, s);
            return;
        };
    }
    const index = vacant orelse return error.MuxConnectionLimit;
    const c = try gpa.create(Connection);
    c.* = .{ .arena = .init(gpa), .key = undefined, .host = undefined, .started = io.nanoTimestamp() };
    errdefer {
        c.arena.deinit();
        gpa.destroy(c);
    }
    c.key = try c.arena.allocator().dupe(u8, key);
    c.host = try s.host.dupe(c.arena.allocator());
    // Publish only after successful thread creation, under registry mutex.
    c.mutex.lock();
    const thread = std.Thread.spawn(.{}, worker, .{c}) catch |err| {
        c.mutex.unlock();
        return err;
    };
    register(c, &c.sessions[0], s);
    registry[index] = c;
    c.mutex.unlock();
    thread.detach();
}

fn register(c: *Connection, slot: *?*agent.Session, s: *agent.Session) void {
    _ = c.refs.fetchAdd(1, .monotonic);
    s.mux_connection = c;
    s.mux_state.id = c.next_id;
    c.next_id += 1;
    slot.* = s;
    c.changed.broadcast();
    c.watch.broadcast();
}

pub fn notify(s: *agent.Session) void {
    const c = s.mux_connection orelse return;
    c.mutex.lock();
    c.ui_notifications += 1;
    c.changed.broadcast();
    c.mutex.unlock();
}

/// Pane close also starts the watchdog's close grace period.
pub fn notifyClose(s: *agent.Session) void {
    const c = s.mux_connection orelse return;
    c.mutex.lock();
    c.ui_notifications += 1;
    c.changed.broadcast();
    c.watch.broadcast();
    c.mutex.unlock();
}

fn worker(c: *Connection) void {
    defer c.unref();
    defer unregister(c);
    var failure: deploy.Failure = .{};
    // Watchdog covers bootstrap, negotiation, stalled writes and close timeout.
    const watcher = std.Thread.spawn(.{}, watchdog, .{c}) catch {
        finish(c, "cannot start mux watchdog");
        return;
    };
    const message = serve(c, &failure) catch |err| switch (err) {
        error.DeployFailed => failure.text(),
        error.DeployCancelled => "host mux bootstrap cancelled",
        else => failure.print("host mux connection failed: {s}", .{@errorName(err)}),
    };
    finish(c, message);
    watcher.join();
}

fn finish(c: *Connection, message: ?[]const u8) void {
    c.mutex.lock();
    defer c.mutex.unlock();
    c.dead = true;
    for (&c.sessions) |*slot| if (slot.*) |s| {
        s.mutex.lock();
        if (c.stopping) s.fallback_allowed = false;
        s.endLocked(if (c.stopping) null else message);
        s.reader_done = true;
        s.changed.broadcast();
        s.wake.signal();
        s.mutex.unlock();
        slot.* = null;
        s.unref();
    };
    c.changed.broadcast();
    c.watch.broadcast();
}

fn unregister(c: *Connection) void {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    c.mutex.lock();
    c.finished = true;
    c.changed.broadcast();
    c.mutex.unlock();
    for (&registry) |*slot| if (slot.* == c) {
        slot.* = null;
        break;
    };
}

/// Application teardown only, after pane owners stop creating new PTYs.
/// Cancel all connections together before waiting, not one grace per pane.
pub fn shutdown() void {
    var connections: [max_connections]?*Connection = .{null} ** max_connections;
    registry_mutex.lock();
    for (registry, 0..) |entry, i| if (entry) |c| {
        _ = c.refs.fetchAdd(1, .monotonic);
        connections[i] = c;
        c.mutex.lock();
        c.stopping = true;
        c.control.cancel(io.get());
        if (c.child) |child| deploy.terminate(child);
        c.changed.broadcast();
        c.watch.broadcast();
        c.mutex.unlock();
    };
    registry_mutex.unlock();
    for (connections) |entry| if (entry) |c| {
        c.mutex.lock();
        while (!c.finished) c.changed.wait(&c.mutex);
        c.mutex.unlock();
        c.unref();
    };
}

fn watchdog(c: *Connection) void {
    c.mutex.lock();
    defer c.mutex.unlock();
    while (!c.dead) {
        const now = io.nanoTimestamp();
        var any_open = false;
        var overdue = false;
        for (c.sessions) |entry| if (entry) |s| {
            s.mutex.lock();
            if (!s.closing and s.phase != .ended) any_open = true;
            if (s.closing and s.mux_state.closed_at == 0) s.mux_state.closed_at = now;
            if (s.closing and now - s.mux_state.closed_at >= grace) overdue = true;
            s.mutex.unlock();
        };
        const timed_out = !c.hello and now - c.started >= @as(i128, c.host.agent.timeout_ms) * std.time.ns_per_ms;
        const stalled = if (c.writing_since) |since| now - since >= grace else false;
        if (!any_open or timed_out or stalled or overdue) {
            c.control.cancel(io.get());
            if (c.child) |child| {
                // Closing one stream never kills a healthy shared connector.
                if (timed_out or stalled or overdue) deploy.terminate(child);
            }
        }
        io.waitTimeout(&c.watch.inner, &c.mutex.inner, 50 * std.time.ns_per_ms) catch {};
    }
}

fn serve(c: *Connection, failure: *deploy.Failure) !?[]const u8 {
    const a = c.arena.allocator();
    var options: deploy.Options = .{};
    while (true) {
        const install = try deploy.install(io.get(), a, &c.control, c.host.connector, c.host.agent, failure, options);
        const tuning = c.host.multiplex.?;
        const argv = try c.host.connector.command(a, &.{
            "/usr/bin/env",
            try std.fmt.allocPrint(a, "HOLLOW_MUX_READ_WORKERS={d}", .{tuning.read_workers}),
            try std.fmt.allocPrint(a, "HOLLOW_MUX_READ_BATCH_JOBS={d}", .{tuning.batch_jobs}),
            install.path,
            "mux",
        });
        if (try run(c, argv)) return "host mux connection lost";
        if (!install.cached) return "host mux did not negotiate";
        if (install.cache_key) |key| deploy.forget(key);
        // No spawn can be sent before valid hello. Never replay a shell.
        options.use_cache = false;
    }
}

fn run(c: *Connection, argv: []const []const u8) !bool {
    const runtime = io.get();
    var child = try std.process.spawn(runtime, .{ .argv = argv, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore, .create_no_window = true });
    c.mutex.lock();
    c.child = child.id;
    c.started = io.nanoTimestamp();
    c.reader_done = false;
    c.mutex.unlock();
    const reader_thread = std.Thread.spawn(.{}, reader, .{ c, child.stdout.? }) catch |err| {
        c.mutex.lock();
        c.child = null;
        c.mutex.unlock();
        child.kill(runtime);
        return err;
    };
    sendLoop(c, child.stdin.?) catch {
        c.mutex.lock();
        if (c.child) |id| deploy.terminate(id);
        c.mutex.unlock();
    };
    child.stdin.?.close(runtime);
    child.stdin = null;
    c.mutex.lock();
    const deadline = io.nanoTimestamp() + grace;
    while (!c.reader_done and io.nanoTimestamp() < deadline) {
        io.waitTimeout(&c.changed.inner, &c.mutex.inner, @intCast(@max(1, deadline - io.nanoTimestamp()))) catch {};
    }
    if (!c.reader_done) deploy.terminate(child.id.?);
    c.child = null; // Never retain a reaped/recyclable process id.
    c.mutex.unlock();
    reader_thread.join();
    _ = child.wait(runtime) catch child.kill(runtime);
    c.mutex.lock();
    defer c.mutex.unlock();
    return c.hello;
}

const Frame = struct {
    kind: p.pty.Kind,
    id: u32,
    len: usize = 0,
    bytes: [p.max_spawn]u8 = undefined,
};

fn writeFrame(c: *Connection, file: std.Io.File, kind: p.pty.Kind, id: u32, bytes: []const u8) !void {
    c.mutex.lock();
    c.writing_since = io.nanoTimestamp();
    c.mutex.unlock();
    defer {
        c.mutex.lock();
        c.writing_since = null;
        c.mutex.unlock();
    }
    var frame: [p.header_len + p.max_spawn]u8 = undefined;
    frame[0..p.header_len].* = (p.Header{ .kind = kind, .stream = id, .len = @intCast(bytes.len) }).encode();
    @memcpy(frame[p.header_len..][0..bytes.len], bytes);
    try file.writeStreamingAll(io.get(), frame[0 .. p.header_len + bytes.len]);
}

fn sendLoop(c: *Connection, file: std.Io.File) !void {
    c.mutex.lock();
    while (!c.hello and !c.reader_done and !c.stopping) c.changed.wait(&c.mutex);
    const ready = c.hello and !c.reader_done and !c.stopping;
    c.mutex.unlock();
    if (!ready) return;
    try writeFrame(c, file, p.negotiate, 0, p.hello_ack);
    var frame: Frame = undefined;
    while (true) {
        c.mutex.lock();
        c.owner_turns += 1;
        const available = nextFrame(c, &frame) catch |err| {
            c.mutex.unlock();
            return err;
        };
        if (c.reader_done or c.dead or c.stopping) {
            c.mutex.unlock();
            return;
        }
        if (!available) {
            c.changed.wait(&c.mutex);
            c.mutex.unlock();
            continue;
        }
        c.mutex.unlock();
        try writeFrame(c, file, frame.kind, frame.id, frame.bytes[0..frame.len]);
    }
}

/// Called under connection lock. Fair one-frame turns; spawn IDs strictly
/// increasing even when UI threads attach panes concurrently.
fn nextFrame(c: *Connection, f: *Frame) !bool {
    var first: ?*agent.Session = null;
    var count: usize = 0;
    for (&c.sessions) |*slot| if (slot.*) |s| {
        s.mutex.lock();
        collectConsumption(c, &s.mux_state);
        if (s.mux_state.failed and !s.mux_state.close_sent) {
            s.mux_state.close_sent = true;
            f.* = .{ .kind = .close, .id = s.mux_state.id };
            s.mutex.unlock();
            return true;
        }
        // Final output still belongs to this connection's budget. Hold the
        // slot until consumed, or explicitly abort it when the pane closes.
        const retire = (s.phase == .ended and (s.mux_state.queued_bytes == 0 or s.closing)) or (s.closing and !s.mux_state.submitted);
        if (retire) {
            s.endLocked(null);
            c.output_reserved -= reservation(&s.mux_state);
            c.output_reserved += window; // Restore the empty slot's reserve.
            s.mux_state.reservation_released = true;
            s.reader_done = true;
            s.changed.broadcast();
            s.wake.signal();
            s.mutex.unlock();
            slot.* = null;
            s.unref();
            continue;
        }
        count += 1;
        if (!s.mux_state.submitted and (first == null or s.mux_state.id < first.?.mux_state.id)) first = s;
        s.mutex.unlock();
    };
    if (count == 0) {
        c.dead = true;
        return false;
    }
    if (first) |s| {
        s.mutex.lock();
        var writer: std.Io.Writer = .fixed(&f.bytes);
        std.json.Stringify.value(p.Spawn{
            .cols = s.cols,
            .rows = s.rows,
            .cwd = s.cwd,
            .env = s.env,
            .argv = s.shell_argv,
            .command = s.command,
            .close_on_exit = s.close_on_exit,
            .path_style = s.host.path_style,
        }, .{}, &writer) catch {
            s.endLocked("mux spawn exceeds 64 KiB");
            s.mutex.unlock();
            return nextFrame(c, f);
        };
        f.kind = .spawn;
        f.id = s.mux_state.id;
        f.len = writer.end;
        s.mux_state.submitted = true;
        s.hello = true; // From here, fallback/replay is unsafe, even before ack.
        s.mutex.unlock();
        return true;
    }
    for (0..p.max_streams) |_| {
        const index = c.cursor;
        c.cursor = (index + 1) % p.max_streams;
        const s = c.sessions[index] orelse continue;
        s.mutex.lock();
        defer s.mutex.unlock();
        const m = &s.mux_state;
        collectConsumption(c, m);
        if (s.phase == .ended) continue;
        const input_ready = m.input_credit > 0 and s.input_start < s.input.items.len;
        const grant = grantAvailable(c, m);
        f.id = m.id;
        f.len = 0;
        if (s.closing) {
            if (m.close_sent) continue;
            m.close_sent = true;
            m.closed_at = io.nanoTimestamp();
            f.kind = .close;
        } else if (!m.spawned) {
            continue;
        } else if (m.focus_pending) {
            m.focus_pending = false;
            f.kind = p.focus;
        } else if (s.resize_pending) {
            s.resize_pending = false;
            f.kind = .resize;
            f.len = 4;
            f.bytes[0..4].* = p.pty.encodeResize(s.cols, s.rows);
        } else if (grant > 0 and (!input_ready or !m.prefer_input) and (grant >= window / 2 or m.output_credit == 0)) {
            if (m.output_credit > window - grant) return error.InvalidCredit;
            const before = reservation(m);
            m.output_credit += grant;
            c.output_reserved += reservation(m) - before;
            c.output_high_water = @max(c.output_high_water, c.output_reserved);
            std.debug.assert(c.output_reserved <= output_budget);
            m.prefer_input = true;
            f.kind = p.credit;
            f.len = 4;
            std.mem.writeInt(u32, f.bytes[0..4], grant, .little);
        } else if (input_ready) {
            f.kind = .input;
            f.len = @min(p.max_data, @min(m.input_credit, s.input.items.len - s.input_start));
            @memcpy(f.bytes[0..f.len], s.input.items[s.input_start..][0..f.len]);
            s.input_start += f.len;
            m.input_credit -= @intCast(f.len);
            m.prefer_input = false;
            if (s.input_start == s.input.items.len) {
                s.input.clearRetainingCapacity();
                s.input_start = 0;
            }
        } else continue;
        return true;
    }
    return false;
}

fn grantAvailable(c: *const Connection, m: *const Stream) u32 {
    std.debug.assert(c.output_reserved <= output_budget);
    std.debug.assert(m.consumed_pending == 0);
    std.debug.assert(m.queued_bytes + m.output_credit <= output_limit);
    const baseline_free: usize = window - @min(window, m.queued_bytes + m.output_credit);
    return @intCast(@min(window - m.output_credit, @min(
        output_limit - m.queued_bytes - m.output_credit,
        baseline_free + output_budget - c.output_reserved,
    )));
}

fn reservation(m: *const Stream) usize {
    return @max(window, @as(usize, m.queued_bytes) + m.output_credit + m.consumed_pending);
}

fn collectConsumption(c: *Connection, m: *Stream) void {
    const before = reservation(m);
    m.consumed_pending = 0;
    c.output_reserved -= before - reservation(m);
}

fn reader(c: *Connection, file: std.Io.File) void {
    readLoop(c, file) catch |err| {
        if (err != error.EndOfStream) std.log.warn("agent mux reader: {s}", .{@errorName(err)});
    };
    c.mutex.lock();
    defer c.mutex.unlock();
    if (c.child) |child| deploy.terminate(child);
    c.reader_done = true;
    c.changed.broadcast();
}

fn readLoop(c: *Connection, file: std.Io.File) !void {
    var read_buffer: [64 * 1024]u8 = undefined;
    var buffered = file.readerStreaming(io.get(), &read_buffer);
    while (true) {
        const frame = try readReceivedFrame(&buffered.interface);
        // accept() copies retained data before the next read invalidates it.
        try accept(c, frame.header, frame.payload);
    }
}

const ReceivedFrame = struct { header: p.Header, payload: []const u8 };

/// Payload is borrowed until the reader's next fill/take. Buffer capacity must
/// accommodate control_limit. Windows reads only the first vector slice:
/// readSliceAll's direct destinations would bypass the read-ahead buffer.
fn readReceivedFrame(buffered: *std.Io.Reader) !ReceivedFrame {
    const h = try p.Header.decode(try buffered.takeArray(p.header_len));
    // Validate before requesting the payload, retaining the mux-specific caps.
    const limit: u32 = switch (h.kind) {
        .hello, .@"error" => p.control_limit,
        .output => p.max_data,
        .exit, p.spawned, p.credit => 4,
        else => return error.InvalidKind,
    };
    if (h.len > limit) return error.PayloadTooLarge;
    return .{ .header = h, .payload = try buffered.take(h.len) };
}

fn accept(c: *Connection, h: p.Header, bytes: []const u8) !void {
    c.mutex.lock();
    defer c.mutex.unlock();
    defer c.changed.broadcast();
    // Output, credit and spawn acks only concern the writer; the watchdog's
    // decisions change on hello, exit and error.
    defer if (wakesWatchdog(h.kind)) c.watch.broadcast();
    if (!c.hello) {
        if (h.kind != .hello or h.stream != 0) return error.InvalidHello;
        const Hello = struct { protocol: []const u8, version: u32, max_streams: u32, window: u32, max_data: u32, max_spawn: u32, capabilities: []const []const u8 };
        const parsed = try std.json.parseFromSlice(Hello, gpa, bytes, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const v = parsed.value;
        if (!std.mem.eql(u8, v.protocol, "hollow-mux") or v.version != 1 or v.max_streams != p.max_streams or v.window != window or v.max_data != p.max_data or v.max_spawn != p.max_spawn) return error.InvalidHello;
        for ([_][]const u8{ "multi-pty", "windows" }) |required| {
            var found = false;
            for (v.capabilities) |cap| if (std.mem.eql(u8, cap, required)) {
                found = true;
            };
            if (!found) return error.InvalidHello;
        }
        c.hello = true;
        return;
    }
    if (h.stream == 0 or h.kind == .hello) return error.InvalidStream;
    for (c.sessions) |entry| if (entry) |s| {
        if (s.mux_state.id != h.stream) continue;
        s.mutex.lock();
        defer s.mutex.unlock();
        const m = &s.mux_state;
        if (!m.submitted) return error.InvalidStream;
        // Error + exit may already share one transport read. An ended handle
        // is retired logically even before the writer drops its session ref.
        if (s.phase == .ended) return;
        switch (h.kind) {
            p.spawned => {
                if (m.spawned or try p.amount(bytes) != window) return error.InvalidCredit;
                m.spawned = true;
                m.input_credit = window;
                s.phase = .running;
                // A resize between spawn write and ack must not be lost.
                s.resize_pending = true;
            },
            p.credit => {
                if (!m.spawned) return error.InvalidCredit;
                m.input_credit = try p.addCredit(m.input_credit, bytes);
            },
            .output => {
                if (!m.spawned or bytes.len > m.output_credit) return error.OutputWindowExceeded;
                const before = reservation(m);
                m.output_credit -= @intCast(bytes.len);
                if (!s.closing) {
                    const pending = s.pendingOutputLocked();
                    if (bytes.len > output_limit - pending) return error.OutputWindowExceeded;
                    // Preserve the consumed prefix until append space is
                    // exhausted. Eager compaction moves the entire backlog
                    // while holding both connection and session locks.
                    if (s.output_start > 0 and s.output.capacity - s.output.items.len < bytes.len) {
                        std.mem.copyForwards(u8, s.output.items[0..pending], s.output.items[s.output_start..]);
                        s.reader_compacted_bytes += pending;
                        s.output.items.len = pending;
                        s.output_start = 0;
                    }
                    try s.output.appendSlice(gpa, bytes);
                    m.queued_bytes += @intCast(bytes.len);
                    s.wake.signal();
                } else c.output_reserved -= before - reservation(m);
            },
            .exit => {
                if (bytes.len != 4) return error.InvalidExit;
                s.exit_status = std.mem.readInt(u32, bytes[0..4], .little);
                s.endLocked(null);
                s.wake.signal();
            },
            .@"error" => {
                // Spawn failure may have no exit frame. Retire this handle;
                // close is unnecessary for rejected spawns and required for
                // errors after a child started, so queue an isolated close.
                s.endLocked(bytes[0..@min(bytes.len, 256)]);
                m.failed = true;
                s.wake.signal();
            },
            else => return error.InvalidKind,
        }
        return;
    };
    if (h.stream >= c.next_id) return error.UnknownStream;
    // Ignore only late frames for retired IDs, never reuse a stream ID.
}

fn wakesWatchdog(kind: p.pty.Kind) bool {
    return switch (kind) {
        .output, p.spawned, p.credit => false,
        else => true,
    };
}

/// Models Windows' first-slice-only streaming read, including short reads.
const FirstSliceReader = struct {
    source: []const u8,
    offset: usize = 0,
    max_chunk: usize = std.math.maxInt(usize),
    calls: usize = 0,
    first_request: usize = 0,
    interface: std.Io.Reader,

    fn init(source: []const u8, buffer: []u8) FirstSliceReader {
        return .{ .source = source, .interface = .{
            .vtable = &.{ .stream = stream, .readVec = readVec },
            .buffer = buffer,
            .seek = 0,
            .end = 0,
        } };
    }

    fn stream(_: *std.Io.Reader, _: *std.Io.Writer, _: std.Io.Limit) std.Io.Reader.StreamError!usize {
        return error.ReadFailed;
    }

    fn readVec(r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const self: *FirstSliceReader = @alignCast(@fieldParentPtr("interface", r));
        var vectors: [16][]u8 = undefined;
        const count, const direct_size = try r.writableVector(&vectors, data);
        std.debug.assert(count > 0);
        self.calls += 1;
        if (self.calls == 1) self.first_request = vectors[0].len;
        if (self.offset == self.source.len) return error.EndOfStream;
        const n = @min(vectors[0].len, self.source.len - self.offset, self.max_chunk);
        @memcpy(vectors[0][0..n], self.source[self.offset..][0..n]);
        self.offset += n;
        if (n > direct_size) r.end += n - direct_size;
        return @min(n, direct_size);
    }
};

test "mux frame reads fill the buffer on first-slice-only backends" {
    const first = (p.Header{ .kind = .output, .stream = 1, .len = 3 }).encode();
    const second = (p.Header{ .kind = p.credit, .stream = 2, .len = 4 }).encode();
    const wire = first ++ "a\x00b" ++ second ++ "\x01\x00\x00\x00";
    var buffer: [64 * 1024]u8 = undefined;
    var source = FirstSliceReader.init(wire, &buffer);
    const a = try readReceivedFrame(&source.interface);
    try std.testing.expectEqualSlices(u8, "a\x00b", a.payload);
    const b = try readReceivedFrame(&source.interface);
    try std.testing.expectEqual(p.credit, b.header.kind);
    try std.testing.expectEqual(@as(u32, 2), b.header.stream);
    try std.testing.expectEqualSlices(u8, "\x01\x00\x00\x00", b.payload);
    try std.testing.expectEqual(@as(usize, 1), source.calls);
    try std.testing.expectEqual(buffer.len, source.first_request);
    try std.testing.expectError(error.EndOfStream, readReceivedFrame(&source.interface));
}

test "mux buffered frames tolerate fragmented headers and payloads" {
    const header = (p.Header{ .kind = .output, .stream = 3, .len = 6 }).encode();
    const wire = header ++ "\x00\xffabcd";
    for ([_]usize{ 1, 4, 9, 13 }) |chunk| {
        var buffer: [64 * 1024]u8 = undefined;
        var source = FirstSliceReader.init(wire, &buffer);
        source.max_chunk = chunk;
        const frame = try readReceivedFrame(&source.interface);
        try std.testing.expectEqualSlices(u8, "\x00\xffabcd", frame.payload);
        try std.testing.expectEqual(@as(u32, 3), frame.header.stream);
    }
    for (0..wire.len) |end| {
        var fixed = std.Io.Reader.fixed(wire[0..end]);
        try std.testing.expectError(error.EndOfStream, readReceivedFrame(&fixed));
    }
}

test "mux buffered frame limits checked before payload reads" {
    const oversized = (p.Header{ .kind = .output, .len = p.max_data + 1 }).encode();
    var buffer: [64 * 1024]u8 = undefined;
    var source = FirstSliceReader.init(&oversized, &buffer);
    try std.testing.expectError(error.PayloadTooLarge, readReceivedFrame(&source.interface));
    try std.testing.expectEqual(@as(usize, 1), source.calls);
    const unknown = (p.Header{ .kind = @enumFromInt(250), .len = 0 }).encode();
    var fixed = std.Io.Reader.fixed(&unknown);
    try std.testing.expectError(error.InvalidKind, readReceivedFrame(&fixed));
}

test "mux buffered frame admits full control payload after buffer rebase" {
    const header = (p.Header{ .kind = .@"error", .stream = 1, .len = p.control_limit }).encode();
    const wire = try std.testing.allocator.alloc(u8, header.len + p.control_limit);
    defer std.testing.allocator.free(wire);
    @memcpy(wire[0..header.len], &header);
    @memset(wire[header.len..], 0xa5);
    var buffer: [64 * 1024]u8 = undefined;
    var source = FirstSliceReader.init(wire, &buffer);
    const frame = try readReceivedFrame(&source.interface);
    try std.testing.expectEqual(@as(usize, p.control_limit), frame.payload.len);
    try std.testing.expect(std.mem.allEqual(u8, frame.payload, 0xa5));
    try std.testing.expectEqual(@as(usize, 2), source.calls);
}

test "per-frame data and credit traffic does not wake the watchdog" {
    try std.testing.expect(!wakesWatchdog(.output));
    try std.testing.expect(!wakesWatchdog(p.spawned));
    try std.testing.expect(!wakesWatchdog(p.credit));
    try std.testing.expect(wakesWatchdog(.hello));
    try std.testing.expect(wakesWatchdog(.exit));
    try std.testing.expect(wakesWatchdog(.@"error"));
}

test "error followed by exit before owner collection does not fail siblings" {
    var pty = try agent.AgentPty.init(std.testing.allocator, .{
        .shell = "/bin/sh",
        .cols = 80,
        .rows = 24,
        .cwd = null,
        .env_block = null,
        .launch_command = null,
        .host = .{},
    }, .{});
    defer pty.closeAndJoin();
    const s = pty.session;
    s.hello = true;
    s.mux_state = .{ .id = 1, .submitted = true };
    var c: Connection = .{ .arena = .init(std.testing.allocator), .key = "test", .host = .{}, .hello = true };
    defer c.arena.deinit();
    c.sessions[0] = s;
    const message = "ExecFailed";
    try accept(&c, .{ .kind = .@"error", .stream = 1, .len = message.len }, message);
    var status: [4]u8 = undefined;
    std.mem.writeInt(u32, &status, 125, .little);
    try accept(&c, .{ .kind = .exit, .stream = 1, .len = 4 }, &status);
    try std.testing.expect(s.mux_state.failed);
    try std.testing.expect(!c.reader_done);
    try std.testing.expectEqual(@as(?u32, agent.failure_status), pty.exitStatus());
}

test "read-ahead cap preserves a baseline refill for every stream" {
    var c: Connection = .{ .arena = .init(std.testing.allocator), .key = "test", .host = .{}, .output_reserved = output_budget };
    defer c.arena.deinit();
    var focused: Stream = .{ .output_credit = 0 };
    try std.testing.expectEqual(@as(u32, window), grantAvailable(&c, &focused));
    var flooded: Stream = .{ .queued_bytes = 2 * 1024 * 1024, .output_credit = 0 };
    try std.testing.expectEqual(@as(u32, 0), grantAvailable(&c, &flooded));
    flooded.consumed(window);
    collectConsumption(&c, &flooded);
    try std.testing.expectEqual(@as(usize, output_budget - window), c.output_reserved);
    try std.testing.expectEqual(@as(u32, window), grantAvailable(&c, &flooded));
    focused = .{ .queued_bytes = window / 2, .output_credit = 0, .consumed_pending = window / 2 };
    const before = c.output_reserved;
    collectConsumption(&c, &focused);
    try std.testing.expectEqual(before, c.output_reserved);
    try std.testing.expectEqual(@as(u32, window / 2), window - @min(window, focused.queued_bytes + focused.output_credit));
    focused.queued_bytes = output_limit;
    try std.testing.expectEqual(@as(u32, 0), grantAvailable(&c, &focused));
}

test "final output retains slot and budget until consumed" {
    var pty = try agent.AgentPty.init(std.testing.allocator, .{
        .shell = "/bin/sh",
        .cols = 80,
        .rows = 24,
        .cwd = null,
        .env_block = null,
        .launch_command = null,
        .host = .{},
    }, .{});
    // The test acts as the worker holding init's second session reference.
    pty.started = true;
    defer pty.closeAndJoin();
    const s = pty.session;
    s.hello = true;
    s.mux_state = .{ .id = 1, .submitted = true, .spawned = true, .output_credit = 0, .queued_bytes = 2 * window };
    try s.output.appendNTimes(gpa, 'x', 2 * window);
    var c: Connection = .{ .arena = .init(std.testing.allocator), .key = "test", .host = .{}, .hello = true };
    defer c.arena.deinit();
    c.sessions[0] = s;
    c.output_reserved += window;
    var status: [4]u8 = undefined;
    std.mem.writeInt(u32, &status, 7, .little);
    try accept(&c, .{ .kind = .exit, .stream = 1, .len = 4 }, &status);
    var frame: Frame = undefined;
    try std.testing.expect(!try nextFrame(&c, &frame));
    try std.testing.expect(c.sessions[0] != null);
    try std.testing.expect(!c.dead);
    var bytes: [window]u8 = undefined;
    const first = try pty.read(&bytes);
    s.mux_state.consumed(first); // No real connection pointer in this fixture.
    try std.testing.expect(!try nextFrame(&c, &frame));
    try std.testing.expectEqual(@as(usize, p.max_streams * window), c.output_reserved);
    try std.testing.expect(c.sessions[0] != null);
    const second = try pty.read(&bytes);
    s.mux_state.consumed(second);
    try std.testing.expect(!try nextFrame(&c, &frame));
    try std.testing.expect(c.sessions[0] == null);
    try std.testing.expect(c.dead);
    try std.testing.expectEqual(@as(?u32, 7), pty.exitStatus());
}

test "output compacts only when append space is exhausted" {
    var pty = try agent.AgentPty.init(std.testing.allocator, .{
        .shell = "/bin/sh",
        .cols = 80,
        .rows = 24,
        .cwd = null,
        .env_block = null,
        .launch_command = null,
        .host = .{},
    }, .{});
    defer pty.closeAndJoin();
    const s = pty.session;
    s.hello = true;
    s.phase = .running;
    try s.output.ensureTotalCapacity(gpa, 128 * 1024);
    const original = s.output.capacity - 16;
    try s.output.appendNTimes(gpa, 'x', original);
    s.mux_state = .{ .id = 1, .submitted = true, .spawned = true, .queued_bytes = @intCast(original) };
    var c: Connection = .{ .arena = .init(std.testing.allocator), .key = "test", .host = .{}, .hello = true };
    defer c.arena.deinit();
    c.sessions[0] = s;
    c.output_reserved += original;
    var prefix: [4096]u8 = undefined;
    try std.testing.expectEqual(prefix.len, try pty.read(&prefix));
    s.mux_state.consumed(prefix.len); // Fixture has no real connection pointer.
    try accept(&c, .{ .kind = .output, .stream = 1, .len = 8 }, "12345678");
    try std.testing.expectEqual(@as(usize, 4096), s.output_start);
    try std.testing.expectEqual(@as(u64, 0), s.reader_compacted_bytes);
    const pending = s.pendingOutputLocked();
    const binary = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 128, 129, 250, 251, 252, 253, 254, 255 };
    try accept(&c, .{ .kind = .output, .stream = 1, .len = binary.len }, &binary);
    try std.testing.expectEqual(@as(usize, 0), s.output_start);
    try std.testing.expectEqual(@as(u64, pending), s.reader_compacted_bytes);
    try std.testing.expectEqualSlices(u8, "12345678", s.output.items[original - prefix.len ..][0..8]);
    try std.testing.expectEqualSlices(u8, &binary, s.output.items[pending..]);
    try std.testing.expectEqual(s.pendingOutputLocked(), s.mux_state.queued_bytes);
}

test "empty reads do not notify the shared owner but consumption does" {
    var pty = try agent.AgentPty.init(std.testing.allocator, .{
        .shell = "/bin/sh",
        .cols = 80,
        .rows = 24,
        .cwd = null,
        .env_block = null,
        .launch_command = null,
        .host = .{},
    }, .{});
    defer pty.closeAndJoin();
    var c: Connection = .{ .arena = .init(std.testing.allocator), .key = "test", .host = .{} };
    defer c.arena.deinit();
    const s = pty.session;
    s.mux_connection = &c;
    defer s.mux_connection = null; // Stack fixture has no owning connection ref.
    var bytes: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try pty.read(&bytes));
    try std.testing.expectEqual(@as(u64, 0), c.ui_notifications);
    try s.output.appendSlice(gpa, "q");
    s.mux_state.queued_bytes = 1;
    try std.testing.expectEqual(@as(usize, 1), try pty.read(&bytes));
    try std.testing.expectEqual(@as(u64, 1), c.ui_notifications);
    try std.testing.expectEqual(@as(u32, 1), s.mux_state.consumed_pending);
    try std.testing.expectEqual(@as(u64, 1), s.empty_reads);
}
