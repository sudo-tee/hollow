//! Bounded copies: handshake parse arenas must never escape into sessions.
const std = @import("std");
const p = @import("session_protocol.zig");
const diagnostics = @import("diagnostics.zig");

pub const Identity = struct {
    instance: [33]u8 = @splat(0),
    build: [65]u8 = @splat(0),
    connection: [33]u8 = @splat(0),
    role: [17]u8 = @splat(0),
    pid: u32 = 0,

    pub fn capture(value: p.ClientTrace) Identity {
        var result: Identity = .{ .pid = value.pid };
        copy(&result.instance, value.instance);
        copy(&result.build, value.build);
        copy(&result.connection, value.connection);
        copy(&result.role, value.role);
        return result;
    }

    pub fn local(role: []const u8) Identity {
        return capture(.{ .instance = &diagnostics.processId(), .build = &diagnostics.buildId(), .connection = &diagnostics.randomId(), .role = role, .pid = diagnostics.pid() });
    }

    pub fn wire(self: *const Identity) p.ClientTrace {
        return .{
            .instance = std.mem.sliceTo(&self.instance, 0),
            .build = std.mem.sliceTo(&self.build, 0),
            .connection = std.mem.sliceTo(&self.connection, 0),
            .role = std.mem.sliceTo(&self.role, 0),
            .pid = self.pid,
        };
    }
};

fn copy(dest: []u8, value: []const u8) void {
    if (value.len >= dest.len) return;
    // Diagnostics must not allow a peer to inject lines or arbitrary text.
    for (value) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return;
    @memcpy(dest[0..value.len], value);
}

pub fn takeover(creator: *const Identity, previous: *const Identity, next: *const Identity, owner: *const Identity, intent: p.AttachIntent, request: u64) p.TakeoverTrace {
    return .{ .creator = creator.wire(), .previous = previous.wire(), .next = next.wire(), .owner = owner.wire(), .intent = intent, .request = request };
}

pub fn logTakeover(session: []const u8, value: p.TakeoverTrace) void {
    const creator = Identity.capture(value.creator);
    const previous = Identity.capture(value.previous);
    const next = Identity.capture(value.next);
    const owner = Identity.capture(value.owner);
    std.log.info("session.takeover session={s} request={d} intent={s} owner={s} owner_build={s} creator={s} creator_build={s} previous={s} previous_build={s} previous_conn={s} next={s} next_build={s} next_conn={s} next_role={s} next_pid={d}", .{
        token(session),          value.request,        @tagName(value.intent),   owner.wire().instance, owner.wire().build,
        creator.wire().instance, creator.wire().build, previous.wire().instance, previous.wire().build, previous.wire().connection,
        next.wire().instance,    next.wire().build,    next.wire().connection,   next.wire().role,      next.wire().pid,
    });
}

pub fn token(value: []const u8) []const u8 {
    if (value.len > 128) return "invalid";
    for (value) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return "invalid";
    return value;
}

test "session trace owns bounded sanitized handshake fields" {
    var bytes: [32]u8 = @splat('a');
    const identity = Identity.capture(.{ .instance = &bytes, .build = "bad\nline", .role = "gui", .connection = &(@as([34]u8, @splat('b'))) });
    bytes[0] = 'c';
    try std.testing.expectEqualStrings(&(@as([32]u8, @splat('a'))), identity.wire().instance);
    try std.testing.expectEqualStrings("", identity.wire().build);
    try std.testing.expectEqualStrings("", identity.wire().connection);
    try std.testing.expectEqualStrings("gui", identity.wire().role);
    try std.testing.expectEqualStrings("invalid", token("session\nforged"));
}

test "session trace fields default for legacy peers and are ignored by older readers" {
    const a = std.testing.allocator;
    const hello = try p.parse(p.Hello, a, "{\"protocol\":\"hollow-session\",\"version\":1,\"ghostty\":\"test\"}");
    defer hello.deinit();
    try std.testing.expectEqualStrings("", hello.value.trace.instance);
    const event = try p.parse(p.Event, a, "{\"event\":\"taken\",\"session\":\"test\"}");
    defer event.deinit();
    try std.testing.expect(event.value.takeover == null);
    const request = try p.parse(p.Request, a, "{\"id\":1,\"op\":\"attach\",\"session\":\"test\"}");
    defer request.deinit();
    try std.testing.expectEqual(p.AttachIntent.unknown, request.value.attach_intent);
    const identity = Identity.capture(.{ .instance = "new", .build = "abc" });
    const bytes = try p.stringify(a, p.Event{ .event = .taken, .session = "test", .takeover = takeover(&identity, &identity, &identity, &identity, .reclaim, 7) });
    defer a.free(bytes);
    const LegacyEvent = struct { event: p.EventKind, session: []const u8, pane: ?u32 = null };
    const legacy = try p.parse(LegacyEvent, a, bytes);
    defer legacy.deinit();
    try std.testing.expectEqual(p.EventKind.taken, legacy.value.event);
}
