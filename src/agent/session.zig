//! `hollow-agent session <serve|connect|list|kill-server|wait|debug-attach>`.
//! `connect` is the stdio-to-socket bridge that connectors (ssh, wsl.exe)
//! run; it starts the owner when none is listening. `debug-attach` is a
//! hidden raw-tty client for manual checks, not a public interface.
const std = @import("std");
const p = @import("session_protocol.zig");
const owner = @import("session_posix.zig");
const c = @import("posix_c");

pub const posix = owner;

pub fn run(a: std.mem.Allocator, io: std.Io, args: anytype) !void {
    const command = args.next() orelse return error.InvalidArgument;
    if (std.mem.eql(u8, command, "serve")) return owner.serve(a, io);
    if (std.mem.eql(u8, command, "connect")) return connect(a);
    if (std.mem.eql(u8, command, "list")) return simple(a, .list);
    if (std.mem.eql(u8, command, "kill-server")) return simple(a, .kill_server);
    if (std.mem.eql(u8, command, "wait")) {
        if (args.next() != null) return error.InvalidArgument;
        return @import("session_wait.zig").run(a);
    }
    if (std.mem.eql(u8, command, "debug-attach")) return debugAttach(a, args.next());
    return error.InvalidArgument;
}

/// Connects to the owner, starting it first if no owner is listening.
/// Racing starters are fine: the owner lock lets only one of them serve.
pub fn connectOrStart(a: std.mem.Allocator) !c_int {
    const paths = try owner.resolvePaths(a);
    defer paths.deinit(a);
    if (try owner.connectTo(paths.socket)) |fd| return fd;
    const log = try std.fmt.allocPrintSentinel(a, "{s}/owner.log", .{paths.dir}, 0);
    defer a.free(log);
    try startOwner(log);
    const deadline = owner.nowMs() + 5000;
    while (owner.nowMs() < deadline) {
        if (try owner.connectTo(paths.socket)) |fd| return fd;
        _ = c.poll(null, 0, 10);
    }
    return error.OwnerStartTimeout;
}

/// Double fork with `setsid`, so the owner has no controlling terminal and
/// is reparented away from the connector that started it.
fn startOwner(log: [:0]const u8) !void {
    var exe: [std.fs.max_path_bytes]u8 = undefined;
    const n = c.readlink("/proc/self/exe", &exe, exe.len - 1);
    if (n <= 0) return error.ExePathFailed;
    exe[@intCast(n)] = 0;
    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        _ = c.setsid();
        if (c.fork() != 0) c._exit(0);
        _ = c.chdir("/");
        const null_fd = c.open("/dev/null", c.O_RDWR);
        const log_fd = c.open(log.ptr, c.O_WRONLY | c.O_CREAT | c.O_APPEND, @as(c_uint, 0o600));
        _ = c.dup2(null_fd, 0);
        _ = c.dup2(null_fd, 1);
        _ = c.dup2(if (log_fd >= 0) log_fd else null_fd, 2);
        _ = std.os.linux.close_range(3, std.math.maxInt(c_int), .{ .UNSHARE = false, .CLOEXEC = false });
        var empty: c.sigset_t = undefined;
        _ = c.sigemptyset(&empty);
        _ = c.sigprocmask(c.SIG_SETMASK, &empty, null);
        const argv = [_:null]?[*:0]const u8{ @ptrCast(&exe), "session", "serve" };
        _ = c.execv(@ptrCast(&exe), @ptrCast(&argv));
        c._exit(127);
    }
    _ = c.waitpid(pid, null, 0);
}

fn connect(a: std.mem.Allocator) !void {
    const fd = try connectOrStart(a);
    defer _ = c.close(fd);
    _ = c.signal(c.SIGPIPE, ignoreSignal);
    var buf: [64 * 1024]u8 = undefined;
    var fds = [_]c.struct_pollfd{ .{ .fd = 0, .events = c.POLLIN, .revents = 0 }, .{ .fd = fd, .events = c.POLLIN, .revents = 0 } };
    while (true) {
        if (c.poll(&fds, fds.len, -1) < 0) {
            if (errno() == c.EINTR) continue;
            return error.PollFailed;
        }
        if (fds[0].revents != 0) {
            const n = c.read(0, &buf, buf.len);
            if (n <= 0) return;
            writeAll(fd, buf[0..@intCast(n)]) catch return;
        }
        if (fds[1].revents != 0) {
            const n = c.read(fd, &buf, buf.len);
            if (n <= 0) return;
            writeAll(1, buf[0..@intCast(n)]) catch return;
        }
    }
}

/// Blocking framed connection for the small built-in clients.
const Conn = struct {
    a: std.mem.Allocator,
    fd: c_int,
    reader: p.Reader = .{},
    next_id: u64 = 1,

    fn deinit(self: *Conn) void {
        self.reader.deinit(self.a);
        _ = c.close(self.fd);
    }

    fn send(self: *Conn, kind: p.Kind, stream: u32, payload: []const u8) !void {
        try writeAll(self.fd, &p.header(kind, stream, payload.len).encode());
        try writeAll(self.fd, payload);
    }

    fn sendJson(self: *Conn, kind: p.Kind, value: anytype) !void {
        const body = try p.stringify(self.a, value);
        defer self.a.free(body);
        try self.send(kind, 0, body);
    }

    fn request(self: *Conn, req: p.Request) !u64 {
        var copy = req;
        copy.id = self.next_id;
        self.next_id += 1;
        try self.sendJson(.request, copy);
        return copy.id;
    }

    /// Returns the next buffered frame without blocking.
    fn poll(self: *Conn) !?Frame {
        const frame = (try self.reader.next()) orelse return null;
        return .{ .kind = try p.validate(frame.header, .to_client), .stream = frame.header.stream, .payload = frame.payload };
    }

    /// Reads once from the socket; false on EOF.
    fn fill(self: *Conn) !bool {
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const n = c.read(self.fd, &buf, buf.len);
            if (n < 0 and errno() == c.EINTR) continue;
            if (n < 0) return error.ReadFailed;
            if (n == 0) return false;
            try self.reader.push(self.a, buf[0..@intCast(n)]);
            return true;
        }
    }

    /// Blocks for the next frame. Its payload is valid until the next call.
    fn next(self: *Conn) !Frame {
        while (true) {
            if (try self.poll()) |frame| return frame;
            if (!try self.fill()) return error.EndOfStream;
        }
    }

    fn hello(self: *Conn, ghostty: []const u8) !p.SnapshotFormat {
        try self.sendJson(.hello, p.Hello{ .protocol = p.protocol, .version = p.version, .ghostty = ghostty, .client = "hollow-agent" });
        const frame = try self.next();
        if (frame.kind != .welcome) {
            try writeAll(2, frame.payload);
            return error.HelloRejected;
        }
        const welcome = try p.parse(p.Welcome, self.a, frame.payload);
        defer welcome.deinit();
        return welcome.value.snapshot;
    }

    /// Waits for the reply to `id`, skipping anything else.
    fn awaitReply(self: *Conn, id: u64) !std.json.Parsed(p.Reply) {
        while (true) {
            const frame = try self.next();
            if (frame.kind != .reply) continue;
            const parsed = try p.parse(p.Reply, self.a, frame.payload);
            if (parsed.value.id == id or parsed.value.id == 0) return parsed;
            parsed.deinit();
        }
    }
};

const Frame = struct { kind: p.Kind, stream: u32, payload: []const u8 };

/// `list` / `kill-server`: prints the reply JSON. Neither starts an owner.
fn simple(a: std.mem.Allocator, op: p.Op) !void {
    const paths = try owner.resolvePaths(a);
    defer paths.deinit(a);
    const fd = (try owner.connectTo(paths.socket)) orelse {
        try writeAll(1, if (op == .list) "{\"id\":1,\"ok\":true,\"sessions\":[]}\n" else "{\"id\":1,\"ok\":true}\n");
        return;
    };
    var conn: Conn = .{ .a = a, .fd = fd };
    defer conn.deinit();
    _ = try conn.hello("cli");
    const id = try conn.request(.{ .id = 0, .op = op });
    while (true) {
        const frame = try conn.next();
        if (frame.kind != .reply) continue;
        const parsed = try p.parse(p.Reply, a, frame.payload);
        defer parsed.deinit();
        if (parsed.value.id != id) continue;
        try writeAll(1, frame.payload);
        try writeAll(1, "\n");
        if (!parsed.value.ok) return error.RequestFailed;
        return;
    }
}

const detach_key = 0x1c; // Ctrl-\

/// Raw-tty client for manual checks: shows the first pane, forwards input,
/// detaches on Ctrl-\. Uses VT formatter snapshots (a deliberately foreign
/// ghostty identity), which replay directly onto the real terminal.
fn debugAttach(a: std.mem.Allocator, session_id: ?[]const u8) !void {
    var conn: Conn = .{ .a = a, .fd = try connectOrStart(a) };
    defer conn.deinit();
    _ = try conn.hello("debug-attach");
    var ws = std.mem.zeroes(c.struct_winsize);
    if (c.ioctl(0, c.TIOCGWINSZ, &ws) != 0 or ws.ws_col == 0) {
        ws.ws_col = 80;
        ws.ws_row = 24;
    }

    var id: u64 = 0;
    if (session_id) |sid| {
        const list_id = try conn.request(.{ .id = 0, .op = .list });
        const listed = try conn.awaitReply(list_id);
        defer listed.deinit();
        var first: ?u32 = null;
        for (listed.value.sessions orelse &.{}) |s| if (std.mem.eql(u8, s.id, sid) and s.panes.len > 0) {
            first = s.panes[0].id;
        };
        const sizes = [_]p.PaneSize{.{ .pane = first orelse 0, .cols = ws.ws_col, .rows = ws.ws_row }};
        id = try conn.request(.{ .id = 0, .op = .attach, .session = sid, .panes = if (first != null) &sizes else &.{} });
    } else {
        id = try conn.request(.{ .id = 0, .op = .create, .spawn = .{ .cols = ws.ws_col, .rows = ws.ws_row } });
    }
    const attached = try conn.awaitReply(id);
    defer attached.deinit();
    if (!attached.value.ok) {
        printErr("hollow-agent: attach failed: {s}\n", .{attached.value.@"error" orelse "unknown"});
        return error.RequestFailed;
    }
    const info = attached.value.session orelse return error.InvalidReply;
    if (info.panes.len == 0) return error.InvalidReply;
    const pane = info.panes[0].id;
    var sid_buf: [64]u8 = undefined;
    const sid = sid_buf[0..@min(info.id.len, sid_buf.len)];
    @memcpy(sid, info.id[0..sid.len]);

    var saved: c.struct_termios = undefined;
    const tty = c.tcgetattr(0, &saved) == 0;
    if (tty) {
        var raw = saved;
        c.cfmakeraw(&raw);
        _ = c.tcsetattr(0, c.TCSANOW, &raw);
    }
    defer if (tty) {
        _ = c.tcsetattr(0, c.TCSANOW, &saved);
    };
    var signals: c.sigset_t = undefined;
    _ = c.sigemptyset(&signals);
    _ = c.sigaddset(&signals, c.SIGWINCH);
    _ = c.sigprocmask(c.SIG_BLOCK, &signals, null);
    const winch = c.signalfd(-1, &signals, c.SFD_CLOEXEC | c.SFD_NONBLOCK);
    defer if (winch >= 0) {
        _ = c.close(winch);
    };

    try writeAll(1, "\x1b[H\x1b[2J\x1b[3J");
    var reason: []const u8 = "detached";
    var fds = [_]c.struct_pollfd{
        .{ .fd = 0, .events = c.POLLIN, .revents = 0 },
        .{ .fd = conn.fd, .events = c.POLLIN, .revents = 0 },
        .{ .fd = winch, .events = c.POLLIN, .revents = 0 },
    };
    loop: while (true) {
        while (try conn.poll()) |frame| {
            if (frame.stream != 0 and frame.stream != pane) continue;
            switch (frame.kind) {
                .snapshot => try writeAll(1, frame.payload),
                .output => {
                    try writeAll(1, frame.payload);
                    if (frame.payload.len > 0) {
                        var grant: [4]u8 = undefined;
                        std.mem.writeInt(u32, &grant, @intCast(frame.payload.len), .little);
                        try conn.send(.credit, pane, &grant);
                    }
                },
                .exit => {
                    var msg: [96]u8 = undefined;
                    try writeAll(1, try std.fmt.bufPrint(&msg, "\r\n[pane exited: {d}; Ctrl-\\ to quit]\r\n", .{try p.decodeExit(frame.payload)}));
                },
                .event => {
                    const ev = try p.parse(p.Event, a, frame.payload);
                    defer ev.deinit();
                    switch (ev.value.event) {
                        .taken => {
                            reason = "taken over by another client";
                            break :loop;
                        },
                        .session_end => {
                            reason = "session ended";
                            break :loop;
                        },
                        .resync => try writeAll(1, "\x1b[H\x1b[2J\x1b[3J"),
                    }
                },
                else => {},
            }
        }
        if (c.poll(&fds, fds.len, -1) < 0) {
            if (errno() == c.EINTR) continue;
            return error.PollFailed;
        }
        if (fds[1].revents != 0 and !try conn.fill()) {
            reason = "owner closed the connection";
            break;
        }
        if (fds[2].revents != 0) {
            var si: c.struct_signalfd_siginfo = undefined;
            while (c.read(winch, &si, @sizeOf(c.struct_signalfd_siginfo)) > 0) {}
            if (c.ioctl(0, c.TIOCGWINSZ, &ws) == 0 and ws.ws_col > 0) try conn.send(.resize, pane, &p.encodeResize(ws.ws_col, ws.ws_row));
        }
        if (fds[0].revents != 0) {
            var buf: [p.max_data]u8 = undefined;
            const n = c.read(0, &buf, buf.len);
            if (n <= 0) break;
            const bytes = buf[0..@intCast(n)];
            if (std.mem.indexOfScalar(u8, bytes, detach_key)) |at| {
                if (at > 0) try conn.send(.input, pane, bytes[0..at]);
                _ = try conn.request(.{ .id = 0, .op = .detach });
                break;
            }
            try conn.send(.input, pane, bytes);
        }
    }
    if (tty) _ = c.tcsetattr(0, c.TCSANOW, &saved);
    printErr("\r\n[{s}: session {s}]\r\n", .{ reason, sid });
}

fn printErr(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    writeAll(2, std.fmt.bufPrint(&buf, fmt, args) catch return) catch {};
}

fn writeAll(fd: c_int, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = c.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (n < 0) {
            if (errno() == c.EINTR) continue;
            if (errno() == c.EAGAIN) {
                var fds = [_]c.struct_pollfd{.{ .fd = fd, .events = c.POLLOUT, .revents = 0 }};
                _ = c.poll(&fds, 1, -1);
                continue;
            }
            return error.WriteFailed;
        }
        offset += @intCast(n);
    }
}

fn ignoreSignal(_: c_int) callconv(.c) void {}

fn errno() c_int {
    return c.__errno_location().*;
}
