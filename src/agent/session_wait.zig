//! Read-only guest lifetime watcher for an owner-held WSL console connection.
//! Uses only v1 hello/list; never starts an owner or acquires an attachment.
const std = @import("std");
const c = @import("posix_c");
const p = @import("session_protocol.zig");
const owner = @import("session_posix.zig");

const startup_ms = 30_000;
const exchange_ms = 5_000;
const interval_ms = 1000;
const retry_ms = 250;

pub fn run(a: std.mem.Allocator) !void {
    const paths = try owner.resolvePaths(a);
    defer paths.deinit(a);
    return runAt(a, paths.socket, owner.nowMs() + startup_ms);
}

fn runAt(a: std.mem.Allocator, path: [:0]const u8, startup_deadline: i64) !void {
    const fd = while (true) {
        if (try connect(path)) |fd| break fd;
        const remaining = startup_deadline - owner.nowMs();
        if (remaining <= 0) return;
        try wait(null, @intCast(@min(remaining, retry_ms)));
    };
    defer _ = c.close(fd);
    var monitor = try Monitor.init(a, fd, owner.nowMs(), startup_deadline);
    defer monitor.deinit();
    while (!try monitor.step(owner.nowMs())) {
        var pollfd: c.struct_pollfd = .{
            .fd = fd,
            .events = @intCast(c.POLLIN | (if (monitor.sent < monitor.out_len) c.POLLOUT else @as(c_int, 0))),
            .revents = 0,
        };
        try wait(&pollfd, @intCast(@min(@max(monitor.deadline - owner.nowMs(), 0), exchange_ms)));
    }
}

// Blocking connectTo is unsuitable here: a full listen backlog must not hold a
// Windows keepalive forever. AF_UNIX EAGAIN means retry with a new socket.
pub fn connect(path: [:0]const u8) !?c_int {
    var addr = std.mem.zeroes(c.struct_sockaddr_un);
    addr.sun_family = c.AF_UNIX;
    if (path.len >= addr.sun_path.len) return error.NameTooLong;
    @memcpy(addr.sun_path[0..path.len], path);
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC | c.SOCK_NONBLOCK, 0);
    if (fd < 0) return error.SocketFailed;
    if (std.c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) == 0) return fd;
    const err = errno();
    _ = c.close(fd);
    if (err == c.ENOENT or err == c.ECONNREFUSED or err == c.EAGAIN) return null;
    return error.ConnectFailed;
}

fn wait(fd: ?*c.struct_pollfd, timeout: c_int) !void {
    if (c.poll(if (fd) |value| value else null, if (fd == null) 0 else 1, timeout) < 0 and errno() != c.EINTR)
        return error.PollFailed;
}

/// Nonblocking monitor; the caller owns the socket and polls `deadline` and
/// POLLIN/POLLOUT. Bounded turns also permit in-process real-owner fixtures.
pub const Monitor = struct {
    a: std.mem.Allocator,
    fd: c_int,
    reader: p.Reader = .{},
    out: [512]u8 = undefined,
    out_len: usize = 0,
    sent: usize = 0,
    phase: enum { welcome, reply, idle, done } = .welcome,
    deadline: i64,
    startup_deadline: i64,
    seen_sessions: bool = false,
    request_id: u64 = 0,
    drain: bool = false,

    pub fn init(a: std.mem.Allocator, fd: c_int, now: i64, startup_deadline: i64) !Monitor {
        return initMode(a, fd, now, startup_deadline, false);
    }

    pub fn initMode(a: std.mem.Allocator, fd: c_int, now: i64, startup_deadline: i64, drain: bool) !Monitor {
        var self: Monitor = .{ .a = a, .fd = fd, .deadline = now + exchange_ms, .startup_deadline = startup_deadline, .drain = drain };
        try self.queue(.hello, p.Hello{ .protocol = p.protocol, .version = p.version, .ghostty = "session-wait", .client = "hollow-agent-session-wait", .owner_drain = drain });
        return self;
    }

    pub fn deinit(self: *Monitor) void {
        self.reader.deinit(self.a);
    }

    fn queue(self: *Monitor, kind: p.Kind, value: anytype) !void {
        if (self.sent != self.out_len) return error.InvalidState;
        const bytes = try p.stringify(self.a, value);
        defer self.a.free(bytes);
        if (bytes.len > self.out.len - p.header_len) return error.ResourceExhausted;
        @memcpy(self.out[0..p.header_len], &p.header(kind, 0, bytes.len).encode());
        @memcpy(self.out[p.header_len..][0..bytes.len], bytes);
        self.out_len = p.header_len + bytes.len;
        self.sent = 0;
    }

    fn list(self: *Monitor, now: i64) !void {
        if (self.request_id == std.math.maxInt(u64)) return error.ResourceExhausted;
        self.request_id += 1;
        try self.queue(.request, p.Request{ .id = self.request_id, .op = .list });
        self.phase = .reply;
        self.deadline = now + exchange_ms;
    }

    fn frame(self: *Monitor, kind: p.Kind, bytes: []const u8, now: i64) !void {
        switch (self.phase) {
            .welcome => {
                if (kind != .welcome) return error.ExpectedWelcome;
                const parsed = try p.parse(p.Welcome, self.a, bytes);
                defer parsed.deinit();
                if (!std.mem.eql(u8, parsed.value.protocol, p.protocol) or parsed.value.version != p.version) return error.ProtocolMismatch;
                if (self.drain) {
                    if (!p.hasFeature(parsed.value.features, "drain-empty")) return error.DrainUnsupported;
                    if (parsed.value.retiring) {
                        self.phase = .done;
                        return;
                    }
                }
                try self.list(now);
            },
            .reply => {
                if (kind != .reply) return error.InvalidReply;
                const parsed = try p.parse(p.Reply, self.a, bytes);
                defer parsed.deinit();
                const reply = parsed.value;
                if (self.drain and reply.id == self.request_id and !reply.ok and
                    std.mem.eql(u8, reply.@"error" orelse "", "OwnerRetiring"))
                {
                    self.phase = .done;
                    return;
                }
                if (reply.id != self.request_id or !reply.ok) return error.InvalidReply;
                const sessions = reply.sessions orelse return error.InvalidReply;
                if (sessions.len > 0) {
                    self.seen_sessions = true;
                } else if (!self.drain and (self.seen_sessions or now >= self.startup_deadline)) {
                    self.phase = .done;
                    return;
                }
                self.phase = .idle;
                self.deadline = if (self.seen_sessions) now + interval_ms else @min(now + interval_ms, self.startup_deadline);
            },
            else => return error.UnexpectedFrame,
        }
    }

    pub fn step(self: *Monitor, now: i64) !bool {
        if (self.phase == .done) return true;
        if (self.phase == .idle and now >= self.deadline) try self.list(now);
        if (now >= self.deadline) return error.Timeout;
        if (self.sent < self.out_len) {
            // MSG_NOSIGNAL avoids changing process-wide signal disposition.
            const n = c.send(self.fd, self.out[self.sent..self.out_len].ptr, self.out_len - self.sent, c.MSG_DONTWAIT | c.MSG_NOSIGNAL);
            if (n > 0) self.sent += @intCast(n) else if (n == 0) return error.EndOfStream else if (errno() != c.EAGAIN and errno() != c.EINTR) return error.WriteFailed;
        }
        // One bounded read per turn. Validate even incomplete frame headers
        // before buffering their claimed payload, including foreign kinds.
        var buffer: [16 * 1024]u8 = undefined;
        const n = c.recv(self.fd, &buffer, buffer.len, c.MSG_DONTWAIT);
        if (n == 0) return error.EndOfStream;
        if (n < 0) {
            if (errno() != c.EAGAIN and errno() != c.EINTR) return error.ReadFailed;
        } else {
            if (self.reader.buffered() + @as(usize, @intCast(n)) > p.control_limit + p.header_len + buffer.len) return error.ResourceExhausted;
            try self.reader.push(self.a, buffer[0..@intCast(n)]);
        }
        var frames: usize = 0;
        while (self.reader.buffered() >= p.header_len) {
            const header = try p.Header.decode(self.reader.buffer.items[self.reader.start..][0..p.header_len]);
            const kind = try p.validate(header, .to_client);
            if (kind != .welcome and kind != .reply) return error.UnexpectedFrame;
            const next = (try self.reader.next()) orelse break;
            try self.frame(kind, next.payload, now);
            frames += 1;
            if (frames > 2 or self.phase == .done) break;
        }
        return self.phase == .done;
    }
};

fn errno() c_int {
    return c.__errno_location().*;
}

const Fixture = struct {
    pair: [2]c_int,
    monitor: Monitor,

    fn init() !Fixture {
        return initWithAllocator(std.testing.allocator);
    }

    fn initWithAllocator(a: std.mem.Allocator) !Fixture {
        var pair: [2]c_int = undefined;
        if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC | c.SOCK_NONBLOCK, 0, &pair) != 0) return error.SocketFailed;
        errdefer for (pair) |fd| {
            _ = c.close(fd);
        };
        return .{ .pair = pair, .monitor = try Monitor.init(a, pair[0], 0, startup_ms) };
    }

    fn deinit(self: *Fixture) void {
        self.monitor.deinit();
        for (self.pair) |fd| {
            _ = c.close(fd);
        }
    }

    fn send(self: *Fixture, kind: p.Kind, value: anytype) !void {
        const bytes = try p.stringify(std.testing.allocator, value);
        defer std.testing.allocator.free(bytes);
        const header = p.header(kind, 0, bytes.len).encode();
        try std.testing.expectEqual(@as(isize, header.len), c.write(self.pair[1], &header, header.len));
        try std.testing.expectEqual(@as(isize, @intCast(bytes.len)), c.write(self.pair[1], bytes.ptr, bytes.len));
    }

    fn hello(self: *Fixture) !void {
        try std.testing.expect(!try self.monitor.step(0));
        try self.send(.welcome, p.Welcome{ .ghostty = "fixture", .snapshot = .vt, .owner_pid = 1 });
        try std.testing.expect(!try self.monitor.step(0));
        try std.testing.expect(!try self.monitor.step(0));
    }
};

test "session wait tolerates pre-create emptiness but ends after the last session" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.hello();
    try fixture.send(.reply, p.Reply{ .id = 1, .sessions = &.{} });
    try std.testing.expect(!try fixture.monitor.step(0));
    try std.testing.expect(!fixture.monitor.seen_sessions);
    try std.testing.expect(!try fixture.monitor.step(interval_ms));
    try fixture.send(.reply, p.Reply{ .id = 2, .sessions = &.{.{ .id = "kept", .attached = false, .revision = 0 }} });
    try std.testing.expect(!try fixture.monitor.step(interval_ms));
    try std.testing.expect(fixture.monitor.seen_sessions);
    // The startup deadline no longer applies once sessions exist.
    try std.testing.expect(!try fixture.monitor.step(startup_ms + 1));
    try fixture.send(.reply, p.Reply{ .id = 3, .sessions = &.{} });
    try std.testing.expect(try fixture.monitor.step(startup_ms + 1));
}

test "guest drain requires atomic retirement rather than an empty list" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.monitor.drain = true;
    fixture.monitor.startup_deadline = 0;
    try std.testing.expect(!try fixture.monitor.step(0));
    try fixture.send(.welcome, p.Welcome{ .ghostty = "fixture", .snapshot = .vt, .owner_pid = 1, .features = &p.owner_features });
    try std.testing.expect(!try fixture.monitor.step(0));
    try std.testing.expect(!try fixture.monitor.step(0));
    try fixture.send(.reply, p.Reply{ .id = 1, .sessions = &.{} });
    try std.testing.expect(!try fixture.monitor.step(0));
    try std.testing.expect(!try fixture.monitor.step(interval_ms));
    try fixture.send(.reply, p.Reply{ .id = 2, .ok = false, .@"error" = "OwnerRetiring" });
    try std.testing.expect(try fixture.monitor.step(interval_ms));
}

test "guest drain accepts retiring welcome and fails closed with legacy guests" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.monitor.drain = true;
    try std.testing.expect(!try fixture.monitor.step(0));
    try fixture.send(.welcome, p.Welcome{ .ghostty = "fixture", .snapshot = .vt, .owner_pid = 1, .retiring = true });
    try std.testing.expectError(error.DrainUnsupported, fixture.monitor.step(0));
    try fixture.send(.welcome, p.Welcome{ .ghostty = "fixture", .snapshot = .vt, .owner_pid = 1, .features = &p.owner_features, .retiring = true });
    try std.testing.expect(try fixture.monitor.step(0));
}

test "session wait bounds initial emptiness and checks once more at the deadline" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.hello();
    try fixture.send(.reply, p.Reply{ .id = 1, .sessions = &.{} });
    try std.testing.expect(!try fixture.monitor.step(0));
    try std.testing.expect(!try fixture.monitor.step(startup_ms - 1));
    try fixture.send(.reply, p.Reply{ .id = 2, .sessions = &.{} });
    try std.testing.expect(!try fixture.monitor.step(startup_ms - 1));
    try std.testing.expect(!try fixture.monitor.step(startup_ms));
    try fixture.send(.reply, p.Reply{ .id = 3, .sessions = &.{} });
    try std.testing.expect(try fixture.monitor.step(startup_ms));
}

test "session wait handshake and partial replies have absolute deadlines" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try std.testing.expectError(error.Timeout, fixture.monitor.step(exchange_ms));
    try fixture.hello();
    const header = p.header(.reply, 0, 100).encode();
    try std.testing.expectEqual(@as(isize, header.len), c.write(fixture.pair[1], &header, header.len));
    try std.testing.expect(!try fixture.monitor.step(exchange_ms - 1));
    try std.testing.expectError(error.Timeout, fixture.monitor.step(exchange_ms));
}

test "session wait rejects oversized control before receiving the payload" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const header = p.header(.welcome, 0, p.control_limit + 1).encode();
    try std.testing.expectEqual(@as(isize, header.len), c.write(fixture.pair[1], &header, header.len));
    try std.testing.expectError(error.PayloadTooLarge, fixture.monitor.step(0));
}

test "session wait never follows an unrelated reply or reconnects after EOF" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.hello();
    try fixture.send(.reply, p.Reply{ .id = 2, .sessions = &.{} });
    try std.testing.expectError(error.InvalidReply, fixture.monitor.step(0));
    _ = c.shutdown(fixture.pair[1], c.SHUT_RDWR);
    try std.testing.expectError(error.EndOfStream, fixture.monitor.step(1));
}

test "session wait rejects foreign protocol and unsuccessful or incomplete lists" {
    var foreign = try Fixture.init();
    defer foreign.deinit();
    try std.testing.expect(!try foreign.monitor.step(0));
    try foreign.send(.welcome, p.Welcome{ .version = p.version + 1, .ghostty = "fixture", .snapshot = .vt, .owner_pid = 1 });
    try std.testing.expectError(error.ProtocolMismatch, foreign.monitor.step(0));
    for ([_]p.Reply{ .{ .id = 1 }, .{ .id = 1, .ok = false, .@"error" = "ResourceExhausted" } }) |reply| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        try fixture.hello();
        try fixture.send(.reply, reply);
        try std.testing.expectError(error.InvalidReply, fixture.monitor.step(0));
    }
}

test "session wait rejects pane delivery and cannot wrap query identity" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.hello();
    const header = p.header(.output, 1, 100).encode();
    try std.testing.expectEqual(@as(isize, header.len), c.write(fixture.pair[1], &header, header.len));
    try std.testing.expectError(error.UnexpectedFrame, fixture.monitor.step(0));
    fixture.monitor.phase = .idle;
    fixture.monitor.request_id = std.math.maxInt(u64);
    try std.testing.expectError(error.ResourceExhausted, fixture.monitor.step(exchange_ms));
}

test "session wait observes a session created at the startup deadline" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.hello();
    try fixture.send(.reply, p.Reply{ .id = 1, .sessions = &.{} });
    try std.testing.expect(!try fixture.monitor.step(0));
    try std.testing.expect(!try fixture.monitor.step(startup_ms));
    try fixture.send(.reply, p.Reply{ .id = 2, .sessions = &.{.{ .id = "late", .attached = false, .revision = 0 }} });
    try std.testing.expect(!try fixture.monitor.step(startup_ms));
    try std.testing.expect(fixture.monitor.seen_sessions);
}

test "session wait peer close does not raise SIGPIPE or retry the hello" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    _ = c.shutdown(fixture.pair[1], c.SHUT_RDWR);
    try std.testing.expectError(error.WriteFailed, fixture.monitor.step(0));
    try std.testing.expectEqual(@as(usize, 0), fixture.monitor.sent);
}

test "session wait missing endpoint times out without starting an owner" {
    // A fresh private directory, not the user's session path or environment.
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const path = try dir.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const socket = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/absent.sock", .{path}, 0);
    defer std.testing.allocator.free(socket);
    try runAt(std.testing.allocator, socket, owner.nowMs() + 10);
    try std.testing.expectEqual(@as(?c_int, null), try connect(socket));
}

test "session wait allocation failures release protocol and parser state" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationLifecycle, .{});
}

fn allocationLifecycle(a: std.mem.Allocator) !void {
    var fixture = try Fixture.initWithAllocator(a);
    defer fixture.deinit();
    try fixture.hello();
    try fixture.send(.reply, p.Reply{ .id = 1, .sessions = &.{.{ .id = "kept", .attached = false, .revision = 0 }} });
    try std.testing.expect(!try fixture.monitor.step(0));
    try std.testing.expect(!try fixture.monitor.step(interval_ms));
    try fixture.send(.reply, p.Reply{ .id = 2, .sessions = &.{} });
    try std.testing.expect(try fixture.monitor.step(interval_ms));
}
