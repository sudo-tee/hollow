//! In-process session owner tests: a fake client on a socketpair drives
//! `Owner.step` directly (no socket path, no daemon).
const std = @import("std");
const p = @import("session_protocol.zig");
const vt = @import("session_vt.zig");
const Owner = @import("session_posix.zig").Owner;
const nowMs = @import("session_posix.zig").nowMs;
const c = @import("posix_c");

const a = std.testing.allocator;

const Frame = struct { kind: p.Kind, stream: u32, payload: []u8 };

const Fake = struct {
    fd: c_int,
    reader: p.Reader = .{},
    frames: std.ArrayList(Frame) = .empty,
    next_id: u64 = 1,

    fn open(owner: *Owner, identity: []const u8) !*Fake {
        var pair: [2]c_int = undefined;
        if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC | c.SOCK_NONBLOCK, 0, &pair) != 0) return error.SocketFailed;
        _ = try owner.addClient(pair[0]);
        const self = try a.create(Fake);
        self.* = .{ .fd = pair[1] };
        try self.send(.hello, 0, try json(p.Hello{ .protocol = p.protocol, .version = p.version, .ghostty = identity }));
        _ = try self.wait(owner, .welcome, 0);
        return self;
    }

    fn close(self: *Fake) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
    }

    fn deinit(self: *Fake) void {
        self.close();
        self.clear();
        self.frames.deinit(a);
        self.reader.deinit(a);
        a.destroy(self);
    }

    fn clear(self: *Fake) void {
        for (self.frames.items) |f| a.free(f.payload);
        self.frames.clearRetainingCapacity();
    }

    fn send(self: *Fake, kind: p.Kind, stream: u32, payload: []const u8) !void {
        defer if (stream == 0) a.free(payload);
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(a);
        try wire.appendSlice(a, &p.header(kind, stream, payload.len).encode());
        try wire.appendSlice(a, payload);
        if (c.write(self.fd, wire.items.ptr, wire.items.len) != @as(isize, @intCast(wire.items.len))) return error.WriteFailed;
    }

    fn request(self: *Fake, req: p.Request) !u64 {
        var copy = req;
        copy.id = self.next_id;
        self.next_id += 1;
        try self.send(.request, 0, try json(copy));
        return copy.id;
    }

    fn sendBytes(self: *Fake, kind: p.Kind, stream: u32, data: []const u8) !void {
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(a);
        try wire.appendSlice(a, &p.header(kind, stream, data.len).encode());
        try wire.appendSlice(a, data);
        if (c.write(self.fd, wire.items.ptr, wire.items.len) != @as(isize, @intCast(wire.items.len))) return error.WriteFailed;
    }

    fn drain(self: *Fake) !void {
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const n = c.read(self.fd, &buf, buf.len);
            if (n <= 0) break;
            try self.reader.push(a, buf[0..@intCast(n)]);
            while (try self.reader.next()) |f| try self.frames.append(a, .{
                .kind = try p.validate(f.header, .to_client),
                .stream = f.header.stream,
                .payload = try a.dupe(u8, f.payload),
            });
        }
    }

    /// Steps the owner until a frame of `kind` on `stream` arrives.
    fn wait(self: *Fake, owner: *Owner, kind: p.Kind, stream: u32) !Frame {
        const deadline = nowMs() + 5000;
        var seen: usize = 0;
        while (nowMs() < deadline) {
            try owner.step(10);
            try self.drain();
            while (seen < self.frames.items.len) : (seen += 1) {
                const f = self.frames.items[seen];
                if (f.kind == kind and f.stream == stream) return f;
            }
        }
        return error.Timeout;
    }

    fn reply(self: *Fake, owner: *Owner, id: u64) !std.json.Parsed(p.Reply) {
        const deadline = nowMs() + 5000;
        var seen: usize = 0;
        while (nowMs() < deadline) {
            try owner.step(10);
            try self.drain();
            while (seen < self.frames.items.len) : (seen += 1) {
                const f = self.frames.items[seen];
                if (f.kind != .reply) continue;
                const parsed = try p.parse(p.Reply, a, f.payload);
                if (parsed.value.id == id) return parsed;
                parsed.deinit();
            }
        }
        return error.Timeout;
    }

    /// Concatenated output (and optionally snapshot) bytes for `pane`.
    fn bytes(self: *Fake, kind: p.Kind, pane: u32) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        for (self.frames.items) |f| if (f.kind == kind and f.stream == pane) try out.appendSlice(a, f.payload);
        return out.toOwnedSlice(a);
    }

    /// Steps until output for `pane` contains `needle`, granting credit.
    fn waitOutput(self: *Fake, owner: *Owner, pane: u32, needle: []const u8) !void {
        const deadline = nowMs() + 5000;
        var granted: usize = 0;
        while (nowMs() < deadline) {
            try owner.step(10);
            try self.drain();
            while (granted < self.frames.items.len) : (granted += 1) {
                const f = self.frames.items[granted];
                if (f.kind != .output or f.payload.len == 0) continue;
                var grant: [4]u8 = undefined;
                std.mem.writeInt(u32, &grant, @intCast(f.payload.len), .little);
                try self.sendBytes(.credit, f.stream, &grant);
            }
            const out = try self.bytes(.output, pane);
            defer a.free(out);
            if (std.mem.indexOf(u8, out, needle) != null) return;
        }
        return error.Timeout;
    }
};

fn json(value: anytype) ![]u8 {
    return p.stringify(a, value);
}

fn shell(comptime script: []const u8) p.Spawn {
    return .{ .cols = 60, .rows = 10, .argv = &.{ "/bin/sh", "-c", script }, .shell_integration = false };
}

fn sessionId(buf: *[32]u8, reply: p.Reply) []const u8 {
    @memcpy(buf, reply.session.?.id[0..32]);
    return buf;
}

test "attach after disconnect restores the screen from a binary snapshot and takes over" {
    var owner = Owner.init(a, std.testing.io);
    defer owner.deinit();
    const first = try Fake.open(&owner, owner.identity);
    defer first.deinit();
    const created = try first.reply(&owner, try first.request(.{ .id = 0, .op = .create, .spawn = shell("printf 'title\\033]0;owner-title\\007'; printf 'kept-line\\n'; read x; printf 'got-%s\\n' \"$x\"; sleep 30") }));
    defer created.deinit();
    try std.testing.expect(created.value.ok);
    var id_buf: [32]u8 = undefined;
    const sid = sessionId(&id_buf, created.value);
    const pane = created.value.session.?.panes[0].id;
    try first.waitOutput(&owner, pane, "kept-line");

    // A second client takes the session over while the first is attached.
    const second = try Fake.open(&owner, owner.identity);
    defer second.deinit();
    const attached = try second.reply(&owner, try second.request(.{ .id = 0, .op = .attach, .session = sid, .panes = &.{.{ .pane = pane, .cols = 70, .rows = 12 }} }));
    defer attached.deinit();
    try std.testing.expect(attached.value.ok);
    _ = try second.wait(&owner, .snapshot_end, pane);
    const taken = try first.wait(&owner, .event, 0);
    const event = try p.parse(p.Event, a, taken.payload);
    defer event.deinit();
    try std.testing.expectEqual(p.EventKind.taken, event.value.event);

    const snapshot = try second.bytes(.snapshot, pane);
    defer a.free(snapshot);
    const restored = try vt.restore(snapshot, 1 << 20);
    defer vt.freeTerminal(restored);
    const text = try vt.plain(restored, a);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "kept-line") != null);

    // Disconnect entirely, reattach, and the shell is still reading input.
    second.close();
    try owner.step(10);
    const third = try Fake.open(&owner, owner.identity);
    defer third.deinit();
    const again = try third.reply(&owner, try third.request(.{ .id = 0, .op = .attach, .session = sid }));
    defer again.deinit();
    try std.testing.expectEqual(@as(u16, 70), again.value.session.?.panes[0].cols);
    _ = try third.wait(&owner, .snapshot_end, pane);
    try third.sendBytes(.input, pane, "abc\n");
    try third.waitOutput(&owner, pane, "got-abc");
}

test "foreign ghostty identity gets a VT formatter snapshot" {
    var owner = Owner.init(a, std.testing.io);
    defer owner.deinit();
    const client = try Fake.open(&owner, "some-other-build");
    defer client.deinit();
    const created = try client.reply(&owner, try client.request(.{ .id = 0, .op = .create, .spawn = shell("printf 'vt-fallback\\n'; sleep 30") }));
    defer created.deinit();
    const pane = created.value.session.?.panes[0].id;
    try client.waitOutput(&owner, pane, "vt-fallback");
    var id_buf: [32]u8 = undefined;
    const sid = sessionId(&id_buf, created.value);
    client.clear();
    const attached = try client.reply(&owner, try client.request(.{ .id = 0, .op = .attach, .session = sid }));
    defer attached.deinit();
    _ = try client.wait(&owner, .snapshot_end, pane);
    const snapshot = try client.bytes(.snapshot, pane);
    defer a.free(snapshot);
    const copy = try vt.Vt.create(a, 60, 10, 1 << 20);
    defer copy.destroy();
    copy.write(snapshot);
    const text = try vt.plain(copy.terminal, a);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "vt-fallback") != null);
}

test "dead pane keeps output and exit status across reattach" {
    var owner = Owner.init(a, std.testing.io);
    defer owner.deinit();
    const client = try Fake.open(&owner, owner.identity);
    defer client.deinit();
    const created = try client.reply(&owner, try client.request(.{ .id = 0, .op = .create, .spawn = shell("printf 'last-words\\n'; exit 3") }));
    defer created.deinit();
    const pane = created.value.session.?.panes[0].id;
    var id_buf: [32]u8 = undefined;
    const sid = sessionId(&id_buf, created.value);
    const exit = try client.wait(&owner, .exit, pane);
    try std.testing.expectEqual(@as(i32, 3), try p.decodeExit(exit.payload));
    const out = try client.bytes(.output, pane);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "last-words") != null);

    const listed = try client.reply(&owner, try client.request(.{ .id = 0, .op = .list }));
    defer listed.deinit();
    try std.testing.expectEqual(@as(?i32, 3), listed.value.sessions.?[0].panes[0].exit);

    client.clear();
    const again = try client.reply(&owner, try client.request(.{ .id = 0, .op = .attach, .session = sid }));
    defer again.deinit();
    _ = try client.wait(&owner, .snapshot_end, pane);
    const exit_again = try client.wait(&owner, .exit, pane);
    try std.testing.expectEqual(@as(i32, 3), try p.decodeExit(exit_again.payload));

    // Closing the last pane ends the session.
    const closed = try client.reply(&owner, try client.request(.{ .id = 0, .op = .close, .pane = pane }));
    defer closed.deinit();
    try std.testing.expect(closed.value.ok);
    const ended = try client.wait(&owner, .event, 0);
    const event = try p.parse(p.Event, a, ended.payload);
    defer event.deinit();
    try std.testing.expectEqual(p.EventKind.session_end, event.value.event);
}

test "exit follows output even when a background job keeps the PTY open" {
    var owner = Owner.init(a, std.testing.io);
    defer owner.deinit();
    const client = try Fake.open(&owner, owner.identity);
    defer client.deinit();
    const created = try client.reply(&owner, try client.request(.{ .id = 0, .op = .create, .spawn = shell("sleep 5 & printf 'fg-done'; exit 2") }));
    defer created.deinit();
    const pane = created.value.session.?.panes[0].id;
    const started = nowMs();
    const exit = try client.wait(&owner, .exit, pane);
    try std.testing.expectEqual(@as(i32, 2), try p.decodeExit(exit.payload));
    try std.testing.expect(nowMs() - started < 2000);
    var saw_output = false;
    for (client.frames.items) |f| {
        if (f.kind == .output and std.mem.indexOf(u8, f.payload, "fg-done") != null) saw_output = true;
        if (f.kind == .exit) break;
    }
    try std.testing.expect(saw_output);
}

test "idle shutdown is cancelled by a new client" {
    var owner = Owner.init(a, std.testing.io);
    defer owner.deinit();
    const first = try Fake.open(&owner, owner.identity);
    first.deinit();
    try owner.step(10);
    try owner.step(10);
    try std.testing.expect(owner.done());
    const second = try Fake.open(&owner, owner.identity);
    defer second.deinit();
    try std.testing.expect(!owner.done());
}

test "layout writes are revision checked" {
    var owner = Owner.init(a, std.testing.io);
    defer owner.deinit();
    const client = try Fake.open(&owner, owner.identity);
    defer client.deinit();
    const created = try client.reply(&owner, try client.request(.{ .id = 0, .op = .create, .spawn = shell("sleep 30") }));
    defer created.deinit();
    const ok = try client.reply(&owner, try client.request(.{ .id = 0, .op = .layout, .revision = 0, .layout = "{\"split\":1}" }));
    defer ok.deinit();
    try std.testing.expect(ok.value.ok);
    try std.testing.expectEqual(@as(?u64, 1), ok.value.revision);
    const stale = try client.reply(&owner, try client.request(.{ .id = 0, .op = .layout, .revision = 0, .layout = "{}" }));
    defer stale.deinit();
    try std.testing.expect(!stale.value.ok);
    try std.testing.expectEqualStrings("RevisionConflict", stale.value.@"error".?);
    try std.testing.expectEqual(@as(?u64, 1), stale.value.revision);
    const listed = try client.reply(&owner, try client.request(.{ .id = 0, .op = .list }));
    defer listed.deinit();
    try std.testing.expectEqualStrings("{\"split\":1}", listed.value.sessions.?[0].layout);
}

test "a client that stops granting credit is resynced with a snapshot" {
    var owner = Owner.init(a, std.testing.io);
    defer owner.deinit();
    const client = try Fake.open(&owner, owner.identity);
    defer client.deinit();
    const created = try client.reply(&owner, try client.request(.{ .id = 0, .op = .create, .spawn = shell("head -c 6000000 /dev/zero | tr '\\000' x; printf 'tail-marker'; sleep 30") }));
    defer created.deinit();
    const pane = created.value.session.?.panes[0].id;
    const deadline = nowMs() + 10000;
    while (nowMs() < deadline and !owner.sessions.items[0].panes.items[0].stale) try owner.step(10);
    try std.testing.expect(owner.sessions.items[0].panes.items[0].stale);
    try client.drain();
    const sent = try client.bytes(.output, pane);
    defer a.free(sent);
    // Nothing beyond the credit window was sent while starved.
    try std.testing.expectEqual(@as(usize, p.window), sent.len);
    var grant: [4]u8 = undefined;
    std.mem.writeInt(u32, &grant, p.window, .little);
    try client.sendBytes(.credit, pane, &grant);
    const ev = try client.wait(&owner, .event, 0);
    const event = try p.parse(p.Event, a, ev.payload);
    defer event.deinit();
    try std.testing.expectEqual(p.EventKind.resync, event.value.event);
    _ = try client.wait(&owner, .snapshot_end, pane);
}
