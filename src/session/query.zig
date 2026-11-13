//! Single-use owner list/kill over a borrowed bridge. Never attaches and never
//! replays: a lost kill reply stays `uncertain` for the caller to re-list.
const std = @import("std");
const transport = @import("transport.zig");
const open = @import("open.zig");
const p = transport.p;
const Allocator = std.mem.Allocator;

pub const Op = enum { list, kill };
pub const Failure = open.Failure;
pub const Reply = open.Attachment;
pub const Step = union(enum) { pending, done: Reply, failed: Failure };

pub const Query = struct {
    allocator: Allocator,
    op: Op,
    session: ?[]u8,
    connection: ?*transport.Connection = null,
    request_id: ?u64 = null,
    finished: bool = false,
    failure: ?Failure = null,
    remote: ?[]u8 = null,

    pub fn init(a: Allocator, op: Op, session: ?[]const u8) !Query {
        if ((op == .kill) != (session != null)) return error.InvalidRequest;
        if (session) |id| if (id.len == 0 or id.len > 128 or std.mem.indexOfScalar(u8, id, 0) != null) return error.InvalidSessionId;
        return .{ .allocator = a, .op = op, .session = if (session) |id| try a.dupe(u8, id) else null };
    }

    pub fn bind(self: *Query, connection: *transport.Connection) void {
        std.debug.assert(self.connection == null and !self.finished);
        self.connection = connection;
    }

    /// Failures, including OOM, are reported exactly once through Step.failed.
    pub fn step(self: *Query) Step {
        if (self.finished or self.connection == null) return .pending;
        return self.advance() catch |err| .{ .failed = self.fail(err, self.outcome()) };
    }

    fn advance(self: *Query) !Step {
        const connection = self.connection.?;
        const status = connection.status();
        if (status.phase == .connecting) return .pending;
        if (status.phase == .closing or status.phase == .ended)
            return .{ .failed = self.fail(status.failure orelse error.Disconnected, self.outcome()) };
        if (self.request_id == null) self.request_id = try connection.request(switch (self.op) {
            .list => .{ .id = 0, .op = .list },
            .kill => .{ .id = 0, .op = .kill, .session = self.session.? },
        });
        for (0..2) |_| {
            const message = connection.poll() orelse return .pending;
            var transferred = false;
            defer if (!transferred) message.deinit();
            if (message.kind == .welcome) continue;
            if (message.kind != .reply or message.request_id != self.request_id) return error.InvalidReply;
            const parsed = try p.parse(p.Reply, self.allocator, message.payload);
            errdefer parsed.deinit();
            if (parsed.value.id != self.request_id.?) return error.InvalidReply;
            if (!parsed.value.ok) {
                defer parsed.deinit();
                if (parsed.value.@"error") |text| self.remote = try self.allocator.dupe(u8, text);
                return .{ .failed = self.fail(error.Rejected, .rejected) };
            }
            if (self.op == .list and parsed.value.sessions == null) return error.InvalidReply;
            self.finished = true;
            transferred = true;
            return .{ .done = .{ .message = message, .reply = parsed } };
        }
        return .pending;
    }

    fn outcome(self: *Query) open.Outcome {
        const id = self.request_id orelse return .not_sent;
        return switch (self.connection.?.requestState(id)) {
            .queued, .not_sent => .not_sent,
            else => .uncertain,
        };
    }

    fn fail(self: *Query, reason: anyerror, result: open.Outcome) Failure {
        const failure: Failure = .{ .reason = reason, .outcome = result, .remote = self.remote };
        self.finished = true;
        self.failure = failure;
        if (self.connection) |connection| connection.close();
        return failure;
    }

    pub fn cancel(self: *Query) Failure {
        if (self.failure) |failure| return failure;
        if (self.finished) return .{ .reason = error.Canceled, .outcome = .uncertain };
        if (self.connection) |connection| connection.close();
        return self.fail(error.Canceled, self.outcome());
    }

    /// No connection access: its owner retires the bridge independently.
    pub fn deinit(self: *Query) void {
        if (self.session) |id| self.allocator.free(id);
        if (self.remote) |text| self.allocator.free(text);
        self.* = undefined;
    }
};

fn mockConnection() transport.Connection {
    return .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .arena = .init(std.testing.allocator),
        .options = .{ .ghostty_identity = "query-test" },
        .client = .{ .allocator = std.testing.allocator, .identity = "query-test" },
    };
}

fn mockDeinit(connection: *transport.Connection) void {
    connection.client.deinit();
    connection.arena.deinit();
}

fn welcome(connection: *transport.Connection) !void {
    const body = try p.stringify(std.testing.allocator, p.Welcome{ .ghostty = "query-test", .snapshot = .binary, .owner_pid = 1 });
    defer std.testing.allocator.free(body);
    try connection.client.receive(p.header(.welcome, 0, body.len), body);
}

fn submitted(connection: *transport.Connection) !std.json.Parsed(p.Request) {
    const message = connection.client.nextWrite() orelse return error.MissingRequest;
    defer message.deinit();
    try std.testing.expectEqual(p.Kind.request, message.kind);
    return std.json.parseFromSlice(p.Request, std.testing.allocator, message.payload, .{ .allocate = .alloc_always });
}

fn reply(connection: *transport.Connection, value: p.Reply) !void {
    const body = try p.stringify(std.testing.allocator, value);
    defer std.testing.allocator.free(body);
    try connection.client.receive(p.header(.reply, 0, body.len), body);
}

test "session pane query lists without attaching and stops at the reply" {
    var connection = mockConnection();
    defer mockDeinit(&connection);
    var query = try Query.init(std.testing.allocator, .list, null);
    defer query.deinit();
    try std.testing.expect(query.step() == .pending);
    query.bind(&connection);
    try welcome(&connection);
    try std.testing.expect(query.step() == .pending);
    const request = try submitted(&connection);
    defer request.deinit();
    try std.testing.expectEqual(p.Op.list, request.value.op);
    try std.testing.expect(request.value.session == null);
    try reply(&connection, .{ .id = query.request_id.?, .sessions = &.{.{ .id = "one", .attached = false, .revision = 3 }} });
    const done = query.step().done;
    defer done.deinit();
    try std.testing.expectEqualStrings("one", done.reply.value.sessions.?[0].id);
    try std.testing.expect(query.step() == .pending);
    try std.testing.expect(connection.client.nextWrite() == null);
}

test "session pane query kill rejection owns the remote error and is not replayed" {
    var connection = mockConnection();
    defer mockDeinit(&connection);
    var id = "gone".*;
    var query = try Query.init(std.testing.allocator, .kill, &id);
    defer query.deinit();
    @memset(&id, 'x');
    query.bind(&connection);
    try welcome(&connection);
    _ = query.step();
    const request = try submitted(&connection);
    defer request.deinit();
    try std.testing.expectEqualStrings("gone", request.value.session.?);
    try reply(&connection, .{ .id = query.request_id.?, .ok = false, .@"error" = "SessionNotFound" });
    const failure = query.step().failed;
    try std.testing.expectEqual(open.Outcome.rejected, failure.outcome);
    try std.testing.expectEqualStrings("SessionNotFound", failure.remote.?);
    try std.testing.expect(connection.closing);
    try std.testing.expect(query.step() == .pending);
    try std.testing.expect(connection.client.nextWrite() == null);
    try std.testing.expectEqual(open.Outcome.rejected, query.cancel().outcome);
}

test "session pane query cancel before submission is not sent and rejects bad input" {
    var connection = mockConnection();
    defer mockDeinit(&connection);
    try std.testing.expectError(error.InvalidRequest, Query.init(std.testing.allocator, .kill, null));
    try std.testing.expectError(error.InvalidRequest, Query.init(std.testing.allocator, .list, "id"));
    try std.testing.expectError(error.InvalidSessionId, Query.init(std.testing.allocator, .kill, ""));
    var query = try Query.init(std.testing.allocator, .list, null);
    defer query.deinit();
    query.bind(&connection);
    try std.testing.expectEqual(open.Outcome.not_sent, query.cancel().outcome);
    try std.testing.expect(query.step() == .pending);
}
