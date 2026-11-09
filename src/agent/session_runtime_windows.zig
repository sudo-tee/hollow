//! Bounded, single-pane Windows owner policy. Transport owns client lifetimes;
//! this module owns processes and VT state, never GUI views or pipe handles.
const std = @import("std");
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
pub const scrollback_bytes = 1024 * 1024;
const input_limit = 4 * 1024 * 1024;
const turn_budget = 256 * 1024;
const exit_linger_ms = 2000;

pub const Client = struct {
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
    backend: *Pane,
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

    fn resetDelivery(self: *Session, a: std.mem.Allocator) void {
        self.stream.detach();
        self.snapshot.deinit(a);
        self.snapshot = .empty;
        self.snapshot_offset = 0;
        self.snapshot_active = false;
    }
};

pub const Owner = struct {
    a: std.mem.Allocator,
    wake: Wake,
    sessions: [max_sessions]*Session = undefined,
    count: usize = 0,

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
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        const temp = arena.allocator();
        switch (req.op) {
            .list => {
                const infos = try temp.alloc(p.SessionInfo, self.count);
                for (self.sessions[0..self.count], infos) |s, *entry| entry.* = try info(temp, s);
                self.control(client, .reply, p.Reply{ .id = req.id, .sessions = infos });
            },
            .create => {
                const s = try self.create(req);
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
                const s = self.find(req.session orelse return error.MissingSession) orelse return error.SessionNotFound;
                self.end(s);
                self.control(client, .reply, p.Reply{ .id = req.id });
            },
            .layout => {
                const s = try attached(client, 1);
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
            .spawn, .close, .respawn => return error.Unsupported,
        }
    }

    fn find(self: *Owner, id: []const u8) ?*Session {
        return core.findSession(self.sessions[0..self.count], id);
    }

    fn create(self: *Owner, req: *const p.Request) !*Session {
        if (self.count == max_sessions) return error.ResourceExhausted;
        const id = if (req.create_id) |reserved| try core.reservedId(reserved) else blk: {
            var random: [16]u8 = undefined;
            std.Io.random(io.get(), &random);
            break :blk core.randomId(random);
        };
        try core.checkCollision(self.sessions[0..self.count], &id);
        const spawn = req.spawn orelse p.Spawn{};
        try validateSpawn(spawn);
        const s = try self.a.create(Session);
        errdefer self.a.destroy(s);
        var meta: core.Metadata = .{ .id = id };
        errdefer meta.deinit(self.a);
        try meta.setInitialLayout(self.a, req.layout orelse "");
        const prepared = try meta.preparePane(false);
        // Copy original cwd before launch, including an omitted cwd's actual
        // inherited Windows directory. VT pwd may later supersede it.
        const cwd = if (spawn.cwd) |value| try self.a.dupeSentinel(u8, value, 0) else try std.process.currentPathAlloc(io.get(), self.a);
        errdefer self.a.free(cwd);
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        var options = try prepareLaunch(arena.allocator(), spawn);
        options.cwd = cwd;
        options.wake = self.wake;
        options.scrollback_bytes = scrollback_bytes;
        const backend = try Pane.create(self.a, options);
        // Nothing fallible follows execution/publication.
        prepared.commit(&meta);
        s.* = .{ .meta = meta, .backend = backend, .cols = spawn.cols, .rows = spawn.rows, .cwd = cwd, .close_on_exit = closeOnExit(spawn) };
        self.sessions[self.count] = s;
        self.count += 1;
        return s;
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
        if (sizes.len > 1) return error.Unsupported;
        for (sizes) |size| {
            if (size.pane != 1) return error.PaneNotFound;
            try validSize(size.cols, size.rows);
        }
        // Materialize the entire reply before takeover. OOM must not evict an
        // existing controller or silently destroy a recoverable created session.
        var session_info = try info(a, s);
        session_info.attached = true;
        for (sizes) |size| {
            const panes = @constCast(session_info.panes);
            panes[0].cols = size.cols;
            panes[0].rows = size.rows;
        }
        const reply = try p.stringify(a, p.Reply{ .id = id, .session = session_info });
        if (reply.len > p.control_limit) return error.ResourceExhausted;
        for (sizes) |size| {
            try s.backend.resize(size.cols, size.rows);
            s.cols = size.cols;
            s.rows = size.rows;
        }
        self.disconnect(client);
        s.resetDelivery(self.a);
        if (attachment.link(client, s)) |old| self.event(old, .taken, s, null);
        s.stream.attach();
        if (!client.send(.reply, 0, reply)) client.dead = true;
    }

    pub fn frame(self: *Owner, client: *Client, kind: p.Kind, stream: u32, bytes: []const u8) !void {
        if (client.dead) return error.Closed;
        const s = try attached(client, stream);
        switch (kind) {
            .input => {
                if (bytes.len > p.max_data) return error.PayloadTooLarge;
                if (s.status != null or s.input_failed) return error.WriteFailed;
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
        s.resetDelivery(self.a);
        s.backend.destroy();
        s.input.deinit(self.a);
        s.stream.deinit(self.a);
        s.meta.deinit(self.a);
        self.a.free(s.cwd);
        self.a.destroy(s);
    }

    /// `now` and deadlines are monotonic milliseconds. Only exhausted work
    /// budgets request another immediate turn; writers/credit/pipe pressure wait
    /// for the shared wake event or another transport frame.
    pub fn tick(self: *Owner, now: u64) bool {
        var more = false;
        var index: usize = 0;
        while (index < self.count) {
            const s = self.sessions[index];
            if (s.client) |client| if (client.dead) self.disconnect(client);
            const immediate = self.tickSession(s, now) catch {
                // Fatal VT/query/read failures cannot yield a trustworthy view.
                // End this session explicitly, rather than inventing process
                // status or spinning forever on a permanently failed backend.
                self.end(s);
                continue;
            };
            more = more or immediate;
            index += 1;
        }
        return more;
    }

    fn tickSession(self: *Owner, s: *Session, now: u64) !bool {
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
            if (s.client != null) s.stream.appendOutput(self.a, buffer[0..n]);
        }
        if (read_budget == 0 and s.backend.pty.hasPendingOutput()) more = true;
        if (s.status == null) if (s.backend.exitStatus()) |status| {
            s.status = wireExit(status);
            s.exit_deadline = now +| exit_linger_ms;
            s.input.clear();
        };
        if (s.status != null and (s.backend.outputEnded() or now >= s.exit_deadline.?)) s.drained = true;

        const client = s.client orelse return more;
        if (client.dead) return more;
        if (!s.snapshot_active and s.stream.requestResync()) self.event(client, .resync, s, 1);
        if (client.dead) return more;
        if (s.stream.startSnapshot()) {
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
            if (!client.send(.snapshot, 1, s.snapshot.items[s.snapshot_offset..][0..n])) return more;
            s.snapshot_offset += n;
            send_budget -= n;
        }
        if (s.snapshot_active) {
            if (s.snapshot_offset != s.snapshot.items.len) return true;
            if (!client.send(.snapshot_end, 1, "")) return more;
            s.snapshot_active = false;
            s.snapshot.deinit(self.a);
            s.snapshot = .empty;
            s.snapshot_offset = 0;
        }
        while (send_budget > 0) {
            const bytes = s.stream.nextOutput();
            if (bytes.len == 0) break;
            const n = @min(bytes.len, send_budget);
            if (!client.send(.output, 1, bytes[0..n])) return more;
            s.stream.consumeOutput(n);
            send_budget -= n;
        }
        if (send_budget == 0 and s.stream.nextOutput().len > 0) more = true;
        // A stale backlog produced while delivering a snapshot can now resync.
        if (s.stream.stale and s.stream.credit == p.window) more = true;
        if (s.status) |status| if (s.stream.exitReady(s.drained)) {
            if (client.send(.exit, 1, &p.encodeExit(status))) s.stream.exit_sent = true;
        };
        return more;
    }

    fn foreground(self: *Owner, s: *Session) !void {
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
            if (s.drained) continue;
            if (s.exit_deadline) |time| result = if (result) |previous| @min(previous, time) else time;
        }
        return result;
    }
};

fn attached(client: *Client, pane: u32) !*Session {
    const s = client.session orelse return error.NotAttached;
    if (s.client != client) return error.NotAttached;
    if (pane != 1) return error.PaneNotFound;
    return s;
}

fn failInput(s: *Session) void {
    s.input_failed = true;
    s.input.clear();
    s.backend.pending_replies.clearRetainingCapacity();
    s.backend.reply_offset = 0;
    s.backend.pending_resize = null;
}

fn info(a: std.mem.Allocator, s: *Session) !p.SessionInfo {
    const panes = try a.alloc(p.PaneInfo, 1);
    const pwd = try s.backend.vt.pwd(a);
    panes[0] = .{
        .id = 1,
        .cols = s.cols,
        .rows = s.rows,
        .title = try s.backend.vt.title(a),
        .cwd = if (windowsPath(pwd)) pwd else s.cwd,
        .foreground_process = if (s.status == null) s.backend.vt.shell_command.value() else "",
        .exit = s.status,
        .close_on_exit = s.close_on_exit,
    };
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
        for (spawn.argv) |arg| try args.append(a, try a.dupe(u8, arg));
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
    if (spawn.command != null or spawn.one_shot) return false;
    if (spawn.argv.len == 0) return true;
    const name = std.fs.path.basenameWindows(spawn.argv[0]);
    const cmd = std.ascii.eqlIgnoreCase(name, "cmd.exe") or std.ascii.eqlIgnoreCase(name, "cmd");
    if (!cmd and !isPowershell(name)) return false;
    for (spawn.argv[1..]) |arg| {
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

test "session capacity rejects before allocation or child creation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var owner = Owner.init(failing.allocator(), .{});
    owner.count = max_sessions;
    try std.testing.expectError(error.ResourceExhausted, owner.create(&.{ .id = 1, .op = .create }));
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(max_sessions, owner.count);
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
    var s: Session = .{ .meta = .{ .id = @splat('a') }, .backend = undefined, .cols = 80, .rows = 24, .cwd = undefined, .close_on_exit = false };
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
    const s = try owner.create(&req);
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
