//! `hollow-agent session serve` on Linux: the per-user owner that keeps
//! session panes alive across client disconnects (docs/persistent-sessions.md).
//! One poll loop drains every PTY into its headless VT, serves clients on a
//! unix socket, and streams output to the attached client under per-pane
//! credit.
const std = @import("std");
const p = @import("session_protocol.zig");
const core = @import("session_core.zig");
const pty = @import("pty.zig");
const Vt = @import("session_vt.zig").Vt;
const session_vt = @import("session_vt.zig");
const c = @import("posix_c");

const read_chunk = 64 * 1024;
/// Client input and query replies waiting for the PTY; beyond this, input
/// is dropped (the program is not reading).
const input_limit = 4 * 1024 * 1024;
/// A client whose socket backs up this far is disconnected.
const client_out_limit = 64 * 1024 * 1024;
const termination_grace_ms = 1500;
/// A freshly started owner nobody talks to exits after this.
const startup_grace_ms = 10_000;
/// Keeps tmpfiles aging (10 days on /tmp by default) off the socket and lock.
const touch_interval_ms = 60 * 60 * 1000;
/// After a pane's process is reaped, how long to wait for PTY EOF (a
/// background job may hold the slave) before sending its exit status.
const exit_linger_ms = 200;
/// Pending snapshots are encoded only while the client's queue is below
/// this, so attaching many large panes never queues them all at once.
const snapshot_queue_low = 1024 * 1024;
pub const default_scrollback_bytes = 10 * 1024 * 1024;

// ---------------------------------------------------------------------------
// Paths

pub const Paths = struct {
    dir: [:0]u8,
    socket: [:0]u8,
    lock: [:0]u8,

    pub fn deinit(self: Paths, a: std.mem.Allocator) void {
        a.free(self.dir);
        a.free(self.socket);
        a.free(self.lock);
    }
};

/// `/tmp/hollow-session-$UID` (or absolute `$HOLLOW_SESSION_DIR`, for
/// tests). Not `$XDG_RUNTIME_DIR`: systemd deletes it when the user's last
/// login session ends, taking the socket of a still-running owner with it.
/// Separate from the shell integration dir `/tmp/hollow-$UID`, which is not
/// `0700`. The directory is created `0700` and refused if it has another
/// owner or group/other bits.
pub fn resolvePaths(a: std.mem.Allocator) !Paths {
    const override = env("HOLLOW_SESSION_DIR");
    const dir = if (override != null and override.?.len > 0 and override.?[0] == '/')
        try a.dupeSentinel(u8, override.?, 0)
    else
        try std.fmt.allocPrintSentinel(a, "/tmp/hollow-session-{d}", .{c.getuid()}, 0);
    errdefer a.free(dir);
    try ensurePrivateDir(dir);
    const socket = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, p.socket_name }, 0);
    errdefer a.free(socket);
    const addr: c.struct_sockaddr_un = undefined;
    if (socket.len >= addr.sun_path.len) return error.NameTooLong;
    return .{ .dir = dir, .socket = socket, .lock = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, p.lock_name }, 0) };
}

pub fn ensurePrivateDir(path: [:0]const u8) !void {
    if (c.mkdir(path.ptr, 0o700) != 0 and errno() != c.EEXIST) return error.RuntimeDirFailed;
    const linux = std.os.linux;
    var st: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, path.ptr, linux.AT.SYMLINK_NOFOLLOW, .BASIC_STATS, &st);
    if (linux.errno(rc) != .SUCCESS) return error.RuntimeDirFailed;
    if ((st.mode & c.S_IFMT) != c.S_IFDIR or st.uid != c.getuid() or (st.mode & 0o077) != 0) return error.UnsafeRuntimeDir;
}

/// `$XDG_STATE_HOME/hollow/sessions`, else `~/.local/state/hollow/sessions`.
fn stateDir(a: std.mem.Allocator) ![:0]u8 {
    const base = if (env("XDG_STATE_HOME")) |s| if (s.len > 0 and s[0] == '/') try a.dupe(u8, s) else null else null;
    const root = base orelse blk: {
        const home = env("HOME") orelse return error.NoHome;
        break :blk try std.fmt.allocPrint(a, "{s}/.local/state", .{home});
    };
    defer a.free(root);
    const out = try std.fmt.allocPrintSentinel(a, "{s}/hollow/sessions", .{root}, 0);
    errdefer a.free(out);
    var i: usize = 1;
    while (i <= out.len) : (i += 1) {
        if (i < out.len and out[i] != '/') continue;
        const saved = if (i < out.len) out[i] else 0;
        out[i] = 0;
        defer out[i] = saved;
        if (c.mkdir(out.ptr, 0o700) != 0 and errno() != c.EEXIST) return error.StateDirFailed;
    }
    return out;
}

// ---------------------------------------------------------------------------
// Owner state

/// Byte queue with a moving start, so consuming frames is O(1).
const Queue = struct {
    buf: std.ArrayList(u8) = .empty,
    start: usize = 0,

    fn len(self: *const Queue) usize {
        return self.buf.items.len - self.start;
    }
    fn slice(self: *const Queue) []const u8 {
        return self.buf.items[self.start..];
    }
    fn append(self: *Queue, a: std.mem.Allocator, bytes: []const u8) !void {
        try self.buf.appendSlice(a, bytes);
    }
    fn consume(self: *Queue, n: usize) void {
        self.start += n;
        if (self.start == self.buf.items.len) {
            self.clear();
        } else if (self.start >= 64 * 1024 and self.start * 2 >= self.buf.items.len) {
            const rest = self.len();
            std.mem.copyForwards(u8, self.buf.items[0..rest], self.buf.items[self.start..]);
            self.buf.items.len = rest;
            self.start = 0;
        }
    }
    fn clear(self: *Queue) void {
        self.buf.clearRetainingCapacity();
        self.start = 0;
    }
    fn deinit(self: *Queue, a: std.mem.Allocator) void {
        self.buf.deinit(a);
    }
};

const Pane = struct {
    id: u32,
    pid: c.pid_t,
    master: c_int,
    /// Exec-status pipe; closed by a successful exec (CLOEXEC).
    launch: c_int,
    vt: *Vt,
    cols: u16,
    rows: u16,
    /// Spawn request as JSON, kept for state files and later respawn.
    spawn: []u8,
    close_on_exit: bool = false,
    /// Encoded exit status once reaped (see `p.encodeExit`).
    status: ?i32 = null,
    /// Exit is sent at PTY EOF or at this deadline, whichever comes first.
    exit_deadline: i64 = 0,
    exit_sent: bool = false,
    /// The attached client still needs a snapshot; output waits for it.
    snapshot_pending: bool = false,
    /// Client input and VT query replies waiting for the PTY.
    input: Queue = .{},
    /// Output read since the attached client's last grant ran out.
    unsent: Queue = .{},
    credit: u32 = p.window,
    /// Backlog was dropped; resync with a snapshot once the client catches up.
    stale: bool = false,
    removed: bool = false,
};

/// OSC 7 reports `file://host/path`; clients want the bare path, matching
/// the client-side pwd callback.
pub fn osc7Path(pwd: []const u8) []const u8 {
    var path = pwd;
    if (std.mem.startsWith(u8, path, "cwd;")) path = path[4..];
    if (std.mem.startsWith(u8, path, "file://")) {
        path = path[7..];
        path = if (std.mem.indexOfScalar(u8, path, '/')) |idx| path[idx..] else "";
    }
    return path;
}

/// Shell-reported cwd, else the spawn cwd: programs like nvim never report
/// one, and clients split new panes from this value.
fn paneCwd(arena: std.mem.Allocator, pane: *const Pane) ![]const u8 {
    const pwd = osc7Path(try pane.vt.pwd(arena));
    if (pwd.len > 0) return pwd;
    const spawn = std.json.parseFromSliceLeaky(p.Spawn, arena, pane.spawn, .{ .ignore_unknown_fields = true }) catch return pwd;
    return spawn.cwd orelse pwd;
}

const Session = struct {
    meta: core.Metadata,
    panes: std.ArrayList(*Pane) = .empty,
    client: ?*Client = null,

    fn find(self: *Session, id: u32) ?*Pane {
        for (self.panes.items) |pane| if (pane.id == id and !pane.removed) return pane;
        return null;
    }
};

const Client = struct {
    fd: c_int,
    reader: p.Reader = .{},
    out: Queue = .{},
    hello: bool = false,
    binary: bool = false,
    foreground_events: bool = false,
    session: ?*Session = null,
    /// Close once `out` is flushed.
    closing: bool = false,
    dead: bool = false,
};

const Doomed = struct { pid: c.pid_t, deadline: i64, killed: bool = false };

const Slot = union(enum) { listen, signal, client: *Client, master: struct { s: *Session, pane: *Pane }, launch: *Pane };

pub const Owner = struct {
    a: std.mem.Allocator,
    io: std.Io,
    identity: []const u8,
    listen_fd: c_int = -1,
    signal_fd: c_int = -1,
    state_dir: ?[:0]u8 = null,
    /// Sent in every welcome; empty when no state dir could be used.
    host_buf: [32]u8 = undefined,
    host: []const u8 = "",
    /// Socket and lock paths to keep fresh; set by `serve`.
    touch_paths: []const [:0]const u8 = &.{},
    touched: i64 = 0,
    scrollback_bytes: usize = default_scrollback_bytes,
    sessions: std.ArrayList(*Session) = .empty,
    clients: std.ArrayList(*Client) = .empty,
    doomed: std.ArrayList(Doomed) = .empty,
    fds: std.ArrayList(c.struct_pollfd) = .empty,
    slots: std.ArrayList(Slot) = .empty,
    read_buf: [read_chunk]u8 = undefined,
    started: i64,
    had_client: bool = false,
    /// `idle` is cancelled by a new client; `kill` (kill_server, SIGTERM)
    /// stops listening.
    stop: enum { none, idle, kill } = .none,

    pub fn init(a: std.mem.Allocator, io: std.Io) Owner {
        return .{ .a = a, .io = io, .identity = session_vt.buildIdentity(), .started = nowMs() };
    }

    pub fn deinit(self: *Owner) void {
        for (self.sessions.items) |s| self.endSession(s);
        self.collect();
        for (self.doomed.items) |d| {
            signalGroup(d.pid, c.SIGKILL);
            _ = c.waitpid(d.pid, null, 0);
        }
        for (self.clients.items) |client| self.freeClient(client);
        self.clients.deinit(self.a);
        self.sessions.deinit(self.a);
        self.doomed.deinit(self.a);
        self.fds.deinit(self.a);
        self.slots.deinit(self.a);
        if (self.state_dir) |dir| self.a.free(dir);
    }

    /// Done once stopping and every killed process has been reaped (or
    /// escalated to SIGKILL).
    pub fn done(self: *Owner) bool {
        if (self.stop == .none) return false;
        for (self.doomed.items) |d| if (!d.killed) return false;
        return true;
    }

    pub fn addClient(self: *Owner, fd: c_int) !*Client {
        const client = try self.a.create(Client);
        errdefer self.a.destroy(client);
        client.* = .{ .fd = fd };
        try self.clients.append(self.a, client);
        self.had_client = true;
        if (self.stop == .idle) self.stop = .none;
        return client;
    }

    /// One poll round. `timeout_ms` caps the wait.
    pub fn step(self: *Owner, timeout_ms: i32) !void {
        self.fds.clearRetainingCapacity();
        self.slots.clearRetainingCapacity();
        if (self.listen_fd >= 0 and self.stop != .kill) try self.watch(.listen, self.listen_fd, c.POLLIN);
        if (self.signal_fd >= 0) try self.watch(.signal, self.signal_fd, c.POLLIN);
        for (self.clients.items) |client| {
            if (client.dead) continue;
            const events: c_int = if (client.closing) 0 else c.POLLIN;
            try self.watch(.{ .client = client }, client.fd, events | if (client.out.len() > 0) @as(c_int, c.POLLOUT) else 0);
        }
        for (self.sessions.items) |s| for (s.panes.items) |pane| {
            if (pane.master >= 0) try self.watch(.{ .master = .{ .s = s, .pane = pane } }, pane.master, c.POLLIN | if (pane.input.len() > 0) @as(c_int, c.POLLOUT) else 0);
            if (pane.launch >= 0) try self.watch(.{ .launch = pane }, pane.launch, c.POLLIN);
        };

        var timeout = timeout_ms;
        const now = nowMs();
        for (self.doomed.items) |d| if (!d.killed) {
            timeout = clampTimeout(timeout, d.deadline - now);
        };
        if (!self.had_client and self.sessions.items.len == 0) timeout = clampTimeout(timeout, self.started + startup_grace_ms - now);
        for (self.sessions.items) |s| for (s.panes.items) |pane| if (pane.status != null and !pane.exit_sent and s.client != null and
            pane.master >= 0 and pane.unsent.len() == 0 and !pane.snapshot_pending and !pane.stale)
        {
            timeout = clampTimeout(timeout, pane.exit_deadline - now);
        };
        // Without signalfd (tests), exits are only noticed by polling.
        if (self.signal_fd < 0) timeout = clampTimeout(timeout, 20);

        const polled = c.poll(self.fds.items.ptr, @intCast(self.fds.items.len), timeout);
        if (polled < 0 and errno() != c.EINTR) return error.PollFailed;
        if (polled > 0) for (self.fds.items, self.slots.items) |fd, slot| {
            if (fd.revents == 0) continue;
            switch (slot) {
                .listen => self.accept(),
                .signal => self.drainSignals(),
                .client => |client| {
                    if (client.dead) continue;
                    if ((fd.revents & c.POLLOUT) != 0) self.flushClient(client);
                    if ((fd.revents & (c.POLLIN | c.POLLHUP | c.POLLERR)) != 0) self.readClient(client);
                },
                .master => |m| {
                    if (m.pane.removed) continue;
                    if ((fd.revents & c.POLLOUT) != 0) flushInput(m.pane);
                    if ((fd.revents & (c.POLLIN | c.POLLHUP | c.POLLERR)) != 0) self.readPane(m.s, m.pane);
                },
                .launch => |pane| if (!pane.removed) self.readLaunch(pane),
            }
        };
        self.reap();
        self.escalate();
        for (self.sessions.items) |s| for (s.panes.items) |pane| if (!pane.removed) {
            flushInput(pane);
            // Exit deadlines expire without any fd activity.
            if (pane.status != null and !pane.exit_sent) self.flushPane(s, pane);
        };
        for (self.clients.items) |client| if (!client.dead) {
            self.serveSnapshots(client);
            self.flushClient(client);
        };
        self.collect();
        if (self.touch_paths.len > 0 and nowMs() - self.touched >= touch_interval_ms) {
            self.touched = nowMs();
            for (self.touch_paths) |path| _ = c.utimensat(c.AT_FDCWD, path.ptr, null, 0);
        }
        if (self.stop == .none and self.sessions.items.len == 0 and self.clients.items.len == 0 and
            (self.had_client or nowMs() - self.started >= startup_grace_ms)) self.stop = .idle;
    }

    fn watch(self: *Owner, slot: Slot, fd: c_int, events: c_int) !void {
        try self.fds.append(self.a, .{ .fd = fd, .events = @intCast(events), .revents = 0 });
        try self.slots.append(self.a, slot);
    }

    // -- clients -----------------------------------------------------------

    fn accept(self: *Owner) void {
        while (true) {
            const fd = std.c.accept4(self.listen_fd, null, null, @intCast(c.SOCK_CLOEXEC | c.SOCK_NONBLOCK));
            if (fd < 0) return;
            // The 0700 directory already restricts access; this also covers a
            // socket path opened before a permission change.
            var cred: c.struct_ucred = undefined;
            var len: c.socklen_t = @sizeOf(c.struct_ucred);
            if (c.getsockopt(fd, c.SOL_SOCKET, c.SO_PEERCRED, &cred, &len) != 0 or cred.uid != c.getuid()) {
                _ = c.close(fd);
                continue;
            }
            _ = self.addClient(fd) catch {
                _ = c.close(fd);
                return;
            };
        }
    }

    fn readClient(self: *Owner, client: *Client) void {
        var reads: usize = 0;
        while (reads < 4 and !client.dead and !client.closing) : (reads += 1) {
            const n = c.read(client.fd, &self.read_buf, self.read_buf.len);
            if (n == 0) return self.dropClient(client);
            if (n < 0) {
                if (errno() == c.EINTR) continue;
                if (errno() == c.EAGAIN) return;
                return self.dropClient(client);
            }
            client.reader.push(self.a, self.read_buf[0..@intCast(n)]) catch return self.dropClient(client);
            while (!client.dead and !client.closing) {
                const frame = (client.reader.next() catch return self.protocolError(client, error.PayloadTooLarge)) orelse break;
                self.handleFrame(client, frame.header, frame.payload) catch |err| return self.protocolError(client, err);
            }
        }
    }

    fn protocolError(self: *Owner, client: *Client, err: anyerror) void {
        self.replyError(client, 0, err);
        client.closing = true;
    }

    fn dropClient(self: *Owner, client: *Client) void {
        if (client.session) |s| self.detach(client, s);
        client.dead = true;
    }

    fn flushClient(self: *Owner, client: *Client) void {
        while (client.out.len() > 0) {
            const bytes = client.out.slice();
            const n = c.write(client.fd, bytes.ptr, bytes.len);
            if (n < 0) {
                if (errno() == c.EINTR) continue;
                if (errno() == c.EAGAIN) break;
                return self.dropClient(client);
            }
            client.out.consume(@intCast(n));
        }
        if (client.out.len() > client_out_limit) return self.dropClient(client);
        if (client.closing and client.out.len() == 0) self.dropClient(client);
    }

    fn send(self: *Owner, client: *Client, kind: p.Kind, stream: u32, payload: []const u8) void {
        if (client.dead) return;
        client.out.append(self.a, &p.header(kind, stream, payload.len).encode()) catch return self.dropClient(client);
        client.out.append(self.a, payload) catch return self.dropClient(client);
    }

    fn sendJson(self: *Owner, client: *Client, kind: p.Kind, value: anytype) void {
        const body = p.stringify(self.a, value) catch return self.dropClient(client);
        defer self.a.free(body);
        if (body.len > p.control_limit) return self.replyError(client, 0, error.ReplyTooLarge);
        self.send(client, kind, 0, body);
    }

    fn reply(self: *Owner, client: *Client, value: p.Reply) void {
        self.sendJson(client, .reply, value);
    }

    fn replyError(self: *Owner, client: *Client, id: u64, err: anyerror) void {
        self.reply(client, .{ .id = id, .ok = false, .@"error" = @errorName(err) });
    }

    fn event(self: *Owner, client: *Client, kind: p.EventKind, s: *Session, pane: ?u32) void {
        self.sendJson(client, .event, p.Event{ .event = kind, .session = &s.meta.id, .pane = pane });
    }

    fn handleFrame(self: *Owner, client: *Client, h: p.Header, payload: []const u8) !void {
        const kind = try p.validate(h, .to_owner);
        if (!client.hello and kind != .hello) return error.ExpectedHello;
        switch (kind) {
            .hello => {
                if (client.hello) return error.DuplicateHello;
                const hello = try p.parse(p.Hello, self.a, payload);
                defer hello.deinit();
                if (!std.mem.eql(u8, hello.value.protocol, p.protocol) or hello.value.version != p.version) return error.ProtocolMismatch;
                client.hello = true;
                client.binary = std.mem.eql(u8, hello.value.ghostty, self.identity);
                client.foreground_events = hello.value.foreground_events;
                self.sendJson(client, .welcome, p.Welcome{ .ghostty = self.identity, .snapshot = if (client.binary) .binary else .vt, .owner_pid = c.getpid(), .host = self.host, .features = &p.owner_features });
            },
            .request => {
                const parsed = try p.parse(p.Request, self.a, payload);
                defer parsed.deinit();
                self.handleRequest(client, parsed.value) catch |err| self.replyError(client, parsed.value.id, err);
            },
            .input => {
                const pane = self.attachedPane(client, h.stream) orelse return;
                if (pane.master < 0 or pane.status != null) return;
                if (pane.input.len() + payload.len > input_limit) return;
                try pane.input.append(self.a, payload);
            },
            .resize => {
                const size = try p.decodeResize(payload);
                const pane = self.attachedPane(client, h.stream) orelse return;
                try resizePane(pane, size.cols, size.rows);
            },
            .credit => {
                const grant = try p.decodeCredit(payload);
                const s = client.session orelse return;
                const pane = s.find(h.stream) orelse return;
                pane.credit = @min(p.window, pane.credit + grant);
                self.flushPane(s, pane);
            },
            else => unreachable,
        }
    }

    fn attachedPane(_: *Owner, client: *Client, id: u32) ?*Pane {
        const s = client.session orelse return null;
        return s.find(id);
    }

    fn handleRequest(self: *Owner, client: *Client, req: p.Request) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.a);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        switch (req.op) {
            .list => {
                var list: std.ArrayList(p.SessionInfo) = .empty;
                for (self.sessions.items) |s| if (!s.meta.ended) try list.append(arena, try self.info(arena, s));
                self.reply(client, .{ .id = req.id, .sessions = list.items });
            },
            .create => {
                const s = try self.createSession(req.create_id);
                errdefer self.endSession(s);
                // Copy layout before fork: allocation failure must not launch
                // a process whose create request is then rejected.
                if (req.layout) |layout| try s.meta.setInitialLayout(self.a, layout);
                _ = try self.spawnPane(s, req.spawn orelse .{}, false);
                self.attach(client, s, req.id, &.{});
            },
            .attach => {
                const s = self.findSession(req.session orelse return error.MissingSession) orelse return error.SessionNotFound;
                self.attach(client, s, req.id, req.panes);
            },
            .detach => {
                if (client.session) |s| self.detach(client, s);
                self.reply(client, .{ .id = req.id });
            },
            .kill => {
                const s = if (req.session) |id| self.findSession(id) orelse return error.SessionNotFound else client.session orelse return error.NotAttached;
                self.endSession(s);
                self.reply(client, .{ .id = req.id });
            },
            .spawn => {
                const s = client.session orelse return error.NotAttached;
                const pane = try self.spawnPane(s, req.spawn orelse .{}, true);
                self.reply(client, .{ .id = req.id, .pane = pane.id, .revision = s.meta.revision });
                self.saveState(s);
            },
            .close => {
                const s = client.session orelse return error.NotAttached;
                const pane = s.find(req.pane orelse return error.MissingPane) orelse return error.PaneNotFound;
                const revision = try s.meta.prepareMembershipChange();
                self.closePane(s, pane);
                s.meta.revision = revision;
                self.reply(client, .{ .id = req.id, .revision = s.meta.revision });
                if (livePanes(s) == 0) self.endSession(s) else self.saveState(s);
            },
            .layout => {
                const s = client.session orelse return error.NotAttached;
                s.meta.replaceLayout(self.a, req.revision, req.layout orelse "") catch |err| {
                    if (err != error.RevisionConflict) return err;
                    self.reply(client, .{ .id = req.id, .ok = false, .@"error" = "RevisionConflict", .revision = s.meta.revision });
                    return;
                };
                self.reply(client, .{ .id = req.id, .revision = s.meta.revision });
                self.saveState(s);
            },
            .respawn => {
                const s = client.session orelse return error.NotAttached;
                const pane = s.find(req.pane orelse return error.MissingPane) orelse return error.PaneNotFound;
                try self.respawnPane(s, pane);
                self.reply(client, .{ .id = req.id, .pane = pane.id });
            },
            .kill_server => {
                for (self.sessions.items) |s| self.endSession(s);
                self.reply(client, .{ .id = req.id });
                self.stop = .kill;
            },
        }
    }

    fn info(self: *Owner, arena: std.mem.Allocator, s: *Session) !p.SessionInfo {
        _ = self;
        var panes: std.ArrayList(p.PaneInfo) = .empty;
        for (s.panes.items) |pane| if (!pane.removed) try panes.append(arena, .{
            .id = pane.id,
            .cols = pane.cols,
            .rows = pane.rows,
            .title = try pane.vt.title(arena),
            .cwd = try paneCwd(arena, pane),
            .foreground_process = if (pane.status == null) pane.vt.shell_command.value() else "",
            .exit = pane.status,
            .close_on_exit = pane.close_on_exit,
        });
        return .{ .id = &s.meta.id, .attached = s.client != null, .revision = s.meta.revision, .layout = s.meta.layout, .panes = panes.items };
    }

    /// Attach with take-over: the reply carries the session, then each pane
    /// gets a snapshot (see `serveSnapshots`) and live output resumes.
    fn attach(self: *Owner, client: *Client, s: *Session, id: u64, sizes: []const p.PaneSize) void {
        if (client.session) |old| if (old != s) self.detach(client, old);
        if (s.client) |other| if (other != client) {
            other.session = null;
            self.event(other, .taken, s, null);
        };
        s.client = client;
        client.session = s;
        for (sizes) |size| if (s.find(size.pane)) |pane| {
            if (size.cols > 0 and size.rows > 0) resizePane(pane, size.cols, size.rows) catch {};
        };
        var arena_state = std.heap.ArenaAllocator.init(self.a);
        defer arena_state.deinit();
        const session_info = self.info(arena_state.allocator(), s) catch return self.replyError(client, id, error.OutOfMemory);
        self.reply(client, .{ .id = id, .session = session_info });
        for (s.panes.items) |pane| if (!pane.removed) {
            pane.unsent.clear();
            pane.stale = false;
            pane.credit = p.window;
            pane.exit_sent = false;
            pane.snapshot_pending = true;
        };
        self.serveSnapshots(client);
        self.saveState(s);
    }

    fn detach(self: *Owner, client: *Client, s: *Session) void {
        if (s.client == client) s.client = null;
        client.session = null;
        for (s.panes.items) |pane| pane.unsent.clear();
        self.saveState(s);
    }

    /// Encodes pending snapshots while the client keeps up. The snapshot is
    /// taken from the VT at send time, so bytes read while it was pending
    /// are already in it and are not streamed. Single-threaded, so no PTY
    /// bytes can slip in between snapshot and stream.
    fn serveSnapshots(self: *Owner, client: *Client) void {
        const s = client.session orelse return;
        for (s.panes.items) |pane| {
            if (client.dead or client.out.len() >= snapshot_queue_low) return;
            if (pane.removed or !pane.snapshot_pending) continue;
            pane.snapshot_pending = false;
            pane.unsent.clear();
            self.sendSnapshot(client, pane);
            self.flushPane(s, pane);
        }
    }

    fn sendSnapshot(self: *Owner, client: *Client, pane: *Pane) void {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(self.a);
        const result = if (client.binary) pane.vt.snapshot(self.a, &bytes) else pane.vt.formatVt(self.a, &bytes);
        // An encode failure still ends the snapshot; the client starts blank.
        if (result) |_| {
            var offset: usize = 0;
            while (offset < bytes.items.len) {
                const n = @min(p.max_data, bytes.items.len - offset);
                self.send(client, .snapshot, pane.id, bytes.items[offset..][0..n]);
                offset += n;
            }
        } else |_| bytes.clearRetainingCapacity();
        self.send(client, .snapshot_end, pane.id, "");
        if (!client.foreground_events) return;
        // HTP events swallowed by the snapshot must not leave stale foreground
        // state. Sync only the value, not command-start/completion side effects.
        const state = p.stringify(self.a, .{
            .kind = "event",
            .name = "session_foreground_process",
            .payload = .{ .command = if (pane.status == null) pane.vt.shell_command.value() else "" },
        }) catch {
            client.dead = true;
            return;
        };
        defer self.a.free(state);
        const framed = std.fmt.allocPrint(self.a, "\x1b]1337;Hollow;{s}\x1b\\", .{state}) catch {
            client.dead = true;
            return;
        };
        defer self.a.free(framed);
        pane.unsent.append(self.a, framed) catch {
            client.dead = true;
        };
    }

    // -- sessions and panes -----------------------------------------------

    fn findSession(self: *Owner, id: []const u8) ?*Session {
        return core.findSession(self.sessions.items, id);
    }

    fn createSession(self: *Owner, reserved: ?[]const u8) !*Session {
        const id: [32]u8 = if (reserved) |value| try core.reservedId(value) else blk: {
            var random: [16]u8 = undefined;
            try fillRandom(&random);
            break :blk core.randomId(random);
        };
        // Ended entries reserve identity only until collect removes them.
        try core.checkCollision(self.sessions.items, &id);
        const s = try self.a.create(Session);
        errdefer self.a.destroy(s);
        s.* = .{ .meta = .{ .id = id } };
        try self.sessions.append(self.a, s);
        return s;
    }

    fn spawnPane(self: *Owner, s: *Session, spawn: p.Spawn, membership_change: bool) !*Pane {
        const prepared = try s.meta.preparePane(membership_change);
        if (spawn.cols == 0 or spawn.rows == 0) return error.InvalidSize;
        try pty.validateSpawn(spawn);
        const spawn_json = try p.stringify(self.a, spawn);
        errdefer self.a.free(spawn_json);
        const vt = try Vt.create(self.a, spawn.cols, spawn.rows, self.scrollback_bytes);
        errdefer vt.destroy();
        const pane = try self.a.create(Pane);
        errdefer self.a.destroy(pane);
        try s.panes.ensureUnusedCapacity(self.a, 1);
        const child = try self.forkChild(spawn, spawn.cols, spawn.rows);
        pane.* = .{ .id = prepared.id, .pid = child.pid, .master = child.master, .launch = child.launch, .vt = vt, .cols = spawn.cols, .rows = spawn.rows, .spawn = spawn_json, .close_on_exit = @import("pty_protocol.zig").sessionCloseOnExit(spawn) };
        s.panes.appendAssumeCapacity(pane);
        prepared.commit(&s.meta);
        self.saveState(s);
        return pane;
    }

    /// Restarts an exited pane from its saved spawn at its current size. The
    /// VT, scrollback, and output credit carry over: the new process writes
    /// below the old screen.
    fn respawnPane(self: *Owner, s: *Session, pane: *Pane) !void {
        if (pane.status == null) return error.PaneAlive;
        var arena_state = std.heap.ArenaAllocator.init(self.a);
        defer arena_state.deinit();
        const spawn = try std.json.parseFromSliceLeaky(p.Spawn, arena_state.allocator(), pane.spawn, .{ .ignore_unknown_fields = true });
        const child = try self.forkChild(spawn, pane.cols, pane.rows);
        // Late output of the old process (already reported dead) is dropped.
        if (pane.master >= 0) _ = c.close(pane.master);
        if (pane.launch >= 0) _ = c.close(pane.launch);
        pane.input.clear();
        pane.unsent.clear();
        pane.pid = child.pid;
        pane.master = child.master;
        pane.launch = child.launch;
        pane.status = null;
        pane.vt.shell_command = .{};
        pane.exit_sent = false;
        pane.exit_deadline = 0;
        self.saveState(s);
    }

    const Child = struct { pid: c.pid_t, master: c_int, launch: c_int };

    fn forkChild(self: *Owner, spawn: p.Spawn, cols: u16, rows: u16) !Child {
        var launch: [2]c_int = undefined;
        if (c.pipe2(&launch, c.O_CLOEXEC | c.O_NONBLOCK) != 0) return error.PipeFailed;
        errdefer _ = c.close(launch[0]);
        defer _ = c.close(launch[1]);
        var size = std.mem.zeroes(c.struct_winsize);
        size.ws_col = cols;
        size.ws_row = rows;
        var master: c_int = -1;
        const pid = c.forkpty(&master, null, null, &size);
        if (pid < 0) return error.ForkFailed;
        if (pid == 0) {
            // Keep only PTY stdio and the exec-status pipe; this closes the
            // listener, other panes' masters, and client sockets. No
            // parent-death signal: panes must outlive clients (and survive an
            // owner crash as orphans rather than die with it).
            if (launch[1] != 3 and c.dup3(launch[1], 3, c.O_CLOEXEC) < 0) c._exit(126);
            if (std.os.linux.errno(std.os.linux.close_range(4, std.math.maxInt(c_int), .{ .UNSHARE = false, .CLOEXEC = false })) != .SUCCESS) c._exit(126);
            // Client-local IDs/endpoints become stale after reattachment. Shell
            // integration in persistent panes must use its pane-bound OSC path.
            inline for (.{ "HOLLOW_PANE_ID", "HOLLOW_WORKSPACE_ID", "HOLLOW_COMMAND_ADDR" }) |key| _ = c.unsetenv(key);
            if (c.setenv("HOLLOW_TRANSPORT", "osc", 1) != 0) c._exit(126);
            pty.execSpawn(self.a, self.io, spawn) catch |err| {
                const name = @errorName(err);
                _ = c.write(3, name.ptr, name.len);
            };
            c._exit(127);
        }
        setNonBlocking(master);
        return .{ .pid = pid, .master = master, .launch = launch[0] };
    }

    fn readLaunch(self: *Owner, pane: *Pane) void {
        var buf: [256]u8 = undefined;
        const n = c.read(pane.launch, &buf, buf.len);
        if (n < 0 and (errno() == c.EAGAIN or errno() == c.EINTR)) return;
        _ = c.close(pane.launch);
        pane.launch = -1;
        if (n > 0) {
            // The child failed before exec; show why in the (dead) pane.
            var msg: [320]u8 = undefined;
            const text = std.fmt.bufPrint(&msg, "hollow-agent: spawn failed: {s}\r\n", .{buf[0..@intCast(n)]}) catch return;
            for (self.sessions.items) |s| if (std.mem.indexOfScalar(*Pane, s.panes.items, pane) != null) self.feed(s, pane, text);
        }
    }

    fn readPane(self: *Owner, s: *Session, pane: *Pane) void {
        while (true) {
            const n = c.read(pane.master, &self.read_buf, self.read_buf.len);
            if (n > 0) {
                self.feed(s, pane, self.read_buf[0..@intCast(n)]);
                return;
            }
            if (n < 0 and errno() == c.EINTR) continue;
            if (n < 0 and errno() == c.EAGAIN) return;
            // EIO: every slave fd is closed.
            _ = c.close(pane.master);
            pane.master = -1;
            pane.input.clear();
            self.flushPane(s, pane);
            return;
        }
    }

    /// All PTY bytes go through the owner VT, even with no client attached.
    fn feed(self: *Owner, s: *Session, pane: *Pane, bytes: []const u8) void {
        pane.vt.write(bytes);
        var replies = pane.vt.takeReplies();
        defer replies.deinit(self.a);
        if (replies.items.len > 0 and pane.master >= 0 and pane.input.len() + replies.items.len <= input_limit) {
            pane.input.append(self.a, replies.items) catch {};
        }
        // Output after the exit status only updates the VT (and so the next
        // snapshot); the client has already been told the pane is dead.
        if (s.client == null or pane.stale or pane.snapshot_pending or pane.exit_sent) return;
        pane.unsent.append(self.a, bytes) catch {
            pane.unsent.clear();
            pane.stale = true;
        };
        if (pane.unsent.len() > p.resync_limit) {
            pane.unsent.clear();
            pane.stale = true;
        }
        self.flushPane(s, pane);
    }

    /// Sends output within the pane's credit, then the exit status once all
    /// output before it is out. A stale pane is resynced when the client has
    /// returned all credit.
    fn flushPane(self: *Owner, s: *Session, pane: *Pane) void {
        const client = s.client orelse return;
        if (pane.snapshot_pending) return;
        if (pane.stale) {
            if (pane.credit < p.window) return;
            pane.stale = false;
            pane.snapshot_pending = true;
            self.event(client, .resync, s, pane.id);
            return self.serveSnapshots(client);
        }
        while (pane.unsent.len() > 0 and pane.credit > 0) {
            const n = @min(@min(pane.unsent.len(), p.max_data), pane.credit);
            self.send(client, .output, pane.id, pane.unsent.slice()[0..n]);
            pane.unsent.consume(n);
            pane.credit -= @intCast(n);
        }
        if (pane.status) |status| if (!pane.exit_sent and pane.unsent.len() == 0 and (pane.master < 0 or nowMs() >= pane.exit_deadline)) {
            pane.exit_sent = true;
            self.send(client, .exit, pane.id, &p.encodeExit(status));
        };
    }

    fn reap(self: *Owner) void {
        while (true) {
            var status: c_int = 0;
            const pid = c.waitpid(-1, &status, c.WNOHANG);
            if (pid <= 0) return;
            const code: i32 = if (c.WIFEXITED(status)) @intCast(c.WEXITSTATUS(status)) else if (c.WIFSIGNALED(status)) -@as(i32, @intCast(c.WTERMSIG(status))) else 1;
            for (self.doomed.items, 0..) |d, i| if (d.pid == pid) {
                _ = self.doomed.swapRemove(i);
                break;
            };
            for (self.sessions.items) |s| for (s.panes.items) |pane| {
                if (pane.pid != pid or pane.removed or pane.status != null) continue;
                // The exit frame waits for PTY EOF (or the linger deadline)
                // so output written just before exit precedes it.
                pane.status = code;
                pane.exit_deadline = nowMs() + exit_linger_ms;
                self.flushPane(s, pane);
                self.saveState(s);
            };
        }
    }

    /// SIGKILL closed panes that ignored SIGHUP for the grace period.
    fn escalate(self: *Owner) void {
        const now = nowMs();
        for (self.doomed.items) |*d| if (!d.killed and now >= d.deadline) {
            signalGroup(d.pid, c.SIGKILL);
            d.killed = true;
        };
    }

    fn resizePane(pane: *Pane, cols: u16, rows: u16) !void {
        try pane.vt.resize(cols, rows);
        pane.cols = cols;
        pane.rows = rows;
        if (pane.master >= 0) pty.applyResize(pane.master, cols, rows);
    }

    fn closePane(self: *Owner, s: *Session, pane: *Pane) void {
        _ = s;
        if (pane.removed) return;
        pane.removed = true;
        if (pane.status == null) {
            signalGroup(pane.pid, c.SIGHUP);
            self.doomed.append(self.a, .{ .pid = pane.pid, .deadline = nowMs() + termination_grace_ms }) catch signalGroup(pane.pid, c.SIGKILL);
        }
    }

    fn endSession(self: *Owner, s: *Session) void {
        if (s.meta.ended) return;
        // Termination is not an admitted membership edit: shutdown and error
        // cleanup must still kill panes even when revision space is exhausted.
        for (s.panes.items) |pane| self.closePane(s, pane);
        s.meta.ended = true;
        if (s.client) |client| {
            client.session = null;
            self.event(client, .session_end, s, null);
            s.client = null;
        }
        if (self.state_dir) |dir| {
            var path: [std.fs.max_path_bytes]u8 = undefined;
            const file = std.fmt.bufPrintSentinel(&path, "{s}/{s}.json", .{ dir, &s.meta.id }, 0) catch return;
            _ = c.unlink(file.ptr);
        }
    }

    /// Frees removed panes, ended sessions, and dead clients after a round,
    /// so poll slots never point at freed memory.
    fn collect(self: *Owner) void {
        var i: usize = 0;
        while (i < self.sessions.items.len) {
            const s = self.sessions.items[i];
            var j: usize = 0;
            while (j < s.panes.items.len) {
                const pane = s.panes.items[j];
                if (!pane.removed) {
                    j += 1;
                    continue;
                }
                _ = s.panes.orderedRemove(j);
                self.freePane(pane);
            }
            if (s.meta.ended) {
                _ = self.sessions.orderedRemove(i);
                s.panes.deinit(self.a);
                s.meta.deinit(self.a);
                self.a.destroy(s);
            } else i += 1;
        }
        i = 0;
        while (i < self.clients.items.len) {
            const client = self.clients.items[i];
            if (client.dead) {
                _ = self.clients.orderedRemove(i);
                self.freeClient(client);
            } else i += 1;
        }
    }

    fn freePane(self: *Owner, pane: *Pane) void {
        if (pane.master >= 0) _ = c.close(pane.master);
        if (pane.launch >= 0) _ = c.close(pane.launch);
        pane.vt.destroy();
        pane.input.deinit(self.a);
        pane.unsent.deinit(self.a);
        self.a.free(pane.spawn);
        self.a.destroy(pane);
    }

    fn freeClient(self: *Owner, client: *Client) void {
        if (client.session) |s| if (s.client == client) {
            s.client = null;
        };
        _ = c.close(client.fd);
        client.reader.deinit(self.a);
        client.out.deinit(self.a);
        self.a.destroy(client);
    }

    fn drainSignals(self: *Owner) void {
        var si: c.struct_signalfd_siginfo = undefined;
        while (c.read(self.signal_fd, &si, @sizeOf(c.struct_signalfd_siginfo)) == @sizeOf(c.struct_signalfd_siginfo)) {
            if (si.ssi_signo == c.SIGTERM or si.ssi_signo == c.SIGINT) {
                for (self.sessions.items) |s| self.endSession(s);
                self.stop = .kill;
            }
            // SIGCHLD is handled by the reap after every round; SIGHUP is
            // ignored (the owner has no controlling terminal).
        }
    }

    /// Reads `<dir>/host-id`, creating it once. Runs under the owner lock, so
    /// no other owner races the creation. A host ID that cannot be persisted
    /// is not used: clients would mistake every restart for a new host.
    pub fn loadHost(self: *Owner, dir: []const u8) void {
        var path_buf: [4096]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&path_buf, "{s}/host-id", .{dir}, 0) catch return;
        const fd = c.open(path.ptr, c.O_RDONLY | c.O_CLOEXEC | c.O_NOFOLLOW);
        if (fd >= 0) {
            defer _ = c.close(fd);
            var buf: [self.host_buf.len + 1]u8 = undefined;
            const n = c.read(fd, &buf, buf.len);
            if (n == self.host_buf.len) {
                const bytes = buf[0..self.host_buf.len];
                const valid = for (bytes) |byte| {
                    if (!std.ascii.isHex(byte)) break false;
                } else true;
                if (valid) {
                    @memcpy(&self.host_buf, bytes);
                    self.host = &self.host_buf;
                    return;
                }
            }
        }
        var random: [16]u8 = undefined;
        fillRandom(&random) catch return;
        const id = std.fmt.bytesToHex(random, .lower);
        var tmp_buf: [4096]u8 = undefined;
        const tmp = std.fmt.bufPrintSentinel(&tmp_buf, "{s}/host-id.tmp", .{dir}, 0) catch return;
        const out = c.open(tmp.ptr, c.O_WRONLY | c.O_CREAT | c.O_TRUNC | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c_uint, 0o600));
        if (out < 0) return;
        const written = c.write(out, &id, id.len);
        const closed = c.close(out);
        if (written != id.len or closed != 0 or std.c.rename(tmp.ptr, path.ptr) != 0) {
            _ = c.unlink(tmp.ptr);
            return;
        }
        self.host_buf = id;
        self.host = &self.host_buf;
    }

    /// Metadata for crash recovery: layout plus per-pane spawn, title, cwd,
    /// exit. Written atomically on every structural change.
    fn saveState(self: *Owner, s: *Session) void {
        const dir = self.state_dir orelse return;
        if (s.meta.ended) return;
        var arena_state = std.heap.ArenaAllocator.init(self.a);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const PaneState = struct { id: u32, spawn: []const u8, title: []const u8, cwd: []const u8, exit: ?i32 };
        var panes: std.ArrayList(PaneState) = .empty;
        for (s.panes.items) |pane| if (!pane.removed) {
            panes.append(arena, .{ .id = pane.id, .spawn = pane.spawn, .title = pane.vt.title(arena) catch "", .cwd = paneCwd(arena, pane) catch "", .exit = pane.status }) catch return;
        };
        const body = p.stringify(arena, .{ .id = &s.meta.id, .revision = s.meta.revision, .layout = s.meta.layout, .panes = panes.items }) catch return;
        const tmp = std.fmt.allocPrintSentinel(arena, "{s}/{s}.json.tmp", .{ dir, &s.meta.id }, 0) catch return;
        const final = std.fmt.allocPrintSentinel(arena, "{s}/{s}.json", .{ dir, &s.meta.id }, 0) catch return;
        const fd = c.open(tmp.ptr, c.O_WRONLY | c.O_CREAT | c.O_TRUNC | c.O_CLOEXEC, @as(c_uint, 0o600));
        if (fd < 0) return;
        var written: usize = 0;
        while (written < body.len) {
            const n = c.write(fd, body.ptr + written, body.len - written);
            if (n <= 0) {
                if (n < 0 and errno() == c.EINTR) continue;
                _ = c.close(fd);
                _ = c.unlink(tmp.ptr);
                return;
            }
            written += @intCast(n);
        }
        _ = c.close(fd);
        _ = std.c.rename(tmp.ptr, final.ptr);
    }
};

fn livePanes(s: *Session) usize {
    var n: usize = 0;
    for (s.panes.items) |pane| if (!pane.removed) {
        n += 1;
    };
    return n;
}

fn flushInput(pane: *Pane) void {
    while (pane.master >= 0 and pane.input.len() > 0) {
        const bytes = pane.input.slice();
        const n = c.write(pane.master, bytes.ptr, bytes.len);
        if (n < 0) {
            if (errno() == c.EINTR) continue;
            return;
        }
        pane.input.consume(@intCast(n));
    }
}

// ---------------------------------------------------------------------------
// serve

/// Runs the owner in the foreground until its last session ends. `session
/// connect` daemonizes it; running it directly is useful for debugging.
pub fn serve(a: std.mem.Allocator, io: std.Io) !void {
    const paths = try resolvePaths(a);
    defer paths.deinit(a);
    const lock_fd = c.open(paths.lock.ptr, c.O_RDWR | c.O_CREAT | c.O_CLOEXEC, @as(c_uint, 0o600));
    if (lock_fd < 0) return error.LockFailed;
    defer _ = c.close(lock_fd);
    // A second owner (two racing connects) waits briefly for a stopping
    // owner to exit, then gives up quietly if one is still running.
    const lock_deadline = nowMs() + 5000;
    while (c.flock(lock_fd, c.LOCK_EX | c.LOCK_NB) != 0) {
        if (nowMs() >= lock_deadline) return;
        _ = c.poll(null, 0, 20);
    }

    var signals: c.sigset_t = undefined;
    _ = c.sigemptyset(&signals);
    inline for (.{ c.SIGCHLD, c.SIGTERM, c.SIGINT, c.SIGHUP }) |sig| _ = c.sigaddset(&signals, sig);
    if (c.sigprocmask(c.SIG_BLOCK, &signals, null) != 0) return error.SignalSetupFailed;
    const signal_fd = c.signalfd(-1, &signals, c.SFD_CLOEXEC | c.SFD_NONBLOCK);
    if (signal_fd < 0) return error.SignalSetupFailed;
    defer _ = c.close(signal_fd);
    // A handler, not SIG_IGN, so exec restores the default for pane shells.
    _ = c.signal(c.SIGPIPE, ignoreSignal);

    const listen_fd = try listenAt(paths.socket);
    defer {
        _ = c.close(listen_fd);
        _ = c.unlink(paths.socket.ptr);
    }

    var owner = Owner.init(a, io);
    defer owner.deinit();
    owner.listen_fd = listen_fd;
    owner.signal_fd = signal_fd;
    owner.state_dir = stateDir(a) catch null;
    if (owner.state_dir) |dir| owner.loadHost(dir);
    const touch = [_][:0]const u8{ paths.socket, paths.lock };
    owner.touch_paths = &touch;
    owner.touched = nowMs();
    while (!owner.done()) try owner.step(1000);
    // Best effort: let the kill_server reply reach its client.
    for (owner.clients.items) |client| if (!client.dead) owner.flushClient(client);
}

/// Binds the socket under the held lock, replacing any stale file.
pub fn listenAt(path: [:0]const u8) !c_int {
    var addr = std.mem.zeroes(c.struct_sockaddr_un);
    addr.sun_family = c.AF_UNIX;
    if (path.len >= addr.sun_path.len) return error.NameTooLong;
    @memcpy(addr.sun_path[0..path.len], path);
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC | c.SOCK_NONBLOCK, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);
    _ = c.unlink(path.ptr);
    if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) return error.BindFailed;
    _ = c.chmod(path.ptr, 0o600);
    if (c.listen(fd, 64) != 0) return error.ListenFailed;
    return fd;
}

/// Connects to the owner socket; null when no owner is listening.
pub fn connectTo(path: [:0]const u8) !?c_int {
    var addr = std.mem.zeroes(c.struct_sockaddr_un);
    addr.sun_family = c.AF_UNIX;
    if (path.len >= addr.sun_path.len) return error.NameTooLong;
    @memcpy(addr.sun_path[0..path.len], path);
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0);
    if (fd < 0) return error.SocketFailed;
    if (std.c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) == 0) return fd;
    const err = errno();
    _ = c.close(fd);
    if (err == c.ENOENT or err == c.ECONNREFUSED) return null;
    return error.ConnectFailed;
}

// ---------------------------------------------------------------------------
// helpers

/// glibc and musl translate `getenv` with different pointer types.
fn env(name: [*:0]const u8) ?[:0]const u8 {
    const value: ?[*:0]const u8 = @ptrCast(c.getenv(name));
    return if (value) |v| std.mem.span(v) else null;
}

fn signalGroup(pid: c.pid_t, sig: c_int) void {
    _ = c.kill(-pid, sig);
    // Close can race forkpty's child before it has created its process group.
    _ = c.kill(pid, sig);
}

fn setNonBlocking(fd: c_int) void {
    const flags = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    if (flags >= 0) _ = c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK);
}

pub fn fillRandom(out: []u8) !void {
    var count: usize = 0;
    while (count < out.len) {
        const result = std.os.linux.getrandom(out[count..].ptr, out.len - count, 0);
        const err = std.os.linux.errno(result);
        if (err == .INTR) continue;
        if (err != .SUCCESS or result == 0) return error.RandomFailed;
        count += result;
    }
}

fn clampTimeout(current: i32, ms: i64) i32 {
    const bounded: i32 = @intCast(std.math.clamp(ms, 0, std.math.maxInt(i32)));
    return if (current < 0) bounded else @min(current, bounded);
}

fn ignoreSignal(_: c_int) callconv(.c) void {}

fn errno() c_int {
    return c.__errno_location().*;
}

pub fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
