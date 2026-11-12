//! Bounded Windows owner policy. Transport owns client lifetimes;
//! this module owns processes and VT state, never GUI views or pipe handles.
const std = @import("std");
const trace = @import("session_trace.zig");
const p = @import("session_protocol.zig");
const core = @import("session_core.zig");
const attachment = @import("session_attachment.zig");
const delivery = @import("session_stream.zig");
const Pane = @import("session_pane_windows.zig").Pane;
const Options = @import("session_pane_windows.zig").Options;
const LaunchCommand = @import("../pty/launch_command.zig").LaunchCommand;
const io = @import("../io.zig");
pub const Wake = @import("../pty/wake.zig").Wake;

pub const max_sessions = 16;
pub const max_session_panes = 16;
pub const max_panes = 64;
pub const scrollback_bytes = 1024 * 1024;
const input_limit = 4 * 1024 * 1024;
const turn_budget = 256 * 1024;
const exit_linger_ms = 2000;

pub const Client = struct {
    trace_identity: trace.Identity = .{},
    attach_intent: p.AttachIntent = .unknown,
    session: ?*Session = null,
    binary: bool = false,
    foreground_events: bool = false,
    dead: bool = false,
    context: *anyopaque,
    send_fn: *const fn (*anyopaque, p.Kind, u32, []const u8) anyerror!void,

    /// The callback must atomically admit a whole frame or reject it. A failed
    /// data admission leaves offsets and credit untouched.
    pub fn send(self: *Client, kind: p.Kind, stream: u32, bytes: []const u8) bool {
        if (self.dead) return false;
        self.send_fn(self.context, kind, stream, bytes) catch |err| {
            if (err != error.ResourceExhausted) self.dead = true;
            return false;
        };
        return true;
    }
};

pub const Session = struct {
    meta: core.Metadata,
    client: ?*Client = null,
    panes: [max_session_panes]*RuntimePane = undefined,
    count: usize = 0,

    fn find(self: *Session, id: u32) ?*RuntimePane {
        for (self.panes[0..self.count]) |pane| if (pane.id == id) return pane;
        return null;
    }

    fn resetDelivery(self: *Session, a: std.mem.Allocator) void {
        for (self.panes[0..self.count]) |pane| pane.resetDelivery(a);
    }
};

pub const RuntimePane = struct {
    id: u32,
    backend: *Pane,
    /// Prepared launch owns every argument/env byte and outlives request arenas.
    launch_arena: std.heap.ArenaAllocator,
    launch: Options,
    stream: delivery.Stream = .{},
    input: delivery.ByteQueue = .{},
    input_failed: bool = false,
    cols: u16,
    rows: u16,
    cwd: [:0]u8,
    close_on_exit: bool,
    status: ?i32 = null,
    exit_deadline: ?u64 = null,
    drained: bool = false,
    snapshot: std.ArrayList(u8) = .empty,
    snapshot_offset: usize = 0,
    snapshot_active: bool = false,

    fn resetDelivery(self: *RuntimePane, a: std.mem.Allocator) void {
        self.stream.detach();
        self.snapshot.deinit(a);
        self.snapshot = .empty;
        self.snapshot_offset = 0;
        self.snapshot_active = false;
    }

    fn destroy(self: *RuntimePane, a: std.mem.Allocator) void {
        self.resetDelivery(a);
        self.backend.destroy();
        self.input.deinit(a);
        self.stream.deinit(a);
        self.launch_arena.deinit();
        a.free(self.cwd);
        a.destroy(self);
    }
};

pub const Owner = struct {
    a: std.mem.Allocator,
    wake: Wake,
    sessions: [max_sessions]*Session = undefined,
    count: usize = 0,
    pane_count: usize = 0,
    turn: usize = 0,

    pub fn init(a: std.mem.Allocator, wake: Wake) Owner {
        return .{ .a = a, .wake = wake };
    }

    pub fn deinit(self: *Owner) void {
        self.killAll();
    }

    pub fn hasSessions(self: *const Owner) bool {
        return self.count != 0;
    }

    pub fn disconnect(self: *Owner, client: *Client) void {
        const s = client.session orelse return;
        if (attachment.unlink(client, s)) s.resetDelivery(self.a);
    }

    fn control(self: *Owner, client: *Client, kind: p.Kind, value: anytype) void {
        const bytes = p.stringify(self.a, value) catch {
            client.dead = true;
            return;
        };
        defer self.a.free(bytes);
        // Losing a control acknowledgement/event makes the connection uncertain.
        if (bytes.len > p.control_limit or !client.send(kind, 0, bytes)) client.dead = true;
    }

    fn event(self: *Owner, client: *Client, kind: p.EventKind, s: *Session, pane: ?u32) void {
        self.control(client, .event, p.Event{ .event = kind, .session = &s.meta.id, .pane = pane });
    }

    pub fn request(self: *Owner, client: *Client, req: *const p.Request) void {
        if (client.dead) return;
        self.handleRequest(client, req) catch |err| {
            self.control(client, .reply, p.Reply{ .id = req.id, .ok = false, .@"error" = @errorName(err) });
        };
        self.wake.signal();
    }

    fn handleRequest(self: *Owner, client: *Client, req: *const p.Request) !void {
        if (req.op == .attach or req.op == .create) {
            client.attach_intent = req.attach_intent;
            std.log.info("session.request.received connection={s} request={d} op={s} session={s} intent={s}", .{ client.trace_identity.wire().connection, req.id, @tagName(req.op), trace.token(req.session orelse ""), @tagName(req.attach_intent) });
        }
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        const temp = arena.allocator();
        switch (req.op) {
            .hold_wsl => return error.Unsupported, // Native transport owns WSL pins.
            .list => {
                const infos = try temp.alloc(p.SessionInfo, self.count);
                for (self.sessions[0..self.count], infos) |s, *entry| entry.* = try info(temp, s);
                self.control(client, .reply, p.Reply{ .id = req.id, .sessions = infos });
            },
            .create => {
                const s = try self.create(req);
                s.meta.creator = client.trace_identity;
                std.log.info("session.created session={s} creator={s} creator_build={s} connection={s}", .{ &s.meta.id, s.meta.creator.wire().instance, s.meta.creator.wire().build, s.meta.creator.wire().connection });
                self.attachCreated(client, s, req.id, temp);
            },
            .attach => {
                const s = self.find(req.session orelse return error.MissingSession) orelse return error.SessionNotFound;
                try self.attach(client, s, req.id, req.panes, temp);
            },
            .detach => {
                self.disconnect(client);
                self.control(client, .reply, p.Reply{ .id = req.id });
            },
            .kill => {
                const s = if (req.session) |id| self.find(id) orelse return error.SessionNotFound else try attached(client);
                self.end(s);
                self.control(client, .reply, p.Reply{ .id = req.id });
            },
            .layout => {
                const s = try attached(client);
                s.meta.replaceLayout(self.a, req.revision, req.layout orelse "") catch |err| {
                    if (err != error.RevisionConflict) return err;
                    self.control(client, .reply, p.Reply{ .id = req.id, .ok = false, .@"error" = "RevisionConflict", .revision = s.meta.revision });
                    return;
                };
                self.control(client, .reply, p.Reply{ .id = req.id, .revision = s.meta.revision });
            },
            .kill_server => {
                self.killAll();
                self.control(client, .reply, p.Reply{ .id = req.id });
            },
            .spawn => {
                const s = try attached(client);
                const pane = try self.spawnPane(s, req.spawn orelse .{}, true);
                // From publication onward, failed control admission is uncertain,
                // never a rejection that could cause command replay.
                self.control(client, .reply, p.Reply{ .id = req.id, .pane = pane.id, .revision = s.meta.revision });
                pane.stream.attach();
            },
            .close => {
                const s = try attached(client);
                const pane = s.find(req.pane orelse return error.MissingPane) orelse return error.PaneNotFound;
                try self.closePane(s, pane);
                self.control(client, .reply, p.Reply{ .id = req.id, .revision = s.meta.revision });
                if (s.count == 0) self.end(s);
            },
            .respawn => {
                const s = try attached(client);
                const pane = s.find(req.pane orelse return error.MissingPane) orelse return error.PaneNotFound;
                try self.respawnPane(pane);
                self.control(client, .reply, p.Reply{ .id = req.id, .pane = pane.id });
            },
        }
    }

    fn find(self: *Owner, id: []const u8) ?*Session {
        return core.findSession(self.sessions[0..self.count], id);
    }

    fn create(self: *Owner, req: *const p.Request) !*Session {
        if (self.count >= max_sessions or self.pane_count >= max_panes) return error.ResourceExhausted;
        const id = if (req.create_id) |reserved| try core.reservedId(reserved) else blk: {
            var random: [16]u8 = undefined;
            std.Io.random(io.get(), &random);
            break :blk core.randomId(random);
        };
        try core.checkCollision(self.sessions[0..self.count], &id);
        const s = try self.a.create(Session);
        errdefer self.a.destroy(s);
        s.* = .{ .meta = .{ .id = id } };
        errdefer s.meta.deinit(self.a);
        try s.meta.setInitialLayout(self.a, req.layout orelse "");
        _ = try self.spawnPane(s, req.spawn orelse .{}, false);
        self.sessions[self.count] = s;
        self.count += 1;
        return s;
    }

    fn spawnPane(self: *Owner, s: *Session, spawn: p.Spawn, membership_change: bool) !*RuntimePane {
        if (s.count >= max_session_panes or self.pane_count >= max_panes) return error.ResourceExhausted;
        const prepared = try s.meta.preparePane(membership_change);
        try validateSpawn(spawn);
        const pane = try self.a.create(RuntimePane);
        errdefer self.a.destroy(pane);
        // Copy original cwd before launch, including an omitted cwd's actual
        // inherited Windows directory. VT pwd may later supersede it.
        const cwd = if (spawn.cwd) |value| try self.a.dupeSentinel(u8, value, 0) else try std.process.currentPathAlloc(io.get(), self.a);
        errdefer self.a.free(cwd);
        var arena = std.heap.ArenaAllocator.init(self.a);
        errdefer arena.deinit();
        var options = try prepareLaunch(arena.allocator(), spawn);
        options.cwd = cwd;
        options.wake = self.wake;
        options.scrollback_bytes = scrollback_bytes;
        const backend = try Pane.create(self.a, options);
        // Nothing fallible follows execution/publication.
        prepared.commit(&s.meta);
        pane.* = .{ .id = prepared.id, .backend = backend, .launch_arena = arena, .launch = options, .cols = spawn.cols, .rows = spawn.rows, .cwd = cwd, .close_on_exit = closeOnExit(spawn) };
        s.panes[s.count] = pane;
        s.count += 1;
        self.pane_count += 1;
        return pane;
    }

    fn closePane(self: *Owner, s: *Session, pane: *RuntimePane) !void {
        const revision = try s.meta.prepareMembershipChange();
        for (s.panes[0..s.count], 0..) |entry, index| {
            if (entry != pane) continue;
            s.count -= 1;
            std.mem.copyForwards(*RuntimePane, s.panes[index..s.count], s.panes[index + 1 .. s.count + 1]);
            self.pane_count -= 1;
            pane.destroy(self.a);
            s.meta.revision = revision;
            return;
        }
        unreachable;
    }

    fn respawnPane(self: *Owner, pane: *RuntimePane) !void {
        if (pane.status == null) return error.PaneAlive;
        var options = pane.launch;
        options.cols = pane.cols;
        options.rows = pane.rows;
        // The replacement is fully allocated and running before changing any
        // old state. Failed preparation/spawn preserves VT, status, and jobs.
        const replacement = try Pane.create(self.a, options);
        const old = pane.backend;
        const fresh_vt = replacement.vt;
        replacement.vt = old.vt;
        old.vt = fresh_vt;
        replacement.vt.shell_command = .{};
        var replies = replacement.vt.takeReplies();
        replies.deinit(self.a);
        pane.backend = replacement;
        old.destroy();
        resetRespawnDelivery(pane);
    }

    fn attachCreated(self: *Owner, client: *Client, s: *Session, id: u64, a: std.mem.Allocator) void {
        // Execution/publication already happened. A definitive rejection would
        // invite another create; disconnect instead, preserving reserved-ID
        // recovery and the client's existing uncertain-result handling.
        self.attach(client, s, id, &.{}, a) catch {
            client.dead = true;
        };
    }

    fn attach(self: *Owner, client: *Client, s: *Session, id: u64, sizes: []const p.PaneSize, a: std.mem.Allocator) !void {
        if (sizes.len > s.count) return error.InvalidPaneSizes;
        for (sizes, 0..) |size, index| {
            _ = s.find(size.pane) orelse return error.PaneNotFound;
            try validSize(size.cols, size.rows);
            for (sizes[0..index]) |previous| if (previous.pane == size.pane) return error.InvalidPaneSizes;
        }
        // Materialize the entire reply before takeover. OOM must not evict an
        // existing controller or silently destroy a recoverable created session.
        var session_info = try info(a, s);
        session_info.attached = true;
        for (sizes) |size| {
            const panes = @constCast(session_info.panes);
            for (panes) |*pane| if (pane.id == size.pane) {
                pane.cols = size.cols;
                pane.rows = size.rows;
            };
        }
        const reply = try p.stringify(a, p.Reply{ .id = id, .session = session_info });
        if (reply.len > p.control_limit) return error.ResourceExhausted;
        for (sizes) |size| {
            const pane = s.find(size.pane).?;
            // Validation and reply allocation precede all resize/takeover work.
            // A VT allocation failure can leave earlier sizes applied, but never
            // changes controller bindings or reports a successful takeover.
            try pane.backend.resize(size.cols, size.rows);
            pane.cols = size.cols;
            pane.rows = size.rows;
        }
        self.disconnect(client);
        s.resetDelivery(self.a);
        if (attachment.link(client, s)) |old| {
            const owner_identity = trace.Identity.local("owner");
            const value = trace.takeover(&s.meta.creator, &old.trace_identity, &client.trace_identity, &owner_identity, client.attach_intent, id);
            trace.logTakeover(&s.meta.id, value);
            self.control(old, .event, p.Event{ .event = .taken, .session = &s.meta.id, .takeover = value });
        }
        for (s.panes[0..s.count]) |pane| pane.stream.attach();
        if (!client.send(.reply, 0, reply)) client.dead = true;
    }

    pub fn frame(self: *Owner, client: *Client, kind: p.Kind, stream: u32, bytes: []const u8) !void {
        if (client.dead) return error.Closed;
        // Validate malformed frames even if their pane was concurrently closed.
        switch (kind) {
            .input => if (bytes.len > p.max_data) return error.PayloadTooLarge,
            .resize => {
                const size = try p.decodeResize(bytes);
                try validSize(size.cols, size.rows);
            },
            .credit => _ = try p.decodeCredit(bytes),
            else => return error.InvalidKind,
        }
        const session = attached(client) catch return;
        const s = session.find(stream) orelse return;
        switch (kind) {
            .input => {
                if (bytes.len > p.max_data) return error.PayloadTooLarge;
                // Late keystrokes for an exited/failed pane must not disconnect
                // the controller of still-running siblings.
                if (s.status != null or s.input_failed) return;
                try s.input.append(self.a, bytes, input_limit);
            },
            .resize => {
                const size = try p.decodeResize(bytes);
                try validSize(size.cols, size.rows);
                try s.backend.resize(size.cols, size.rows);
                s.cols = size.cols;
                s.rows = size.rows;
            },
            .credit => s.stream.grant(try p.decodeCredit(bytes)),
            else => return error.InvalidKind,
        }
        self.wake.signal();
    }

    pub fn killAll(self: *Owner) void {
        while (self.count != 0) self.end(self.sessions[self.count - 1]);
    }

    fn end(self: *Owner, s: *Session) void {
        s.meta.ended = true;
        if (s.client) |client| {
            self.event(client, .session_end, s, null);
            self.disconnect(client);
        }
        for (self.sessions[0..self.count], 0..) |entry, index| {
            if (entry != s) continue;
            self.count -= 1;
            std.mem.copyForwards(*Session, self.sessions[index..self.count], self.sessions[index + 1 .. self.count + 1]);
            break;
        }
        for (s.panes[0..s.count]) |pane| pane.destroy(self.a);
        self.pane_count -= s.count;
        s.meta.deinit(self.a);
        self.a.destroy(s);
    }

    /// `now` and deadlines are monotonic milliseconds. Only exhausted work
    /// budgets request another immediate turn; writers/credit/pipe pressure wait
    /// for the shared wake event or another transport frame.
    pub fn tick(self: *Owner, now: u64) bool {
        var more = false;
        const Entry = struct { session: *Session, pane: *RuntimePane };
        var entries: [max_panes]Entry = undefined;
        var count: usize = 0;
        for (self.sessions[0..self.count]) |s| {
            if (s.client) |client| if (client.dead) self.disconnect(client);
            for (s.panes[0..s.count]) |pane| {
                entries[count] = .{ .session = s, .pane = pane };
                count += 1;
            }
        }
        if (count == 0) return false;
        const start = self.turn % count;
        self.turn = (start + 1) % count;
        for (0..count) |offset| {
            const entry = entries[(start + offset) % count];
            if (entry.session.meta.ended) continue;
            const immediate = self.tickPane(entry.session, entry.pane, now) catch {
                // Fatal VT/query/read failures cannot yield a trustworthy view.
                // Defer destruction until visitation ends: later entries may
                // refer to siblings in this same session.
                entry.session.meta.ended = true;
                continue;
            };
            more = more or immediate;
        }
        var index: usize = 0;
        while (index < self.count) {
            const s = self.sessions[index];
            if (s.meta.ended) self.end(s) else index += 1;
        }
        return more;
    }

    fn tickPane(self: *Owner, session: *Session, s: *RuntimePane, now: u64) !bool {
        var more = false;
        // Flush query replies and latest resize even when no application input
        // is queued. Exhaustion here is waitable, except a fatal VT reply sink.
        s.backend.flush() catch |err| switch (err) {
            error.ResourceExhausted => if (s.backend.reply_failed) return err,
            error.WriteFailed => {
                failInput(s);
            },
            else => return err,
        };
        var input_budget: usize = turn_budget;
        while (!s.input_failed and s.status == null and s.input.len() > 0 and input_budget > 0) {
            const n = @min(@min(s.input.len(), p.max_data), input_budget);
            s.backend.writeAll(s.input.slice()[0..n]) catch |err| switch (err) {
                error.ResourceExhausted => break,
                else => {
                    failInput(s);
                    break;
                },
            };
            s.input.consume(n);
            input_budget -= n;
        }
        if (input_budget == 0 and s.input.len() > 0) more = true;

        var read_budget: usize = turn_budget;
        var buffer: [p.max_data]u8 = undefined;
        // Linger expiry permits exit delivery, not abandoning VT authority.
        // Descendant output after root exit still belongs in future snapshots.
        while (read_budget > 0) {
            const n = s.backend.read(buffer[0..@min(buffer.len, read_budget)]) catch |err| switch (err) {
                error.WriteFailed => {
                    failInput(s);
                    continue;
                },
                else => return err,
            };
            if (n == 0) break;
            // A dead input channel does not imply process exit. Drop queries
            // that can no longer be answered, but continue consuming output.
            if (s.input_failed) failInput(s);
            read_budget -= n;
            if (session.client != null) s.stream.appendOutput(self.a, buffer[0..n]);
        }
        if (read_budget == 0 and s.backend.pty.hasPendingOutput()) more = true;
        if (s.status == null) if (s.backend.exitStatus()) |status| {
            s.status = wireExit(status);
            s.exit_deadline = now +| exit_linger_ms;
            s.input.clear();
        };
        if (s.status != null and (s.backend.outputEnded() or now >= s.exit_deadline.?)) s.drained = true;

        const client = session.client orelse return more;
        if (client.dead) return more;
        if (!s.snapshot_active and s.stream.requestResync()) self.event(client, .resync, session, s.id);
        if (client.dead) return more;
        if (!s.snapshot_active and s.stream.startSnapshot()) {
            s.snapshot_active = true;
            s.snapshot_offset = 0;
            const encoded = if (client.binary) s.backend.snapshot(self.a, &s.snapshot) else s.backend.formatVt(self.a, &s.snapshot);
            encoded catch {
                client.dead = true;
                return more;
            };
            // Sink also bounds during encoding, not merely after allocation.
            if (s.snapshot.items.len > @import("session_vt.zig").snapshot_limit) {
                client.dead = true;
                return more;
            }
            if (client.foreground_events) self.foreground(s) catch {
                client.dead = true;
                return more;
            };
        }

        var send_budget: usize = turn_budget;
        while (s.snapshot_active and s.snapshot_offset < s.snapshot.items.len and send_budget > 0) {
            const n = @min(@min(p.max_data, s.snapshot.items.len - s.snapshot_offset), send_budget);
            if (!client.send(.snapshot, s.id, s.snapshot.items[s.snapshot_offset..][0..n])) return more;
            s.snapshot_offset += n;
            send_budget -= n;
        }
        if (s.snapshot_active) {
            if (s.snapshot_offset != s.snapshot.items.len) return true;
            if (!client.send(.snapshot_end, s.id, "")) return more;
            s.snapshot_active = false;
            s.snapshot.deinit(self.a);
            s.snapshot = .empty;
            s.snapshot_offset = 0;
        }
        while (send_budget > 0) {
            const bytes = s.stream.nextOutput();
            if (bytes.len == 0) break;
            const n = @min(bytes.len, send_budget);
            if (!client.send(.output, s.id, bytes[0..n])) return more;
            s.stream.consumeOutput(n);
            send_budget -= n;
        }
        if (send_budget == 0 and s.stream.nextOutput().len > 0) more = true;
        // A stale backlog produced while delivering a snapshot can now resync.
        if (s.stream.stale and s.stream.credit == p.window) more = true;
        if (s.stream.snapshot_pending) more = true;
        if (s.status) |status| if (s.stream.exitReady(s.drained)) {
            if (client.send(.exit, s.id, &p.encodeExit(status))) s.stream.exit_sent = true;
        };
        return more;
    }

    fn foreground(self: *Owner, s: *RuntimePane) !void {
        const state = try p.stringify(self.a, .{
            .kind = "event",
            .name = "session_foreground_process",
            .payload = .{ .command = if (s.status == null) s.backend.vt.shell_command.value() else "" },
        });
        defer self.a.free(state);
        const framed = try std.fmt.allocPrint(self.a, "\x1b]1337;Hollow;{s}\x1b\\", .{state});
        defer self.a.free(framed);
        // Insert before any output read after snapshot capture, not at the end
        // of a possibly multi-turn snapshot transfer.
        try s.stream.unsent.append(self.a, framed, p.resync_limit);
    }

    pub fn deadline(self: *const Owner) ?u64 {
        var result: ?u64 = null;
        for (self.sessions[0..self.count]) |s| {
            for (s.panes[0..s.count]) |pane| {
                if (pane.drained) continue;
                if (pane.exit_deadline) |time| result = if (result) |previous| @min(previous, time) else time;
            }
        }
        return result;
    }
};

fn attached(client: *Client) !*Session {
    const s = client.session orelse return error.NotAttached;
    if (s.client != client) return error.NotAttached;
    return s;
}

fn failInput(s: *RuntimePane) void {
    s.input_failed = true;
    s.input.clear();
    s.backend.pending_replies.clearRetainingCapacity();
    s.backend.reply_offset = 0;
    s.backend.pending_resize = null;
}

fn resetRespawnDelivery(pane: *RuntimePane) void {
    const refresh = pane.snapshot_active or pane.stream.unsent.len() > 0;
    pane.input.clear();
    pane.input_failed = false;
    pane.status = null;
    pane.exit_deadline = null;
    pane.drained = false;
    pane.stream.respawn();
    // Never splice an in-flight snapshot or silently lose old unsent output.
    // Finish the old capture, wait for prior credit, then announce resync before
    // encoding another snapshot. An already-pending fresh capture suffices.
    if (refresh and !pane.stream.snapshot_pending) pane.stream.stale = true;
}

fn info(a: std.mem.Allocator, s: *Session) !p.SessionInfo {
    const panes = try a.alloc(p.PaneInfo, s.count);
    for (s.panes[0..s.count], panes) |pane, *entry| {
        const pwd = try pane.backend.vt.pwd(a);
        entry.* = .{
            .id = pane.id,
            .cols = pane.cols,
            .rows = pane.rows,
            .title = try pane.backend.vt.title(a),
            .cwd = if (windowsPath(pwd)) pwd else pane.cwd,
            .foreground_process = if (pane.status == null) pane.backend.vt.shell_command.value() else "",
            .exit = pane.status,
            .close_on_exit = pane.close_on_exit,
        };
    }
    return .{ .id = &s.meta.id, .attached = s.client != null, .revision = s.meta.revision, .layout = s.meta.layout, .panes = panes };
}

fn windowsPath(path: []const u8) bool {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
    return (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '\\' or path[2] == '/')) or std.mem.startsWith(u8, path, "\\\\");
}

/// The existing wire reserves negatives for Unix signals. Windows high-bit
/// exception/exit codes therefore saturate, never masquerade as a signal.
fn wireExit(status: u32) i32 {
    return @intCast(@min(status, std.math.maxInt(i32)));
}

fn validSize(cols: u16, rows: u16) !void {
    if (cols == 0 or rows == 0 or cols > std.math.maxInt(i16) or rows > std.math.maxInt(i16)) return error.InvalidSize;
}

fn boundedString(bytes: []const u8, total: *usize) !void {
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.InvalidCharacter;
    if (bytes.len >= p.control_limit - total.*) return error.ResourceExhausted;
    total.* += bytes.len + 1;
}

fn validateSpawn(spawn: p.Spawn) !void {
    try validSize(spawn.cols, spawn.rows);
    var total: usize = 0;
    if (spawn.cwd) |cwd| try boundedString(cwd, &total);
    if (spawn.command) |command| try boundedString(command, &total);
    for (spawn.argv) |arg| try boundedString(arg, &total);
    if (spawn.argv.len > 0 and spawn.argv[0].len == 0) return error.InvalidArgv;
    for (spawn.env) |env| {
        if (env.key.len == 0 or std.mem.indexOfScalar(u8, env.key, '=') != null) return error.InvalidEnv;
        try boundedString(env.key, &total);
        try boundedString(env.value, &total);
    }
}

/// All returned storage belongs to the temporary arena. Native argv is literal:
/// never translate Unix shell arguments into a Windows command line.
fn prepareLaunch(a: std.mem.Allocator, spawn: p.Spawn) !Options {
    var env: std.ArrayList(u8) = .empty;
    for (spawn.env) |entry| {
        try env.appendSlice(a, entry.key);
        try env.append(a, '=');
        try env.appendSlice(a, entry.value);
        try env.append(a, 0);
    }
    try env.append(a, 0);
    const default_shell = "powershell.exe";
    var args: std.ArrayList([]const u8) = .empty;
    if (spawn.command) |command| {
        const shell_args: []const []const u8 = if (spawn.argv.len > 0) spawn.argv else &.{default_shell};
        for (shell_args) |arg| try args.append(a, try a.dupe(u8, arg));
        const name = std.fs.path.basenameWindows(shell_args[0]);
        if (isPowershell(name)) {
            if (!spawn.user_shell) try args.appendSlice(a, &.{ "-NoProfile", "-NonInteractive" });
            try args.append(a, "-Command");
        } else if (std.ascii.eqlIgnoreCase(name, "cmd.exe") or std.ascii.eqlIgnoreCase(name, "cmd")) {
            if (spawn.user_shell) return error.UnsupportedUserShell;
            try args.appendSlice(a, &.{ "/D", "/C" });
        } else return error.UnsupportedBackgroundShell;
        try args.append(a, try a.dupe(u8, command));
    } else if (spawn.user_shell and spawn.argv.len > 0) {
        const command = try (LaunchCommand{ .argv = spawn.argv }).userShellCommand(a, true);
        try args.appendSlice(a, &.{ default_shell, "-Command", command });
    } else if (spawn.argv.len > 0) {
        if (spawn.shell_integration and !spawn.one_shot and interactiveNativeShell(spawn.argv) and
            isPowershell(std.fs.path.basenameWindows(spawn.argv[0])))
        {
            const integrated = try @import("../pty/pty_windows.zig").sessionInteractiveArgv(a, spawn.argv);
            try args.appendSlice(a, integrated);
        } else {
            for (spawn.argv) |arg| try args.append(a, try a.dupe(u8, arg));
        }
    } else {
        if (spawn.one_shot) return error.InvalidCommand;
        if (!spawn.shell_integration) return .{
            .shell = default_shell,
            .cols = spawn.cols,
            .rows = spawn.rows,
            .env_block = env.items,
            .launch_command = .{ .argv = &.{ default_shell, "-NoLogo" } },
        };
        // No launch wrapper for an ordinary interactive default shell.
        return .{ .shell = default_shell, .cols = spawn.cols, .rows = spawn.rows, .env_block = env.items };
    }
    return .{
        .shell = default_shell,
        .cols = spawn.cols,
        .rows = spawn.rows,
        .env_block = env.items,
        .launch_command = .{ .argv = args.items, .one_shot = spawn.one_shot or spawn.command != null, .close_on_exit = spawn.close_on_exit },
    };
}

fn isPowershell(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "powershell.exe") or std.ascii.eqlIgnoreCase(name, "powershell") or std.ascii.eqlIgnoreCase(name, "pwsh.exe") or std.ascii.eqlIgnoreCase(name, "pwsh");
}

fn closeOnExit(spawn: p.Spawn) bool {
    if (spawn.close_on_exit) return true;
    if (spawn.command != null or spawn.one_shot or spawn.user_shell) return false;
    return interactiveNativeShell(spawn.argv);
}

fn interactiveNativeShell(args: []const []const u8) bool {
    if (args.len == 0) return true;
    const name = std.fs.path.basenameWindows(args[0]);
    const cmd = std.ascii.eqlIgnoreCase(name, "cmd.exe") or std.ascii.eqlIgnoreCase(name, "cmd");
    if (!cmd and !isPowershell(name)) return false;
    for (args[1..]) |arg| {
        const interactive_flag = if (cmd)
            std.ascii.eqlIgnoreCase(arg, "/D") or std.ascii.eqlIgnoreCase(arg, "/Q")
        else
            std.ascii.eqlIgnoreCase(arg, "-NoLogo") or std.ascii.eqlIgnoreCase(arg, "-NoProfile") or std.ascii.eqlIgnoreCase(arg, "-NoExit");
        if (!interactive_flag) return false;
    }
    return true;
}

test "Windows exit codes never encode Unix signals" {
    try std.testing.expectEqual(@as(i32, 7), wireExit(7));
    try std.testing.expectEqual(std.math.maxInt(i32), wireExit(0xc0000005));
}

test "respawn resyncs discarded backlog and finishes active snapshot before refreshing" {
    const a = std.testing.allocator;
    var pane: RuntimePane = .{
        .id = 1,
        .backend = undefined,
        .launch_arena = std.heap.ArenaAllocator.init(a),
        .launch = .{ .shell = "powershell.exe" },
        .cwd = undefined,
        .cols = 80,
        .rows = 24,
        .close_on_exit = false,
    };
    defer pane.launch_arena.deinit();
    defer pane.stream.deinit(a);
    pane.stream.credit = p.window - 1;
    pane.stream.appendOutput(a, "not delivered before respawn");
    resetRespawnDelivery(&pane);
    try std.testing.expect(pane.stream.stale);
    try std.testing.expectEqual(@as(usize, 0), pane.stream.unsent.len());
    try std.testing.expect(!pane.stream.requestResync());
    pane.stream.grant(1);
    try std.testing.expect(pane.stream.requestResync());
    try std.testing.expect(pane.stream.startSnapshot());

    pane.stream.attach();
    _ = pane.stream.startSnapshot();
    pane.snapshot_active = true;
    pane.snapshot_offset = 123;
    resetRespawnDelivery(&pane);
    try std.testing.expect(pane.snapshot_active);
    try std.testing.expectEqual(@as(usize, 123), pane.snapshot_offset);
    try std.testing.expect(!pane.stream.snapshot_pending);
    try std.testing.expect(pane.stream.stale);
    // tickPane gates requestResync on !snapshot_active. After the old end frame,
    // this transition emits resync before the next startSnapshot call.
    pane.snapshot_active = false;
    try std.testing.expect(pane.stream.requestResync());
    try std.testing.expect(pane.stream.startSnapshot());
}

test "session capacity rejects before allocation or child creation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var owner = Owner.init(failing.allocator(), .{});
    owner.count = max_sessions;
    try std.testing.expectError(error.ResourceExhausted, owner.create(&.{ .id = 1, .op = .create }));
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(max_sessions, owner.count);
}

test "global and per-session pane capacity reject before allocation or mutation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var owner = Owner.init(failing.allocator(), .{});
    var s: Session = .{ .meta = .{ .id = @splat('a'), .next_pane = 9, .revision = 3 } };
    owner.pane_count = max_panes;
    try std.testing.expectError(error.ResourceExhausted, owner.create(&.{ .id = 1, .op = .create }));
    try std.testing.expectError(error.ResourceExhausted, owner.spawnPane(&s, .{}, true));
    owner.pane_count = 1;
    s.count = max_session_panes;
    try std.testing.expectError(error.ResourceExhausted, owner.spawnPane(&s, .{}, true));
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(@as(u64, 9), s.meta.next_pane);
    try std.testing.expectEqual(@as(u64, 3), s.meta.revision);
    try std.testing.expectEqual(@as(usize, max_session_panes), s.count);
}

test "numeric exhaustion rejects spawn and close before backend or allocation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var owner = Owner.init(failing.allocator(), .{});
    var s: Session = .{ .meta = .{ .id = @splat('a'), .next_pane = @as(u64, std.math.maxInt(u32)) + 1 } };
    var pane: RuntimePane = undefined;
    s.panes[0] = &pane;
    s.count = 1;
    owner.pane_count = 1;
    try std.testing.expectError(error.ResourceExhausted, owner.spawnPane(&s, .{}, true));
    s.meta.next_pane = 2;
    s.meta.revision = std.math.maxInt(u64);
    try std.testing.expectError(error.ResourceExhausted, owner.spawnPane(&s, .{}, true));
    try std.testing.expectError(error.ResourceExhausted, owner.closePane(&s, &pane));
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(@as(u64, 2), s.meta.next_pane);
    try std.testing.expectEqual(std.math.maxInt(u64), s.meta.revision);
    try std.testing.expectEqual(@as(usize, 1), s.count);
    try std.testing.expectEqual(@as(usize, 1), owner.pane_count);
    try std.testing.expect(s.panes[0] == &pane);
}

test "failed respawn preserves state and owned original launch" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var original = [_]u8{ 'e', 'x', 'i', 't', ' ', '7' };
    const launch = try prepareLaunch(arena.allocator(), .{ .command = &original });
    @memset(&original, 'x');
    var pane: RuntimePane = .{
        .id = 7,
        .backend = undefined,
        .launch_arena = arena,
        .launch = launch,
        .cols = 90,
        .rows = 30,
        .cwd = undefined,
        .close_on_exit = false,
        .status = 7,
        .exit_deadline = 500,
        .drained = true,
        .input_failed = true,
        .snapshot_active = true,
        .snapshot_offset = 3,
        .stream = .{ .credit = 15, .exit_sent = true },
    };
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    var owner = Owner.init(failing.allocator(), .{});
    try std.testing.expectError(error.OutOfMemory, owner.respawnPane(&pane));
    try std.testing.expectEqualStrings("exit 7", pane.launch.launch_command.?.argv.?[4]);
    try std.testing.expectEqual(@as(?i32, 7), pane.status);
    try std.testing.expectEqual(@as(?u64, 500), pane.exit_deadline);
    try std.testing.expectEqual(@as(u32, 7), pane.id);
    try std.testing.expectEqual(@as(u32, 15), pane.stream.credit);
    try std.testing.expectEqual(@as(usize, 3), pane.snapshot_offset);
    try std.testing.expect(pane.drained and pane.input_failed and pane.snapshot_active and pane.stream.exit_sent);
    pane.status = null;
    try std.testing.expectError(error.PaneAlive, owner.respawnPane(&pane));
}

test "stale frames cannot reach siblings or taken-over panes" {
    const Sink = struct {
        fn send(_: *anyopaque, _: p.Kind, _: u32, _: []const u8) !void {}
    };
    var context: u8 = 0;
    var owner = Owner.init(std.testing.allocator, .{});
    var s: Session = .{ .meta = .{ .id = @splat('a') } };
    var pane: RuntimePane = undefined;
    pane.id = 2;
    pane.stream = .{ .credit = 0 };
    pane.input = .{};
    pane.status = null;
    pane.input_failed = false;
    s.panes[0] = &pane;
    s.count = 1;
    var client: Client = .{ .context = &context, .send_fn = Sink.send, .session = &s };
    s.client = &client;
    try owner.frame(&client, .input, 1, "stale");
    try owner.frame(&client, .credit, 1, &.{ 12, 0, 0, 0 });
    try std.testing.expectEqual(@as(usize, 0), pane.input.len());
    try std.testing.expectEqual(@as(u32, 0), pane.stream.credit);
    client.session = null;
    try owner.frame(&client, .input, 2, "taken");
    try owner.frame(&client, .credit, 2, &.{ 12, 0, 0, 0 });
    try std.testing.expectEqual(@as(usize, 0), pane.input.len());
    try std.testing.expectEqual(@as(u32, 0), pane.stream.credit);
    try std.testing.expectError(error.InvalidResize, owner.frame(&client, .resize, 1, &p.encodeResize(0, 1)));
}

test "attach validates every size and duplicate before touching VT or bindings" {
    const Sink = struct {
        fn send(_: *anyopaque, _: p.Kind, _: u32, _: []const u8) !void {}
    };
    var context: u8 = 0;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var owner = Owner.init(failing.allocator(), .{});
    var s: Session = .{ .meta = .{ .id = @splat('a') } };
    var first: RuntimePane = undefined;
    var second: RuntimePane = undefined;
    first.id = 2;
    second.id = 3;
    s.panes[0] = &first;
    s.panes[1] = &second;
    s.count = 2;
    var old: Client = .{ .context = &context, .send_fn = Sink.send, .session = &s };
    var next: Client = .{ .context = &context, .send_fn = Sink.send };
    s.client = &old;
    const good: p.PaneSize = .{ .pane = 2, .cols = 90, .rows = 30 };
    try std.testing.expectError(error.InvalidSize, owner.attach(&next, &s, 1, &.{ good, .{ .pane = 3, .cols = 0, .rows = 30 } }, owner.a));
    try std.testing.expectError(error.PaneNotFound, owner.attach(&next, &s, 1, &.{ good, .{ .pane = 1, .cols = 90, .rows = 30 } }, owner.a));
    try std.testing.expectError(error.InvalidPaneSizes, owner.attach(&next, &s, 1, &.{ good, good }, owner.a));
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expect(s.client == &old and old.session == &s and next.session == null);
}

test "native interactive shell exit policy does not classify commands as shells" {
    try std.testing.expect(closeOnExit(.{ .argv = &.{ "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\PowerShell.EXE", "-NoProfile" } }));
    try std.testing.expect(closeOnExit(.{ .argv = &.{"pwsh.exe"} }));
    try std.testing.expect(closeOnExit(.{ .argv = &.{ "CMD.EXE", "/D", "/Q" } }));
    try std.testing.expect(!closeOnExit(.{ .argv = &.{ "powershell.exe", "-Command", "exit 0" } }));
    try std.testing.expect(!closeOnExit(.{ .argv = &.{ "cmd.exe", "/C", "exit 0" } }));
    try std.testing.expect(!closeOnExit(.{ .argv = &.{ "pwsh.exe", "script.ps1" } }));
}

test "published create attach OOM is uncertain and retains its session identity" {
    const Reject = struct {
        fn send(context: *anyopaque, _: p.Kind, _: u32, _: []const u8) !void {
            const calls: *usize = @ptrCast(@alignCast(context));
            calls.* += 1;
        }
    };
    var owner = Owner.init(std.testing.allocator, .{});
    var s: Session = .{ .meta = .{ .id = @splat('a') } };
    var pane: RuntimePane = undefined;
    s.panes[0] = &pane;
    s.count = 1;
    owner.sessions[0] = &s;
    owner.count = 1;
    var calls: usize = 0;
    var client: Client = .{ .context = &calls, .send_fn = Reject.send };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    owner.attachCreated(&client, &s, 1, failing.allocator());
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(client.dead);
    try std.testing.expectEqual(@as(usize, 0), calls);
    try std.testing.expect(owner.find(&s.meta.id) == &s);
    try std.testing.expectEqual(@as(usize, 1), owner.count);
}

test "read-side query write failure preserves live process and VT output" {
    var owner = Owner.init(std.testing.allocator, .{});
    defer owner.deinit();
    const req: p.Request = .{ .id = 1, .op = .create, .spawn = .{
        .argv = &.{ "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", "$null=[Console]::ReadLine()" },
    } };
    const session = try owner.create(&req);
    const s = session.panes[0];
    // No queued input exists. A closed writer can still accompany a live child
    // and buffered output, including a query discovered inside the read loop.
    s.backend.pty.writer_state.mutex.lock();
    s.backend.pty.writer_state.closing = true;
    s.backend.pty.writer_state.mutex.unlock();
    s.backend.pty.reader_state.mutex.lock();
    s.backend.pty.reader_state.buf.appendSlice(std.heap.page_allocator, "\x1b[6nREAD_AFTER_INPUT_FAILURE") catch |err| {
        s.backend.pty.reader_state.mutex.unlock();
        return err;
    };
    s.backend.pty.reader_state.mutex.unlock();
    _ = owner.tick(0);
    try std.testing.expectEqual(@as(usize, 1), owner.count);
    try std.testing.expect(s.input_failed);
    try std.testing.expect(s.backend.isAlive());
    const text = try @import("session_vt.zig").plain(s.backend.vt.terminal, owner.a);
    defer owner.a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "READ_AFTER_INPUT_FAILURE") != null);
}

test "native launch mapping keeps literal argv and uses Windows shell commands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const direct = try prepareLaunch(a, .{ .argv = &.{ "demo.exe", "$HOME; &", "" } });
    try std.testing.expectEqualStrings("$HOME; &", direct.launch_command.?.argv.?[1]);
    const command = try prepareLaunch(a, .{ .command = "exit 7", .user_shell = true });
    try std.testing.expectEqualStrings("-Command", command.launch_command.?.argv.?[1]);
    try std.testing.expectEqualStrings("exit 7", command.launch_command.?.argv.?[2]);
    try std.testing.expect((try prepareLaunch(a, .{})).launch_command == null);
    try std.testing.expectEqualStrings("-NoLogo", (try prepareLaunch(a, .{ .shell_integration = false })).launch_command.?.argv.?[1]);
    try std.testing.expectError(error.UnsupportedBackgroundShell, prepareLaunch(a, .{ .argv = &.{ "/bin/bash", "-l" }, .command = "exit 7" }));
    try std.testing.expectError(error.InvalidEnv, validateSpawn(.{ .env = &.{.{ .key = "bad=key", .value = "x" }} }));
    try std.testing.expectError(error.InvalidSize, validateSpawn(.{ .cols = 32768 }));
}

test "interactive PowerShell session argv receives the native integration wrapper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const configured: []const []const u8 = &.{ "C:\\Program Files\\PowerShell\\7\\PWSH.EXE", "-NoProfile" };
    // Explicit exit policy must not be used to infer whether argv is a shell.
    const launch = try prepareLaunch(a, .{ .argv = configured, .close_on_exit = true });
    const args = launch.launch_command.?.argv.?;
    for (configured, args[0..configured.len]) |original, copied| {
        try std.testing.expectEqualStrings(original, copied);
        try std.testing.expect(original.ptr != copied.ptr);
    }
    try std.testing.expectEqualStrings("-Command", args[args.len - 2]);
    const wrapper = args[args.len - 1];
    try std.testing.expect(std.mem.startsWith(u8, wrapper, ". '"));
    try std.testing.expect(std.mem.endsWith(u8, wrapper, "\\powershell.ps1'"));
    const pid_dir = try std.fmt.allocPrint(a, "\\hollow-{d}\\", .{std.os.windows.GetCurrentProcessId()});
    try std.testing.expect(std.mem.indexOf(u8, wrapper, pid_dir) != null);
    try std.testing.expect(std.mem.indexOf(u8, wrapper, "HOLLOW_PANE_ID") == null);
    const disabled = try prepareLaunch(a, .{ .argv = configured, .shell_integration = false });
    try std.testing.expectEqual(configured.len, disabled.launch_command.?.argv.?.len);
    for (configured, disabled.launch_command.?.argv.?) |original, copied|
        try std.testing.expectEqualStrings(original, copied);
}

test "PowerShell commands and explicit apps never receive interactive hooks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const variants = [_][]const []const u8{
        &.{ "powershell.exe", "-Command", "$HOME; & 'literal app.exe'" },
        &.{ "pwsh.exe", "-File", "C:\\script with spaces.ps1" },
        &.{ "pwsh.exe", "script.ps1" },
        &.{ "cmd.exe", "/D", "/Q" },
        &.{ "demo.exe", "$HOME; &", "" },
    };
    for (variants) |configured| {
        const launch = try prepareLaunch(a, .{ .argv = configured, .close_on_exit = true });
        const args = launch.launch_command.?.argv.?;
        try std.testing.expectEqual(configured.len, args.len);
        for (configured, args) |original, copied| try std.testing.expectEqualStrings(original, copied);
    }
    const one_shot = try prepareLaunch(a, .{ .argv = &.{ "pwsh.exe", "-NoProfile" }, .one_shot = true });
    try std.testing.expectEqual(@as(usize, 2), one_shot.launch_command.?.argv.?.len);
    const command = try prepareLaunch(a, .{ .argv = &.{"pwsh.exe"}, .command = "literal command" });
    try std.testing.expectEqualStrings("literal command", command.launch_command.?.argv.?[4]);
    try std.testing.expect(!interactiveNativeShell(&.{ "pwsh.exe", "-Command", "exit 0" }));
    try std.testing.expect(!closeOnExit(.{ .argv = &.{"pwsh.exe"}, .user_shell = true }));
}

test "configured native PowerShell reports cwd without GUI pane identity" {
    const Wait = struct {
        extern "kernel32" fn Sleep(std.os.windows.DWORD) callconv(.winapi) void;
    };
    var owner = Owner.init(std.testing.allocator, .{});
    defer owner.deinit();
    const session = try owner.create(&.{ .id = 1, .op = .create, .spawn = .{
        .argv = &.{ "powershell.exe", "-NoProfile" },
    } });
    const pane = session.panes[0];
    for (0..1000) |turn| {
        _ = owner.tick(@intCast(turn * 10));
        try std.testing.expectEqual(@as(usize, 1), owner.count);
        const pwd = try pane.backend.vt.pwd(owner.a);
        defer owner.a.free(pwd);
        if (windowsPath(pwd)) return;
        try std.testing.expect(pane.status == null);
        Wait.Sleep(10);
    }
    return error.TestUnexpectedResult;
}
