const std = @import("std");
const io = @import("io.zig");
const core = @import("session/client.zig");
const transport = @import("session/transport.zig");
const p = core.p;
const a = std.testing.allocator;

fn receive(client: *core.Client, kind: p.Kind, value: anytype) !void {
    const body = try p.stringify(a, value);
    defer a.free(body);
    try client.receive(p.header(kind, 0, body.len), body);
}

fn welcome(client: *core.Client) !void {
    try receive(client, .welcome, p.Welcome{ .ghostty = "test", .snapshot = .binary, .owner_pid = 1 });
    client.poll().?.deinit();
}

fn attach(client: *core.Client) !void {
    const id = try client.request(.{ .id = 0, .op = .attach, .session = "test-session" });
    client.nextWrite().?.deinit();
    try receive(client, .reply, p.Reply{
        .id = id,
        .session = .{ .id = "test-session", .attached = true, .revision = 0, .panes = &.{.{ .id = 1, .cols = 80, .rows = 24 }} },
    });
    client.poll().?.deinit();
}

test "session client holds requests until welcome and records ambiguous submission" {
    var client: core.Client = .{ .allocator = a, .identity = "test" };
    defer client.deinit();
    const first = try client.request(.{ .id = 999, .op = .create });
    const second = try client.request(.{ .id = 999, .op = .list });
    try std.testing.expect(client.nextWrite() == null);
    try std.testing.expectEqual(core.RequestState.queued, client.requestState(first));
    try welcome(&client);
    const frame = client.nextWrite().?;
    defer frame.deinit();
    const parsed = try p.parse(p.Request, a, frame.payload);
    defer parsed.deinit();
    try std.testing.expectEqual(first, parsed.value.id);
    try std.testing.expectEqual(core.RequestState.submitted, client.requestState(first));
    client.ended = true;
    try std.testing.expectEqual(core.RequestState.uncertain, client.requestState(first));
    try std.testing.expectEqual(core.RequestState.not_sent, client.requestState(second));
    try std.testing.expect(client.nextWrite() == null);
    try std.testing.expectError(error.Disconnected, client.request(.{ .id = 0, .op = .create }));
}

test "session client records a valid welcome host and ignores an invalid one" {
    var client: core.Client = .{ .allocator = a, .identity = "test" };
    defer client.deinit();
    try receive(&client, .welcome, p.Welcome{ .ghostty = "test", .snapshot = .binary, .owner_pid = 1, .host = "0123456789abcdef0123456789abcdef" });
    client.poll().?.deinit();
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", client.host());

    var other: core.Client = .{ .allocator = a, .identity = "test" };
    defer other.deinit();
    try receive(&other, .welcome, p.Welcome{ .ghostty = "test", .snapshot = .binary, .owner_pid = 1, .host = "bad host\x1b" });
    other.poll().?.deinit();
    try std.testing.expect(other.ready);
    try std.testing.expectEqualStrings("", other.host());
}

test "session client validates welcome format direction and reply correlation" {
    var client: core.Client = .{ .allocator = a, .identity = "test" };
    defer client.deinit();
    try std.testing.expectError(error.ExpectedWelcome, client.receive(p.header(.snapshot_end, 1, 0), ""));
    try std.testing.expectError(error.ProtocolMismatch, receive(&client, .welcome, p.Welcome{ .version = 2, .ghostty = "test", .snapshot = .binary, .owner_pid = 1 }));
    try std.testing.expectError(error.IdentityMismatch, receive(&client, .welcome, p.Welcome{ .ghostty = "other", .snapshot = .binary, .owner_pid = 1 }));
    try receive(&client, .welcome, p.Welcome{ .ghostty = "other", .snapshot = .vt, .owner_pid = 1 });
    client.poll().?.deinit();
    try std.testing.expectEqual(p.SnapshotFormat.vt, client.format.?);
    try std.testing.expectError(error.DuplicateWelcome, receive(&client, .welcome, p.Welcome{ .ghostty = "test", .snapshot = .binary, .owner_pid = 1 }));
    try std.testing.expectError(error.InvalidKind, client.receive(p.header(.input, 1, 1), "x"));
    const id = try client.request(.{ .id = 0, .op = .list });
    try std.testing.expectError(error.UnexpectedReply, receive(&client, .reply, p.Reply{ .id = id }));
    client.nextWrite().?.deinit();
    try receive(&client, .reply, p.Reply{ .id = id });
    try std.testing.expectEqual(core.RequestState.reply_pending, client.requestState(id));
    try std.testing.expectError(error.UnexpectedReply, receive(&client, .reply, p.Reply{ .id = id }));
    client.poll().?.deinit();
    try std.testing.expectEqual(core.RequestState.unknown, client.requestState(id));
}

/// Receives one full output frame and discards it; parsing is reported
/// separately through consumedBytes.
fn receiveFrame(client: *core.Client, pane: u32) !void {
    const bytes: [p.max_data]u8 = @splat('x');
    try client.receive(p.header(.output, pane, bytes.len), &bytes);
    client.poll().?.deinit();
}

fn expectGrant(client: *core.Client, pane: u32, amount: u32) !void {
    const grant = client.nextWrite() orelse return error.TestExpectedGrant;
    defer grant.deinit();
    try std.testing.expectEqual(p.Kind.credit, grant.kind);
    try std.testing.expectEqual(pane, grant.pane);
    try std.testing.expectEqual(amount, try p.decodeCredit(grant.payload));
}

test "session client grants credit on receipt up to the receive-ahead bound" {
    var client: core.Client = .{ .allocator = a, .identity = "test" };
    defer client.deinit();
    try welcome(&client);
    try attach(&client);
    // Credit no longer waits for a GUI frame to parse: throughput is bound by
    // the transport round trip, not by 64 KiB per rendered frame.
    const ahead_frames = (core.pane_receive_ahead - p.window) / p.max_data;
    for (0..ahead_frames) |_| {
        try receiveFrame(&client, 1);
        try expectGrant(&client, 1, p.max_data);
    }
    // At the bound, the owner may still fill one window, then must wait.
    for (0..p.window / p.max_data) |_| try receiveFrame(&client, 1);
    try std.testing.expect(client.nextWrite() == null);
    try std.testing.expectError(error.InvalidCredit, client.receive(p.header(.output, 1, 1), "x"));
    try std.testing.expectEqual(core.pane_receive_ahead, client.buffered);
    try std.testing.expectError(error.InvalidCredit, client.consumedBytes(1, client.generation, core.pane_receive_ahead + 1));
    try client.consumedBytes(1, client.generation, p.max_data);
    try std.testing.expect(client.nextWrite() == null); // Still above the bound.
    try client.consumedBytes(1, client.generation, p.window - p.max_data);
    try expectGrant(&client, 1, p.window);
    const generation = client.generation;
    try attach(&client);
    try std.testing.expectEqual(@as(usize, 0), client.buffered);
    try client.consumedBytes(1, generation, p.max_data); // Same pane ID, old attachment.
    try std.testing.expect(client.nextWrite() == null);
}

test "session client aggregate receive-ahead retries a drained pane's withheld grant" {
    var client: core.Client = .{ .allocator = a, .identity = "test" };
    defer client.deinit();
    try welcome(&client);
    const id = try client.request(.{ .id = 0, .op = .attach, .session = "s" });
    client.nextWrite().?.deinit();
    const pane_count = core.receive_ahead / core.pane_receive_ahead + 1;
    var panes: [pane_count]p.PaneInfo = undefined;
    for (&panes, 1..) |*info, pane| info.* = .{ .id = @intCast(pane), .cols = 80, .rows = 24 };
    try receive(&client, .reply, p.Reply{ .id = id, .session = .{ .id = "s", .attached = true, .revision = 0, .panes = &panes } });
    client.poll().?.deinit();
    // Fill every other pane to its own bound, so together they fill the
    // aggregate one; the last window of each stays uncredited.
    const per_pane = core.pane_receive_ahead - p.window;
    for (1..pane_count) |pane| {
        for (0..per_pane / p.max_data) |_| {
            try receiveFrame(&client, @intCast(pane));
            try expectGrant(&client, @intCast(pane), p.max_data);
        }
        for (0..p.window / p.max_data) |_| try receiveFrame(&client, @intCast(pane));
    }
    try std.testing.expect(client.nextWrite() == null);
    try std.testing.expectEqual(core.receive_ahead, client.buffered);
    try receiveFrame(&client, pane_count);
    try std.testing.expect(client.nextWrite() == null);
    // The withheld pane parses everything it has, yet stays withheld.
    try client.consumedBytes(pane_count, client.generation, p.max_data);
    try std.testing.expect(client.nextWrite() == null);
    // Another pane's parse must release it; nothing else would.
    try client.consumedBytes(1, client.generation, p.window);
    try expectGrant(&client, 1, p.window);
    try expectGrant(&client, pane_count, p.max_data);
    try std.testing.expect(client.nextWrite() == null);
}

test "session client close releases the closed pane's receive-ahead" {
    var client: core.Client = .{ .allocator = a, .identity = "test" };
    defer client.deinit();
    try welcome(&client);
    try attach(&client);
    try client.receive(p.header(.output, 1, 3), "abc");
    try expectGrant(&client, 1, 3);
    const id = try client.request(.{ .id = 0, .op = .close, .pane = 1 });
    client.nextWrite().?.deinit();
    try receive(&client, .reply, p.Reply{ .id = id });
    try std.testing.expectEqual(@as(usize, 0), client.buffered);
    while (client.poll()) |message| message.deinit();
    try client.consumedBytes(1, client.generation, 3); // Late parse of a closed pane.
    try std.testing.expect(client.nextWrite() == null);
}

test "session client bounds queues and outstanding requests" {
    var client: core.Client = .{ .allocator = a, .identity = "test" };
    defer client.deinit();
    for (0..core.max_requests) |_| _ = try client.request(.{ .id = 0, .op = .list });
    try std.testing.expectError(error.ResourceExhausted, client.request(.{ .id = 0, .op = .list }));
    try welcome(&client);
    while (client.nextWrite()) |message| message.deinit();
    // A fresh client exercises receive queue bounds without pending work.
    var other: core.Client = .{ .allocator = a, .identity = "test" };
    defer other.deinit();
    try welcome(&other);
    try attach(&other);
    for (0..core.queue_frames) |_| try other.receive(p.header(.snapshot_end, 1, 0), "");
    try std.testing.expectError(error.ResourceExhausted, other.receive(p.header(.snapshot_end, 1, 0), ""));
    other.poll().?.deinit();
    try other.receive(p.header(.snapshot_end, 1, 0), "");
    try std.testing.expectError(error.PayloadTooLarge, other.receive(p.header(.snapshot, 1, p.max_data + 1), ""));
    var byte_bounded: core.Client = .{ .allocator = a, .identity = "test" };
    defer byte_bounded.deinit();
    const large = try a.alloc(u8, 300 * 1024);
    defer a.free(large);
    @memset(large, 'x');
    var count: usize = 0;
    while (true) {
        _ = byte_bounded.request(.{ .id = 0, .op = .layout, .layout = large }) catch |err| {
            try std.testing.expectEqual(error.ResourceExhausted, err);
            break;
        };
        count += 1;
    }
    try std.testing.expect(count < core.max_requests);
    try std.testing.expect(byte_bounded.outgoing.bytes <= core.queue_bytes);
}

test "session client never sends old pane actions or credits to a new attachment" {
    var client: core.Client = .{ .allocator = a, .identity = "test" };
    defer client.deinit();
    try welcome(&client);
    try attach(&client);
    try client.receive(p.header(.output, 1, 1), "x");
    try expectGrant(&client, 1, 1);
    const output = client.poll().?;
    defer output.deinit();
    const id = try client.request(.{ .id = 0, .op = .attach, .session = "other" });
    try std.testing.expectError(error.AttachmentPending, client.request(.{ .id = 0, .op = .close, .pane = 1 }));
    try std.testing.expectError(error.AttachmentPending, client.send(.input, 1, "stale"));
    client.nextWrite().?.deinit();
    try client.consumed(output);
    try std.testing.expect(client.nextWrite() == null); // Await attach result.
    try receive(&client, .reply, p.Reply{
        .id = id,
        .session = .{ .id = "other", .attached = true, .revision = 0, .panes = &.{.{ .id = 1, .cols = 80, .rows = 24 }} },
    });
    try std.testing.expectError(error.AttachmentPending, client.send(.input, 1, "not-published"));
    client.poll().?.deinit();
    try std.testing.expect(client.nextWrite() == null); // Stale credit dropped.
    try client.send(.input, 1, "stale");
    try receive(&client, .event, p.Event{ .event = .taken, .session = "other" });
    client.poll().?.deinit();
    try std.testing.expect(client.nextWrite() == null); // Take-over drops input.
}

test "session client close frees pane slots and detach keeps connection usable" {
    var client: core.Client = .{ .allocator = a, .identity = "test" };
    defer client.deinit();
    try welcome(&client);
    try attach(&client);
    const id = try client.request(.{ .id = 0, .op = .close, .pane = 1 });
    client.nextWrite().?.deinit();
    try receive(&client, .reply, p.Reply{ .id = id });
    client.poll().?.deinit();
    try std.testing.expectError(error.NotAttached, client.send(.input, 1, "closed"));
    for (2..core.max_panes + 4) |pane| {
        const spawn = try client.request(.{ .id = 0, .op = .spawn });
        client.nextWrite().?.deinit();
        try receive(&client, .reply, p.Reply{ .id = spawn, .pane = @intCast(pane) });
        client.poll().?.deinit();
        const close = try client.request(.{ .id = 0, .op = .close, .pane = @intCast(pane) });
        client.nextWrite().?.deinit();
        try receive(&client, .reply, p.Reply{ .id = close });
        client.poll().?.deinit();
    }
    const detach = try client.request(.{ .id = 0, .op = .detach });
    client.nextWrite().?.deinit();
    try receive(&client, .reply, p.Reply{ .id = detach });
    client.poll().?.deinit();
    try std.testing.expect(client.ready and !client.ended);
    _ = try client.request(.{ .id = 0, .op = .list });
    client.nextWrite().?.deinit();
}

test "session client transport API rejects invalid timeout on every platform" {
    std.testing.refAllDecls(transport.Connection);
    try std.testing.expectError(error.InvalidArgument, transport.Connection.create(a, io.get(), .{
        .agent = .{ .timeout_ms = 0 },
        .ghostty_identity = "test",
    }));
}

fn allocationFailures(allocator: std.mem.Allocator) !void {
    var client: core.Client = .{ .allocator = allocator, .identity = "test" };
    defer client.deinit();
    const id = try client.request(.{ .id = 0, .op = .list });
    const hello = "{\"ghostty\":\"test\",\"snapshot\":\"binary\",\"owner_pid\":1}";
    try client.receive(p.header(.welcome, 0, hello.len), hello);
    client.poll().?.deinit();
    client.nextWrite().?.deinit();
    const reply = "{\"id\":1,\"ok\":true,\"sessions\":[]}";
    client.receive(p.header(.reply, 0, reply.len), reply) catch |err| {
        try std.testing.expectEqual(core.RequestState.submitted, client.requestState(id));
        try std.testing.expect(client.poll() == null);
        return err;
    };
    client.poll().?.deinit();
}

test "session client allocation failure never loses a completed reply" {
    try std.testing.checkAllAllocationFailures(a, allocationFailures, .{});
}

fn inputAllocationFailures(allocator: std.mem.Allocator) !void {
    var client: core.Client = .{ .allocator = allocator, .identity = "test" };
    defer client.deinit();
    const hello = "{\"ghostty\":\"test\",\"snapshot\":\"binary\",\"owner_pid\":1}";
    try client.receive(p.header(.welcome, 0, hello.len), hello);
    client.poll().?.deinit();
    _ = try client.request(.{ .id = 0, .op = .attach, .session = "test" });
    client.nextWrite().?.deinit();
    const reply = "{\"id\":1,\"session\":{\"id\":\"test\",\"attached\":true,\"revision\":0,\"panes\":[{\"id\":1,\"cols\":80,\"rows\":24}]}}";
    try client.receive(p.header(.reply, 0, reply.len), reply);
    client.poll().?.deinit();
    const bytes: [2 * p.max_data + 3]u8 = @splat('x');
    client.input(1, &bytes) catch |err| {
        try std.testing.expect(client.nextWrite() == null);
        try std.testing.expectEqual(@as(usize, 0), client.outgoing.bytes);
        return err;
    };
    var count: usize = 0;
    while (client.nextWrite()) |message| {
        defer message.deinit();
        try std.testing.expectEqual(p.Kind.input, message.kind);
        count += message.payload.len;
    }
    try std.testing.expectEqual(bytes.len, count);
}

test "session client large paste admission is atomic across allocation failures" {
    try std.testing.checkAllAllocationFailures(a, inputAllocationFailures, .{});
}

pub fn waitMessage(connection: *transport.Connection, kind: p.Kind) !transport.Message {
    const deadline = io.nanoTimestamp() + 5 * std.time.ns_per_s;
    while (io.nanoTimestamp() < deadline) {
        while (connection.poll()) |message| {
            if (message.kind == kind) return message;
            defer message.deinit();
            try connection.consumed(message);
        }
        if (connection.status().phase == .ended) return error.ConnectionEnded;
        try std.Io.sleep(io.get(), .fromMilliseconds(5), .awake);
    }
    return error.Timeout;
}

pub fn waitEnded(connection: *transport.Connection) !void {
    const deadline = io.nanoTimestamp() + 5 * std.time.ns_per_s;
    while (connection.status().phase != .ended) {
        if (io.nanoTimestamp() > deadline) return error.Timeout;
        try std.Io.sleep(io.get(), .fromMilliseconds(5), .awake);
    }
}

test "session transport negotiates times out and joins connectors without a welcome" {
    const connection = try transport.Connection.create(a, io.get(), .{
        .connector = .{ .argv = &.{ "/bin/sh", "-c", "exec sleep 30" } },
        .agent = .{ .path = "unused", .timeout_ms = 50 },
        .ghostty_identity = "test",
    });
    defer connection.destroy();
    const id = try connection.request(.{ .id = 0, .op = .create });
    try waitEnded(connection);
    try std.testing.expectEqual(error.Timeout, connection.status().failure.?);
    try std.testing.expectEqual(core.RequestState.not_sent, connection.requestState(id));
}

test "session transport cancel joins deployment and rejects future requests" {
    const connection = try transport.Connection.create(a, io.get(), .{
        .connector = .{ .argv = &.{ "/bin/sh", "-c", "exec sleep 30" } },
        .agent = .{ .path = "unused" },
        .ghostty_identity = "test",
    });
    connection.close();
    try std.testing.expectError(error.Disconnected, connection.request(.{ .id = 0, .op = .create }));
    connection.destroy();
}

// Connector fixtures still consume the real framed hello/request stream.
const fake_prelude =
    \\import os, sys, json, struct
    \\def exact(n):
    \\    out = b''
    \\    while len(out) < n:
    \\        data = os.read(0, n-len(out))
    \\        if not data: raise SystemExit(0)
    \\        out += data
    \\    return out
    \\def read():
    \\    k, s, n = struct.unpack('<BII', exact(9))
    \\    return k, s, exact(n)
    \\def send(k, s, data):
    \\    if isinstance(data, dict): data = json.dumps(data).encode()
    \\    wire = struct.pack('<BII', k, s, len(data)) + data
    \\    while wire:
    \\        wire = wire[os.write(1, wire):]
    \\assert read()[0] == 1
    \\send(16, 0, dict(ghostty='test', snapshot='vt', owner_pid=1))
    \\kind, stream, data = read()
    \\assert kind == 2
    \\request = json.loads(data)
    \\
;

test "session transport never replays create after lost reply" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io.get(), ".", a);
    defer a.free(dir);
    const log = try std.fmt.allocPrint(a, "{s}/submissions", .{dir});
    defer a.free(log);
    const script = fake_prelude ++ "with open(sys.argv[1], 'a') as f: f.write('create\\n')\n";
    const connection = try transport.Connection.create(a, io.get(), .{
        .connector = .{ .argv = &.{ "/usr/bin/python3", "-c", script, log } },
        .agent = .{ .path = "unused" },
        .ghostty_identity = "test",
    });
    defer connection.destroy();
    const id = try connection.request(.{ .id = 0, .op = .create });
    try waitEnded(connection);
    try std.testing.expectEqual(core.RequestState.uncertain, connection.requestState(id));
    const contents = try tmp.dir.readFileAlloc(io.get(), "submissions", a, .limited(1024));
    defer a.free(contents);
    try std.testing.expectEqualStrings("create\n", contents);
}

test "session transport times out unanswered requests as uncertain without replay" {
    const script = fake_prelude ++ "import time; time.sleep(30)\n";
    const connection = try transport.Connection.create(a, io.get(), .{
        .connector = .{ .argv = &.{ "/usr/bin/python3", "-c", script } },
        .agent = .{ .path = "unused", .timeout_ms = 500 },
        .ghostty_identity = "test",
    });
    defer connection.destroy();
    const id = try connection.request(.{ .id = 0, .op = .create });
    try waitEnded(connection);
    try std.testing.expectEqual(error.RequestTimeout, connection.status().failure.?);
    try std.testing.expectEqual(core.RequestState.uncertain, connection.requestState(id));
}

test "session transport watchdog sleeps while idle instead of polling" {
    const script = fake_prelude ++
        \\send(17, 0, dict(id=request['id'], sessions=[]))
        \\import time; time.sleep(30)
    ;
    const connection = try transport.Connection.create(a, io.get(), .{
        .connector = .{ .argv = &.{ "/usr/bin/python3", "-c", script } },
        .agent = .{ .path = "unused" },
        .ghostty_identity = "test",
    });
    defer connection.destroy();
    _ = try connection.request(.{ .id = 0, .op = .list });
    const reply = try waitMessage(connection, .reply);
    reply.deinit();
    const turns = connection.status().watchdog_turns;
    try std.Io.sleep(io.get(), .fromMilliseconds(200), .awake);
    try std.testing.expect(connection.status().watchdog_turns <= turns + 2);
}

test "session transport stalled writes are canceled without hanging teardown" {
    const script = fake_prelude ++
        \\send(17, 0, dict(id=request['id'], session=dict(id='test', attached=True, revision=0, panes=[dict(id=1, cols=80, rows=24)])))
        \\import time; time.sleep(30)
    ;
    const connection = try transport.Connection.create(a, io.get(), .{
        .connector = .{ .argv = &.{ "/usr/bin/python3", "-c", script } },
        .agent = .{ .path = "unused" },
        .ghostty_identity = "test",
    });
    defer connection.destroy();
    _ = try connection.request(.{ .id = 0, .op = .create });
    const reply = try waitMessage(connection, .reply);
    reply.deinit();
    const input: [p.max_data]u8 = @splat('x');
    while (true) {
        connection.send(.input, 1, &input) catch |err| {
            try std.testing.expectEqual(error.ResourceExhausted, err);
            break;
        };
    }
    try waitEnded(connection);
    try std.testing.expectEqual(error.WriteTimeout, connection.status().failure.?);
}

test "session transport backpressure stays bounded and cancel joins a full receive queue" {
    const script = fake_prelude ++
        \\send(17, 0, dict(id=request['id'], session=dict(id='test', attached=True, revision=0, panes=[dict(id=1, cols=80, rows=24)])))
        \\while True: send(21, 1, b'')
    ;
    const connection = try transport.Connection.create(a, io.get(), .{
        .connector = .{ .argv = &.{ "/usr/bin/python3", "-c", script } },
        .agent = .{ .path = "unused" },
        .ghostty_identity = "test",
    });
    defer connection.destroy();
    _ = try connection.request(.{ .id = 0, .op = .create });
    const deadline = io.nanoTimestamp() + 5 * std.time.ns_per_s;
    while (connection.status().queued_frames < core.queue_frames) {
        if (io.nanoTimestamp() >= deadline) return error.Timeout;
        if (connection.status().phase == .ended) return error.ConnectionEnded;
        try std.Io.sleep(io.get(), .fromMilliseconds(5), .awake);
    }
    try std.testing.expect(connection.status().queued_bytes <= core.queue_bytes);
    connection.close();
    try waitEnded(connection);
}

test "session transport rejects oversized headers before reading any payload" {
    const script = fake_prelude ++
        \\os.write(1, struct.pack('<BII', 19, 1, 16385))
        \\import time; time.sleep(30)
    ;
    const connection = try transport.Connection.create(a, io.get(), .{
        .connector = .{ .argv = &.{ "/usr/bin/python3", "-c", script } },
        .agent = .{ .path = "unused" },
        .ghostty_identity = "test",
    });
    defer connection.destroy();
    _ = try connection.request(.{ .id = 0, .op = .create });
    try waitEnded(connection);
    try std.testing.expectEqual(error.PayloadTooLarge, connection.status().failure.?);
}

test "session transport detaches without killing pane and reattaches through the real owner" {
    const path = std.testing.environ.getAlloc(a, "HOLLOW_TEST_AGENT") catch return error.SkipZigTest;
    defer a.free(path);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io.get(), ".", a);
    defer a.free(dir);
    const private_dir = try std.fmt.allocPrint(a, "{s}/socket", .{dir});
    defer a.free(private_dir);
    const runtime_env = try std.fmt.allocPrint(a, "HOLLOW_SESSION_DIR={s}", .{private_dir});
    defer a.free(runtime_env);
    const state_env = try std.fmt.allocPrint(a, "XDG_STATE_HOME={s}", .{dir});
    defer a.free(state_env);
    const options: transport.Options = .{
        .connector = .{ .argv = &.{ "/usr/bin/env", runtime_env, state_env } },
        .agent = .{ .path = path },
        .ghostty_identity = "test", // VT fallback, readable without linking GUI.
    };
    // Registered before connection cleanup, so the bridge is gone before the
    // owner is killed. Also runs when assertions fail before the second attach.
    defer {
        if (transport.Connection.create(a, io.get(), options)) |cleanup| {
            defer cleanup.destroy();
            _ = cleanup.request(.{ .id = 0, .op = .kill_server }) catch 0;
            if (waitMessage(cleanup, .reply)) |message| message.deinit() else |_| {}
            waitEnded(cleanup) catch {};
        } else |_| {}
    }
    const first = try transport.Connection.create(a, io.get(), options);
    var first_live = true;
    defer if (first_live) first.destroy();
    const create_id = try first.request(.{ .id = 0, .op = .create, .spawn = .{
        .argv = &.{ "/bin/sh", "-c", "printf 'before-detach\\n'; read x; printf 'after-%s\\n' \"$x\"; sleep 30" },
        .shell_integration = false,
    } });
    const created = try waitMessage(first, .reply);
    defer created.deinit();
    try std.testing.expectEqual(create_id, created.request_id.?);
    const reply = try p.parse(p.Reply, a, created.payload);
    defer reply.deinit();
    try std.testing.expect(reply.value.ok);
    const sid = reply.value.session.?.id;
    const pane = reply.value.session.?.panes[0].id;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(a);
    while (std.mem.indexOf(u8, output.items, "before-detach") == null) {
        const message = try waitMessage(first, .output);
        defer message.deinit();
        try output.appendSlice(a, message.payload);
        try first.consumed(message);
    }
    first.destroy();
    first_live = false;
    const second = try transport.Connection.create(a, io.get(), options);
    defer second.destroy();
    _ = try second.request(.{ .id = 0, .op = .list });
    const listed = try waitMessage(second, .reply);
    defer listed.deinit();
    const list = try p.parse(p.Reply, a, listed.payload);
    defer list.deinit();
    try std.testing.expectEqualStrings(sid, list.value.sessions.?[0].id);
    try std.testing.expect(!list.value.sessions.?[0].attached);
    _ = try second.request(.{ .id = 0, .op = .attach, .session = sid });
    const attached = try waitMessage(second, .reply);
    attached.deinit();
    output.clearRetainingCapacity();
    const snapshot_deadline = io.nanoTimestamp() + 5 * std.time.ns_per_s;
    while (true) {
        if (io.nanoTimestamp() >= snapshot_deadline) return error.Timeout;
        const message = second.poll() orelse {
            try std.Io.sleep(io.get(), .fromMilliseconds(5), .awake);
            continue;
        };
        defer message.deinit();
        if (message.kind == .snapshot) try output.appendSlice(a, message.payload);
        if (message.kind == .snapshot_end) break;
    }
    try std.testing.expect(std.mem.indexOf(u8, output.items, "before-detach") != null);
    try second.send(.input, pane, "works\n");
    output.clearRetainingCapacity();
    while (std.mem.indexOf(u8, output.items, "after-works") == null) {
        const message = try waitMessage(second, .output);
        defer message.deinit();
        try output.appendSlice(a, message.payload);
        try second.consumed(message);
    }
    // New panes share the session, but close affects only its target.
    _ = try second.request(.{ .id = 0, .op = .spawn, .spawn = .{
        .argv = &.{ "/bin/sh", "-c", "head -c 200000 /dev/zero | tr '\\000' y; printf 'flow-end'; sleep 30" },
        .shell_integration = false,
    } });
    const spawned = try waitMessage(second, .reply);
    defer spawned.deinit();
    const spawn_reply = try p.parse(p.Reply, a, spawned.payload);
    defer spawn_reply.deinit();
    const sibling = spawn_reply.value.pane.?;
    output.clearRetainingCapacity();
    while (std.mem.indexOf(u8, output.items, "flow-end") == null) {
        const message = try waitMessage(second, .output);
        defer message.deinit();
        if (message.pane == sibling) try output.appendSlice(a, message.payload);
        try second.consumed(message);
    }
    try std.testing.expect(output.items.len > p.window);
    _ = try second.request(.{ .id = 0, .op = .close, .pane = pane });
    const closed = try waitMessage(second, .reply);
    closed.deinit();
    _ = try second.request(.{ .id = 0, .op = .list });
    const remaining = try waitMessage(second, .reply);
    defer remaining.deinit();
    const remaining_reply = try p.parse(p.Reply, a, remaining.payload);
    defer remaining_reply.deinit();
    try std.testing.expectEqual(@as(usize, 1), remaining_reply.value.sessions.?[0].panes.len);
    try std.testing.expectEqual(sibling, remaining_reply.value.sessions.?[0].panes[0].id);
    // Take-over is an event, not connector loss or a remote kill.
    const third = try transport.Connection.create(a, io.get(), options);
    defer third.destroy();
    _ = try third.request(.{ .id = 0, .op = .attach, .session = sid });
    const third_attached = try waitMessage(third, .reply);
    third_attached.deinit();
    const taken = try waitMessage(second, .event);
    defer taken.deinit();
    const event = try p.parse(p.Event, a, taken.payload);
    defer event.deinit();
    try std.testing.expectEqual(p.EventKind.taken, event.value.event);
    try std.testing.expectError(error.NotAttached, second.send(.input, sibling, "ignored"));
}
