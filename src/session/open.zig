//! Single-use asynchronous create/attach. Borrows the bridge; never replays.
const std = @import("std");
const transport = @import("transport.zig");
const p = transport.p;
const Allocator = std.mem.Allocator;

pub const Outcome = enum { not_sent, uncertain, rejected };
pub const Failure = struct { reason: anyerror, outcome: Outcome, remote: ?[]const u8 = null };
pub const Attachment = struct {
    // Both allocations are independent of Open.arena and outlive Open.deinit.
    message: transport.Message,
    reply: std.json.Parsed(p.Reply),

    pub fn deinit(self: Attachment) void {
        self.reply.deinit();
        self.message.deinit();
    }
};
pub const Step = union(enum) { pending, attached: Attachment, failed: Failure };

pub const Open = struct {
    allocator: Allocator,
    connection: ?*transport.Connection = null,
    arena: std.heap.ArenaAllocator,
    request: p.Request,
    request_id: ?u64 = null,
    finished: bool = false,
    failure: ?Failure = null,

    pub fn init(a: Allocator, connection: *transport.Connection, request: p.Request) !Open {
        var self = try prepare(a, request);
        self.bind(connection);
        return self;
    }

    /// Complete all fallible setup before creating a bridge. Own every string,
    /// including nested argv/env; no caller storage survives this call.
    pub fn prepare(a: Allocator, request: p.Request) !Open {
        if (request.id != 0 or request.pane != null or request.panes.len != 0 or
            request.revision != null or request.layout != null) return error.InvalidRequest;
        switch (request.op) {
            .create => {
                if (request.session != null or request.spawn == null) return error.InvalidRequest;
                if (request.spawn.?.cols == 0 or request.spawn.?.rows == 0) return error.InvalidRequest;
            },
            .attach => if (request.spawn != null or request.session == null or request.session.?.len == 0) return error.InvalidRequest,
            else => return error.InvalidRequest,
        }
        const buffer = try a.alloc(u8, p.control_limit);
        defer a.free(buffer);
        var writer = std.Io.Writer.fixed(buffer);
        std.json.Stringify.value(request, .{ .emit_null_optional_fields = false }, &writer) catch return error.PayloadTooLarge;
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const copy = try std.json.parseFromSlice(p.Request, arena.allocator(), writer.buffered(), .{ .allocate = .alloc_always });
        return .{ .allocator = a, .arena = arena, .request = copy.value };
    }

    pub fn bind(self: *Open, connection: *transport.Connection) void {
        std.debug.assert(self.connection == null and !self.finished);
        self.connection = connection;
    }

    pub fn isFinished(self: *const Open) bool {
        return self.finished;
    }

    /// Failures, including OOM, are reported exactly once through Step.failed.
    /// Remote error strings remain valid until Open.deinit.
    pub fn step(self: *Open) !Step {
        if (self.finished or self.connection == null) return .pending;
        return self.advance() catch |err| .{ .failed = self.fail(err, self.outcome(), null) };
    }

    fn advance(self: *Open) !Step {
        const connection = self.connection.?;
        const status = connection.status();
        if (status.phase == .connecting) return .pending;
        if (status.phase == .closing or status.phase == .ended)
            return .{ .failed = self.fail(status.failure orelse error.Disconnected, self.outcome(), null) };
        if (self.request_id == null) self.request_id = try connection.request(self.request);
        // One welcome plus one reply maximum. Never cross the reply barrier.
        for (0..2) |_| {
            const message = connection.poll() orelse return .pending;
            var transferred = false;
            defer if (!transferred) message.deinit();
            if (message.kind == .welcome) continue;
            // poll releases the request slot. Malformed replies remain uncertain.
            if (message.kind != .reply or message.request_id != self.request_id) return error.InvalidReply;
            const parsed = try p.parse(p.Reply, self.allocator, message.payload);
            errdefer parsed.deinit();
            if (parsed.value.id != self.request_id.?) return error.InvalidReply;
            if (!parsed.value.ok) {
                defer parsed.deinit();
                const remote = if (parsed.value.@"error") |text| self.arena.allocator().dupe(u8, text) catch {
                    return .{ .failed = self.fail(error.OutOfMemory, .rejected, null) };
                } else null;
                return .{ .failed = self.fail(error.Rejected, .rejected, remote) };
            }
            const session = parsed.value.session orelse return error.InvalidReply;
            if (session.id.len == 0 or !session.attached or session.panes.len == 0 or
                session.panes.len > @import("client.zig").max_panes or
                message.generation == 0 or message.generation != connection.attachmentGeneration()) return error.InvalidReply;
            if (self.request.op == .attach and !std.mem.eql(u8, self.request.session.?, session.id)) return error.InvalidReply;
            for (session.panes, 0..) |pane, i| {
                if (pane.id == 0 or pane.cols == 0 or pane.rows == 0) return error.InvalidReply;
                for (session.panes[0..i]) |previous| if (previous.id == pane.id) return error.InvalidReply;
            }
            self.finished = true;
            transferred = true;
            return .{ .attached = .{ .message = message, .reply = parsed } };
        }
        return .pending;
    }

    fn outcome(self: *Open) Outcome {
        const id = self.request_id orelse return .not_sent;
        return switch (self.connection.?.requestState(id)) {
            .queued, .not_sent => .not_sent,
            else => .uncertain,
        };
    }

    fn fail(self: *Open, reason: anyerror, result: Outcome, remote: ?[]const u8) Failure {
        const failure: Failure = .{ .reason = reason, .outcome = result, .remote = remote };
        self.finished = true;
        self.failure = failure;
        if (self.connection) |connection| connection.close();
        return failure;
    }

    pub fn cancel(self: *Open) Failure {
        if (self.failure) |failure| return failure;
        // A transferred attachment belongs to its caller, not this operation.
        if (self.finished) return .{ .reason = error.Canceled, .outcome = .uncertain };
        // Fence the writer before classifying queued work. Otherwise it could
        // submit between requestState and close, invalidating not_sent.
        if (self.connection) |connection| connection.close();
        return self.fail(error.Canceled, self.outcome(), null);
    }

    /// No connection access: its owner handles bridge retirement independently.
    pub fn deinit(self: *Open) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn mockConnection() transport.Connection {
    return .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .arena = .init(std.testing.allocator),
        .options = .{ .ghostty_identity = "open-test" },
        .client = .{ .allocator = std.testing.allocator, .identity = "open-test" },
    };
}

fn mockDeinit(connection: *transport.Connection) void {
    connection.client.deinit();
    connection.arena.deinit();
}

fn welcome(connection: *transport.Connection) !void {
    const body = try p.stringify(std.testing.allocator, p.Welcome{ .ghostty = "open-test", .snapshot = .binary, .owner_pid = 1 });
    defer std.testing.allocator.free(body);
    try connection.client.receive(p.header(.welcome, 0, body.len), body);
}

fn submit(connection: *transport.Connection) !void {
    const message = connection.client.nextWrite() orelse return error.MissingRequest;
    defer message.deinit();
    try std.testing.expectEqual(p.Kind.request, message.kind);
}

fn reply(connection: *transport.Connection, value: p.Reply) !void {
    const body = try p.stringify(std.testing.allocator, value);
    defer std.testing.allocator.free(body);
    try connection.client.receive(p.header(.reply, 0, body.len), body);
}

test "session pane open connecting admission deep copy and reply barrier" {
    var connection = mockConnection();
    defer mockDeinit(&connection);
    var cwd = "/old".*;
    var arg = "shell".*;
    var command = "exec!".*;
    var key = "KEY".*;
    var value = "value".*;
    var operation = try Open.prepare(std.testing.allocator, .{ .id = 0, .op = .create, .spawn = .{ .cwd = &cwd, .argv = &.{&arg}, .command = &command, .env = &.{.{ .key = &key, .value = &value }} } });
    defer operation.deinit();
    @memset(&cwd, 'x');
    @memset(&arg, 'x');
    @memset(&command, 'x');
    @memset(&key, 'x');
    @memset(&value, 'x');
    try std.testing.expectEqualStrings("/old", operation.request.spawn.?.cwd.?);
    try std.testing.expectEqualStrings("shell", operation.request.spawn.?.argv[0]);
    try std.testing.expectEqualStrings("exec!", operation.request.spawn.?.command.?);
    try std.testing.expectEqualStrings("KEY", operation.request.spawn.?.env[0].key);
    try std.testing.expectEqualStrings("value", operation.request.spawn.?.env[0].value);
    try std.testing.expect((try operation.step()) == .pending);
    operation.bind(&connection);
    try std.testing.expect((try operation.step()) == .pending);
    try std.testing.expectEqual(@as(u64, 1), connection.client.next_id);
    try welcome(&connection);
    try std.testing.expect((try operation.step()) == .pending);
    try submit(&connection);
    try std.testing.expect((try operation.step()) == .pending);
    try std.testing.expectEqual(@as(u64, 2), connection.client.next_id);
    try std.testing.expect(connection.client.nextWrite() == null);
    try reply(&connection, .{ .id = operation.request_id.?, .session = .{ .id = "session", .attached = true, .revision = 1, .panes = &.{.{ .id = 1, .cols = 80, .rows = 24 }} } });
    try connection.client.receive(p.header(.output, 1, 4), "live");
    const attached = (try operation.step()).attached;
    defer attached.deinit();
    try std.testing.expect(operation.isFinished());
    try std.testing.expectEqualStrings("session", attached.reply.value.session.?.id);
    try std.testing.expect((try operation.step()) == .pending);
    try std.testing.expect(!connection.closing);
    const output = connection.poll().?;
    defer output.deinit();
    try std.testing.expectEqualStrings("live", output.payload);
}

test "session pane open rejection owns remote error and reports once" {
    var connection = mockConnection();
    defer mockDeinit(&connection);
    try welcome(&connection);
    var operation = try Open.init(std.testing.allocator, &connection, .{ .id = 0, .op = .attach, .session = "missing" });
    defer operation.deinit();
    _ = try operation.step();
    try submit(&connection);
    try reply(&connection, .{ .id = operation.request_id.?, .ok = false, .@"error" = "SessionNotFound" });
    const failure = (try operation.step()).failed;
    try std.testing.expectEqual(Outcome.rejected, failure.outcome);
    try std.testing.expectEqualStrings("SessionNotFound", failure.remote.?);
    try std.testing.expect(connection.closing);
    try std.testing.expect((try operation.step()) == .pending);
}

test "session pane open lost reply queued cancellation and preadmission" {
    for (0..5) |scenario| {
        var connection = mockConnection();
        defer mockDeinit(&connection);
        var operation = try Open.prepare(std.testing.allocator, .{ .id = 0, .op = .create, .spawn = .{} });
        defer operation.deinit();
        if (scenario != 4) operation.bind(&connection);
        if (scenario > 0 and scenario < 4) {
            try welcome(&connection);
            _ = try operation.step();
            if (scenario >= 2) try submit(&connection);
        }
        const expected: Outcome = if (scenario == 2 or scenario == 3) .uncertain else .not_sent;
        const failure = if (scenario == 0 or scenario >= 3) operation.cancel() else blk: {
            connection.client.ended = true;
            connection.finished = true;
            connection.failure = error.EndOfStream;
            break :blk (try operation.step()).failed;
        };
        try std.testing.expectEqual(expected, failure.outcome);
        try std.testing.expectEqual(scenario != 4, connection.closing);
        try std.testing.expect((try operation.step()) == .pending);
    }
}

test "session pane open invalid initial requests leave connection alone" {
    var connection = mockConnection();
    defer mockDeinit(&connection);
    const invalid = [_]p.Request{
        .{ .id = 1, .op = .create, .spawn = .{} },
        .{ .id = 0, .op = .create },
        .{ .id = 0, .op = .list },
        .{ .id = 0, .op = .attach, .session = "" },
        .{ .id = 0, .op = .attach, .session = "s", .spawn = .{} },
        .{ .id = 0, .op = .create, .spawn = .{}, .session = "s" },
        .{ .id = 0, .op = .create, .spawn = .{}, .pane = 1 },
        .{ .id = 0, .op = .create, .spawn = .{}, .revision = 0 },
        .{ .id = 0, .op = .create, .spawn = .{}, .layout = "" },
        .{ .id = 0, .op = .create, .spawn = .{}, .panes = &.{.{ .pane = 1, .cols = 80, .rows = 24 }} },
    };
    for (invalid) |request| try std.testing.expectError(error.InvalidRequest, Open.init(std.testing.allocator, &connection, request));
    try std.testing.expect(!connection.closing);
    try std.testing.expectEqual(@as(u64, 1), connection.client.next_id);
}

test "session pane open malformed dequeued reply stays uncertain" {
    for (0..9) |scenario| {
        var connection = mockConnection();
        defer mockDeinit(&connection);
        try welcome(&connection);
        var operation = try Open.init(std.testing.allocator, &connection, .{ .id = 0, .op = .create, .spawn = .{} });
        defer operation.deinit();
        _ = try operation.step();
        try submit(&connection);
        const panes = [_]p.PaneInfo{ .{ .id = if (scenario == 3) 0 else 1, .cols = if (scenario == 4) 0 else 80, .rows = if (scenario == 5) 0 else 24 }, .{ .id = 1, .cols = 80, .rows = 24 } };
        const value: p.Reply = .{ .id = operation.request_id.?, .session = .{
            .id = if (scenario == 1) "" else "s",
            .attached = scenario != 2,
            .revision = 0,
            .panes = if (scenario == 0) &.{} else if (scenario == 6) &panes else panes[0..1],
        } };
        // Inject invalid bytes/metadata past the lower protocol validator.
        const body = if (scenario == 7) try std.testing.allocator.dupe(u8, "{") else try p.stringify(std.testing.allocator, value);
        try connection.client.incoming.append(std.testing.allocator, .{ .kind = .reply, .request_id = operation.request_id, .generation = if (scenario == 8) 2 else 1, .payload = body, .allocator = std.testing.allocator });
        connection.client.generation = 1;
        const failure = (try operation.step()).failed;
        try std.testing.expectEqual(Outcome.uncertain, failure.outcome);
        try std.testing.expect(connection.closing);
        try std.testing.expect((try operation.step()) == .pending);
    }
}

fn allocationRollback(a: Allocator) !void {
    var connection = mockConnection();
    defer mockDeinit(&connection);
    var operation = Open.init(a, &connection, .{ .id = 0, .op = .create, .spawn = .{ .cwd = "/tmp", .argv = &.{ "sh", "-l" } } }) catch |err| {
        try std.testing.expect(!connection.closing);
        return err;
    };
    operation.deinit();
    try std.testing.expect(!connection.closing);
}

test "session pane open allocator rollback" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationRollback, .{});
}

fn completionAllocationRollback(a: Allocator, rejected: bool) !void {
    var connection = mockConnection();
    defer mockDeinit(&connection);
    var operation = try Open.init(a, &connection, .{ .id = 0, .op = .attach, .session = "s" });
    defer operation.deinit();
    try welcome(&connection);
    try std.testing.expect((try operation.step()) == .pending);
    try submit(&connection);
    try reply(&connection, .{
        .id = operation.request_id.?,
        .ok = !rejected,
        .@"error" = if (rejected) "SessionNotFound" else null,
        .session = if (rejected) null else .{ .id = "s", .attached = true, .revision = 0, .panes = &.{.{ .id = 1, .cols = 80, .rows = 24 }} },
    });
    switch (try operation.step()) {
        .attached => |attachment| {
            defer attachment.deinit();
            try std.testing.expect(!rejected);
        },
        .failed => |failure| {
            try std.testing.expect(operation.isFinished());
            try std.testing.expect(connection.closing);
            try std.testing.expect((try operation.step()) == .pending);
            if (failure.reason == error.OutOfMemory) return error.OutOfMemory;
            try std.testing.expect(rejected);
            try std.testing.expectEqual(Outcome.rejected, failure.outcome);
        },
        .pending => return error.MissingCompletion,
    }
}

test "session pane open completion allocator rollback reports terminal failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, completionAllocationRollback, .{false});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, completionAllocationRollback, .{true});
}

test "session pane open attach request owns session string and deinit leaves bridge alone" {
    var connection = mockConnection();
    defer mockDeinit(&connection);
    var session = "session".*;
    var operation = try Open.init(std.testing.allocator, &connection, .{ .id = 0, .op = .attach, .session = &session });
    @memset(&session, 'x');
    try std.testing.expectEqualStrings("session", operation.request.session.?);
    operation.deinit();
    try std.testing.expect(!connection.closing);
}

test "session pane open serialization bounded before bind" {
    const large = try std.testing.allocator.alloc(u8, p.control_limit);
    defer std.testing.allocator.free(large);
    @memset(large, 'x');
    try std.testing.expectError(error.PayloadTooLarge, Open.prepare(std.testing.allocator, .{ .id = 0, .op = .attach, .session = large }));
}

test "session pane open attachment outlives operation request arena" {
    for ([_]p.Op{ .create, .attach }) |op| {
        var connection = mockConnection();
        defer mockDeinit(&connection);
        const attachment: Attachment = blk: {
            var operation = try Open.init(std.testing.allocator, &connection, .{
                .id = 0,
                .op = op,
                .session = if (op == .attach) "session" else null,
                .spawn = if (op == .create) .{ .cwd = "/request-owned" } else null,
            });
            defer operation.deinit();
            try welcome(&connection);
            _ = try operation.step();
            try submit(&connection);
            try reply(&connection, .{ .id = operation.request_id.?, .session = .{
                .id = "session",
                .attached = true,
                .revision = 42,
                .layout = "opaque-layout",
                .panes = &.{.{ .id = 7, .cols = 90, .rows = 30, .title = "shell", .cwd = "/remote" }},
            } });
            break :blk (try operation.step()).attached;
        };
        defer attachment.deinit();
        const session = attachment.reply.value.session.?;
        try std.testing.expectEqualStrings("session", session.id);
        try std.testing.expectEqualStrings("opaque-layout", session.layout);
        try std.testing.expectEqual(@as(u64, 42), session.revision);
        try std.testing.expectEqualStrings("shell", session.panes[0].title);
        try std.testing.expectEqualStrings("/remote", session.panes[0].cwd);
        try std.testing.expectEqual(@as(u32, 7), session.panes[0].id);
        try std.testing.expect(std.mem.indexOf(u8, attachment.message.payload, "opaque-layout") != null);
        try std.testing.expect(!connection.closing);
    }
}
