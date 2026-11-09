//! Real ConPTY sessions through private, process-owned named-pipe fixtures.
const std = @import("std");
const testing = std.testing;
const a = testing.allocator;
const windows = std.os.windows;
const io = @import("io.zig");
const owner = @import("agent/session_windows.zig");
const pipe = @import("agent/session_pipe_windows.zig");
const p = @import("agent/session_protocol.zig");

extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn Sleep(u32) callconv(.winapi) void;
extern "kernel32" fn WaitForSingleObject(windows.HANDLE, u32) callconv(.winapi) u32;
extern "kernel32" fn OpenProcess(u32, windows.BOOL, u32) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn CloseHandle(windows.HANDLE) callconv(.winapi) windows.BOOL;

const session_id = "0123456789abcdef0123456789abcdef";
const capture_limit = 2 * 1024 * 1024;
var serial: u32 = 0;

fn executable() ![]u8 {
    const path = @import("build_options").windows_owner_exe;
    if (!std.mem.startsWith(u8, path, "/")) return a.dupe(u8, path);
    const distro = try io.getEnvVarOwned(a, "WSL_DISTRO_NAME");
    defer a.free(distro);
    const result = try std.fmt.allocPrint(a, "\\\\wsl.localhost\\{s}{s}", .{ distro, path });
    std.mem.replaceScalar(u8, result, '/', '\\');
    return result;
}

const Fixture = struct {
    namespace: []u8,
    child: std.process.Child,

    fn init() !Fixture {
        serial += 1;
        const namespace = try std.fmt.allocPrint(a, "live-owner-test-{d}-{d}-{d}", .{ GetCurrentProcessId(), GetTickCount64(), serial });
        errdefer a.free(namespace);
        const exe = try executable();
        defer a.free(exe);
        return .{ .namespace = namespace, .child = try std.process.spawn(io.get(), .{
            .argv = &.{ exe, "session", "serve", "--namespace", namespace },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .inherit,
            .create_no_window = true,
        }) };
    }

    fn connect(self: *Fixture) !Client {
        return self.connectFormat(false);
    }

    fn connectFormat(self: *Fixture, binary: bool) !Client {
        var endpoint = try pipe.Endpoint.init(a, self.namespace);
        defer endpoint.deinit(a);
        const deadline = GetTickCount64() + 10_000;
        while (GetTickCount64() < deadline) {
            const handle = endpoint.connect() catch |err| switch (err) {
                error.PipeBusy => null,
                else => return err,
            };
            if (handle) |h| {
                var client: Client = .{ .connection = try owner.Connection.init(a, h) };
                errdefer client.deinit();
                try client.connection.sendJson(.hello, p.Hello{
                    .protocol = p.protocol,
                    .version = p.version,
                    .ghostty = if (binary) @import("agent/session_vt.zig").buildIdentity() else "fixture-mismatch",
                    .client = "live-owner-test",
                });
                const frame = try client.connection.next(5000);
                try testing.expectEqual(p.Kind.welcome, frame.kind);
                const welcome = try p.parse(p.Welcome, a, frame.payload);
                defer welcome.deinit();
                try testing.expectEqual(if (binary) p.SnapshotFormat.binary else p.SnapshotFormat.vt, welcome.value.snapshot);
                try testing.expect(!std.mem.eql(u8, "bootstrap", welcome.value.ghostty));
                try testing.expect(p.hasFeature(welcome.value.features, "create-id"));
                try testing.expect(!p.hasFeature(welcome.value.features, "respawn"));
                return client;
            }
            Sleep(10);
        }
        return error.FixtureStartupTimeout;
    }

    fn deinit(self: *Fixture) void {
        // Cleanup is scoped to this namespace and the exact spawned process.
        if (WaitForSingleObject(self.child.id.?, 0) != 0) {
            if (self.connect()) |value| {
                var client = value;
                client.connection.sendJson(.request, p.Request{ .id = 999, .op = .kill_server }) catch {};
                _ = WaitForSingleObject(self.child.id.?, 10_000);
                client.deinit();
            } else |_| {}
        }
        self.child.kill(io.get());
        a.free(self.namespace);
    }
};

const Client = struct {
    connection: owner.Connection,
    bytes: std.ArrayList(u8) = .empty,
    snapshot_ended: bool = false,
    snapshot_bytes: usize = 0,
    output_bytes: usize = 0,
    auto_credit: bool = true,
    exit: ?i32 = null,
    taken: bool = false,

    fn deinit(self: *Client) void {
        self.connection.deinit();
        self.bytes.deinit(a);
    }

    fn credit(self: *Client, count: usize) !void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, @intCast(count), .little);
        try self.connection.send(.credit, 1, &bytes);
    }

    fn consume(self: *Client, frame: owner.Frame) !void {
        switch (frame.kind) {
            .snapshot, .output => {
                try testing.expectEqual(@as(u32, 1), frame.stream);
                if (frame.kind == .snapshot) {
                    try testing.expect(!self.snapshot_ended);
                    self.snapshot_bytes += frame.payload.len;
                } else {
                    // A live byte must never overtake its snapshot barrier.
                    try testing.expect(self.snapshot_ended);
                    self.output_bytes += frame.payload.len;
                }
                if (frame.payload.len > capture_limit - self.bytes.items.len) return error.CaptureLimit;
                try self.bytes.appendSlice(a, frame.payload);
                if (frame.kind == .output and self.auto_credit) try self.credit(frame.payload.len);
            },
            .snapshot_end => {
                try testing.expectEqual(@as(u32, 1), frame.stream);
                try testing.expect(!self.snapshot_ended);
                self.snapshot_ended = true;
            },
            .exit => self.exit = try p.decodeExit(frame.payload),
            .event => {
                const event = try p.parse(p.Event, a, frame.payload);
                defer event.deinit();
                if (event.value.event == .taken) self.taken = true;
            },
            else => return error.UnexpectedFrame,
        }
    }

    fn request(self: *Client, value: p.Request) !std.json.Parsed(p.Reply) {
        try self.connection.sendJson(.request, value);
        const deadline = GetTickCount64() + 15_000;
        while (GetTickCount64() < deadline) {
            const frame = try self.connection.next(5000);
            if (frame.kind != .reply) {
                try self.consume(frame);
                continue;
            }
            const reply = try p.parse(p.Reply, a, frame.payload);
            errdefer reply.deinit();
            try testing.expectEqual(value.id, reply.value.id);
            return reply;
        }
        return error.ReplyTimeout;
    }

    fn ok(self: *Client, value: p.Request) !void {
        const reply = try self.request(value);
        defer reply.deinit();
        if (!reply.value.ok) std.debug.print("live owner {s}: {s}\n", .{ @tagName(value.op), reply.value.@"error" orelse "missing error" });
        try testing.expect(reply.value.ok);
    }

    fn rejected(self: *Client, value: p.Request, expected: ?[]const u8) !void {
        const reply = try self.request(value);
        defer reply.deinit();
        try testing.expect(!reply.value.ok);
        const err = reply.value.@"error" orelse return error.MissingError;
        if (expected) |name| try testing.expectEqualStrings(name, err);
    }

    fn create(self: *Client, script: []const u8) !void {
        const reply = try self.request(.{ .id = 1, .op = .create, .create_id = session_id, .spawn = .{
            .argv = &.{ "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script },
            .shell_integration = false,
            .cols = 120,
            .rows = 30,
        } });
        defer reply.deinit();
        if (!reply.value.ok) std.debug.print("create: {s}\n", .{reply.value.@"error" orelse "missing error"});
        try testing.expect(reply.value.ok);
        const session = reply.value.session orelse return error.MissingSession;
        try testing.expectEqualStrings(session_id, session.id);
        try testing.expect(session.attached);
        try testing.expectEqual(@as(usize, 1), session.panes.len);
        try testing.expectEqual(@as(u32, 1), session.panes[0].id);
    }

    fn until(self: *Client, marker: []const u8) !void {
        const deadline = GetTickCount64() + 30_000;
        while (GetTickCount64() < deadline) {
            if (self.snapshot_ended and std.mem.indexOf(u8, self.bytes.items, marker) != null) return;
            try self.consume(try self.connection.next(5000));
        }
        return error.MarkerTimeout;
    }

    fn snapshot(self: *Client) !void {
        const deadline = GetTickCount64() + 15_000;
        while (!self.snapshot_ended) {
            if (GetTickCount64() >= deadline) return error.SnapshotTimeout;
            try self.consume(try self.connection.next(5000));
        }
    }

    fn attach(self: *Client) !void {
        self.snapshot_ended = false;
        self.snapshot_bytes = 0;
        self.bytes.clearRetainingCapacity();
        try self.ok(.{ .id = 2, .op = .attach, .session = session_id, .panes = &.{.{ .pane = 1, .cols = 120, .rows = 30 }} });
        try self.snapshot();
    }

    fn listed(self: *Client, attached: bool) !std.json.Parsed(p.Reply) {
        const reply = try self.request(.{ .id = 10, .op = .list });
        errdefer reply.deinit();
        try testing.expect(reply.value.ok);
        const sessions = reply.value.sessions orelse return error.MissingSessions;
        try testing.expectEqual(@as(usize, 1), sessions.len);
        try testing.expectEqualStrings(session_id, sessions[0].id);
        try testing.expectEqual(attached, sessions[0].attached);
        try testing.expectEqual(@as(usize, 1), sessions[0].panes.len);
        try testing.expectEqual(@as(u32, 1), sessions[0].panes[0].id);
        return reply;
    }

    fn empty(self: *Client) !void {
        const reply = try self.request(.{ .id = 11, .op = .list });
        defer reply.deinit();
        try testing.expect(reply.value.ok);
        try testing.expectEqual(@as(usize, 0), (reply.value.sessions orelse return error.MissingSessions).len);
    }
};

const waiting = "[Console]::WriteLine('READY'); $null=[Console]::ReadLine(); Start-Sleep -Seconds 120";

test "Windows matching build negotiates and restores live binary snapshot" {
    const vt = @import("agent/session_vt.zig");
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var client = try fixture.connectFormat(true);
    defer client.deinit();
    try client.create(waiting);
    try client.until("READY");
    try client.ok(.{ .id = 3, .op = .detach });
    try client.attach();
    const terminal = try vt.restore(client.bytes.items, 1024 * 1024);
    defer vt.freeTerminal(terminal);
    const text = try vt.plain(terminal, a);
    defer a.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "READY") != null);
}

test "Windows live owner reconnect preserves history and in-process state" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var first = try fixture.connect();
    var first_open = true;
    defer if (first_open) first.deinit();
    try first.create("$state=[guid]::NewGuid().ToString('N'); [Console]::WriteLine('HISTORY-'+$state); [Console]::WriteLine('READY'); $line=[Console]::ReadLine(); [Console]::WriteLine('CONTINUED-'+$state+'-'+$line); Start-Sleep -Seconds 120");
    try first.until("READY");
    const offset = (std.mem.indexOf(u8, first.bytes.items, "HISTORY-") orelse return error.MissingHistory) + "HISTORY-".len;
    try testing.expect(first.bytes.items.len >= offset + 32);
    const state = first.bytes.items[offset..][0..32].*;
    first.deinit();
    first_open = false;

    var second = try fixture.connect();
    defer second.deinit();
    // Disconnect processing is asynchronous; list until the old attachment clears.
    const deadline = GetTickCount64() + 5000;
    while (true) {
        const reply = try second.request(.{ .id = 3, .op = .list });
        defer reply.deinit();
        const sessions = reply.value.sessions orelse return error.MissingSessions;
        try testing.expectEqual(@as(usize, 1), sessions.len);
        try testing.expectEqualStrings(session_id, sessions[0].id);
        if (!sessions[0].attached) break;
        if (GetTickCount64() >= deadline) return error.DetachTimeout;
        Sleep(10);
    }
    try second.attach();
    const history = try std.fmt.allocPrint(a, "HISTORY-{s}", .{state});
    defer a.free(history);
    try testing.expect(std.mem.indexOf(u8, second.bytes.items, history) != null);
    try second.connection.send(.input, 1, "resume\r");
    const continued = try std.fmt.allocPrint(a, "CONTINUED-{s}-resume", .{state});
    defer a.free(continued);
    try second.until(continued);
    const listed = try second.listed(true);
    defer listed.deinit();
}

test "Windows live owner collision precedes spawn validation and never takes attachment" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var first = try fixture.connect();
    defer first.deinit();
    try first.create(waiting);
    try first.until("READY");
    var second = try fixture.connect();
    defer second.deinit();
    // Invalid executable would fail differently if create reached child launch.
    try second.rejected(.{ .id = 2, .op = .create, .create_id = session_id, .spawn = .{ .argv = &.{"Z:\\hollow-missing\\collision.exe"} } }, "SessionExists");
    const listed = try second.listed(true);
    defer listed.deinit();
    // Original client's ability to mutate proves no implicit attachment takeover.
    try first.ok(.{ .id = 3, .op = .layout, .revision = listed.value.sessions.?[0].revision, .layout = "original-client" });
    try first.ok(.{ .id = 4, .op = .detach });
    const detached = try second.listed(false);
    defer detached.deinit();
    try second.ok(.{ .id = 5, .op = .kill, .session = session_id });
    try second.empty();
}

test "Windows live owner takeover notifies old client and rejects stale input" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var first = try fixture.connect();
    defer first.deinit();
    try first.create("[Console]::WriteLine('READY'); $line=[Console]::ReadLine(); [Console]::WriteLine('CONTROL-'+$line); Start-Sleep -Seconds 120");
    try first.until("READY");
    var second = try fixture.connect();
    defer second.deinit();
    try second.attach();
    const deadline = GetTickCount64() + 5000;
    while (!first.taken) {
        if (GetTickCount64() >= deadline) return error.TakeoverTimeout;
        try first.consume(try first.connection.next(1000));
    }
    // Send may succeed before the server rejects the stale controller. Neither
    // that submission nor old-client cleanup may reach the new attachment.
    first.connection.send(.input, 1, "stale\r") catch {};
    try second.connection.send(.input, 1, "current\r");
    try second.until("CONTROL-current");
    try testing.expect(std.mem.indexOf(u8, second.bytes.items, "CONTROL-stale") == null);
    const listed = try second.listed(true);
    defer listed.deinit();
}

test "Windows live owner invalid spawn cwd and size leave no session" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var client = try fixture.connect();
    defer client.deinit();
    const bad = [_]p.Spawn{
        .{ .argv = &.{"Z:\\hollow-missing\\missing.exe"} },
        .{ .argv = &.{ "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", "exit 0" }, .cwd = "Z:\\hollow-missing\\cwd" },
        .{ .argv = &.{"powershell.exe"}, .cols = 0 },
        .{ .argv = &.{"powershell.exe"}, .rows = 0 },
    };
    for (bad) |spawn| {
        try client.rejected(.{ .id = 1, .op = .create, .create_id = session_id, .spawn = spawn }, null);
        try client.empty();
    }
}

test "Windows live owner retains raw root exit and layout CAS preserves current layout" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var client = try fixture.connect();
    defer client.deinit();
    try client.create("[Console]::WriteLine('FINITE-OUTPUT'); exit 301");
    try client.until("FINITE-OUTPUT");
    const deadline = GetTickCount64() + 15_000;
    while (client.exit == null) {
        if (GetTickCount64() >= deadline) return error.ExitTimeout;
        try client.consume(try client.connection.next(5000));
    }
    try testing.expectEqual(@as(?i32, 301), client.exit);
    const initial = try client.listed(true);
    defer initial.deinit();
    try testing.expectEqual(@as(?i32, 301), initial.value.sessions.?[0].panes[0].exit);
    const revision = initial.value.sessions.?[0].revision;
    try client.ok(.{ .id = 4, .op = .layout, .revision = revision, .layout = "kept-layout" });
    for ([_]?u64{ null, revision }) |stale| {
        const conflict = try client.request(.{ .id = 5, .op = .layout, .revision = stale, .layout = "must-not-replace" });
        defer conflict.deinit();
        try testing.expect(!conflict.value.ok);
        try testing.expectEqualStrings("RevisionConflict", conflict.value.@"error" orelse return error.MissingError);
        try testing.expectEqual(@as(?u64, revision + 1), conflict.value.revision);
    }
    const retained = try client.listed(true);
    defer retained.deinit();
    try testing.expectEqualStrings("kept-layout", retained.value.sessions.?[0].layout);
    try testing.expectEqual(revision + 1, retained.value.sessions.?[0].revision);
    for ([_]p.Op{ .spawn, .close, .respawn }) |op| try client.rejected(.{ .id = 6, .op = op, .pane = 1, .spawn = .{} }, "Unsupported");
    try client.ok(.{ .id = 7, .op = .kill, .session = session_id });
    try client.empty();
}

test "Windows live owner snapshot precedes output and credit bounds long output" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var client = try fixture.connect();
    defer client.deinit();
    try client.create("[Console]::WriteLine('READY'); $null=[Console]::ReadLine(); $line='X'*80; for($i=0;$i -lt 5000;$i++){[Console]::WriteLine($line)}; [Console]::WriteLine('BURST-DONE'); $null=[Console]::ReadLine(); [Console]::WriteLine('AFTER-SNAPSHOT'); Start-Sleep -Seconds 120");
    try client.until("READY");
    try testing.expect(client.snapshot_ended);
    const baseline = client.output_bytes;
    client.auto_credit = false;
    try client.connection.send(.input, 1, "burst\r");
    const deadline = GetTickCount64() + 30_000;
    while (client.output_bytes - baseline < p.window) {
        if (GetTickCount64() >= deadline) return error.CreditWindowTimeout;
        try client.consume(try client.connection.next(5000));
        try testing.expect(client.output_bytes - baseline <= p.window);
    }
    // A timeout here proves the next byte waits for credit, not an unbounded queue.
    try testing.expectError(error.Timeout, client.connection.next(200));
    client.auto_credit = true;
    try client.credit(p.window);
    try client.until("BURST-DONE");
    try testing.expect(client.output_bytes - baseline > 300 * 1024);
    try client.ok(.{ .id = 3, .op = .detach });
    try client.attach();
    try testing.expect(client.snapshot_bytes > p.max_data);
    try client.connection.send(.input, 1, "continue\r");
    try client.until("AFTER-SNAPSHOT");
    const resize = p.encodeResize(100, 25);
    try client.connection.send(.resize, 1, &resize);
    // Requests on the same connection are processed after resize.
    const listed = try client.listed(true);
    defer listed.deinit();
    try testing.expectEqual(@as(u16, 100), listed.value.sessions.?[0].panes[0].cols);
    try testing.expectEqual(@as(u16, 25), listed.value.sessions.?[0].panes[0].rows);
}

test "Windows snapshot larger than transport queue completes without another child wake" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var client = try fixture.connect();
    defer client.deinit();
    try client.ok(.{ .id = 1, .op = .create, .create_id = session_id, .spawn = .{
        .cols = 1024,
        .rows = 1300,
        .argv = &.{ "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", "[Console]::Write((('X'*1024)+[Environment]::NewLine)*1300); [Console]::WriteLine('LARGE_READY'); $null=[Console]::ReadLine(); Start-Sleep -Seconds 120" },
        .shell_integration = false,
    } });
    try client.until("LARGE_READY");
    try client.ok(.{ .id = 2, .op = .detach });
    client.snapshot_ended = false;
    client.snapshot_bytes = 0;
    client.bytes.clearRetainingCapacity();
    // Keep the large screen dimensions, and send nothing while waiting for its
    // snapshot. Only transport completions can release the retained suffix.
    try client.ok(.{ .id = 3, .op = .attach, .session = session_id });
    try client.snapshot();
    try testing.expect(client.snapshot_bytes > 1024 * 1024);
    try testing.expect(std.mem.indexOf(u8, client.bytes.items, "LARGE_READY") != null);
}

fn descendant(client: *Client) !windows.HANDLE {
    try client.create("$child=Start-Process powershell.exe -ArgumentList '-NoProfile -NonInteractive -Command Start-Sleep -Seconds 120' -PassThru -WindowStyle Hidden; [Console]::WriteLine('CHILD-'+$child.Id+'-READY'); $null=[Console]::ReadLine(); Start-Sleep -Seconds 120");
    try client.until("-READY");
    const start = (std.mem.indexOf(u8, client.bytes.items, "CHILD-") orelse return error.MissingChild) + 6;
    const end = std.mem.indexOfScalarPos(u8, client.bytes.items, start, '-') orelse return error.MissingChild;
    const pid = try std.fmt.parseInt(u32, client.bytes.items[start..end], 10);
    const handle = OpenProcess(0x00100000, .FALSE, pid) orelse return error.OpenProcessFailed;
    errdefer _ = CloseHandle(handle);
    try testing.expectEqual(@as(u32, 258), WaitForSingleObject(handle, 0));
    return handle;
}

test "Windows live owner kill and kill-server terminate descendant jobs and retain ACK" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var client = try fixture.connect();
    defer client.deinit();
    const child = try descendant(&client);
    defer _ = CloseHandle(child);
    try client.ok(.{ .id = 3, .op = .kill, .session = session_id });
    try testing.expectEqual(@as(u32, 0), WaitForSingleObject(child, 10_000));
    try client.empty();
    // New session on the same owner, with its own descendant tree.
    client.snapshot_ended = false;
    client.bytes.clearRetainingCapacity();
    const second = try descendant(&client);
    defer _ = CloseHandle(second);
    try client.ok(.{ .id = 4, .op = .detach });
    // Drain attachment output before shutdown, then deliberately delay ACK read.
    try client.connection.sendJson(.request, p.Request{ .id = 5, .op = .kill_server });
    try testing.expectEqual(@as(u32, 0), WaitForSingleObject(fixture.child.id.?, 10_000));
    try testing.expectEqual(@as(u32, 0), WaitForSingleObject(second, 10_000));
    const frame = try client.connection.next(5000);
    try testing.expectEqual(p.Kind.reply, frame.kind);
    const ack = try p.parse(p.Reply, a, frame.payload);
    defer ack.deinit();
    try testing.expectEqual(@as(u64, 5), ack.value.id);
    try testing.expect(ack.value.ok);
}
