//! Multi-pane ConPTY regressions, isolated by process-owned fixture namespaces.
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

const session_id = "abcdef0123456789abcdef0123456789";
const layout = "opaque: keep this even when pane membership changes";
const capture_limit = 2 * 1024 * 1024;
var serial: u32 = 0;

const Fixture = struct {
    namespace: []u8,
    child: std.process.Child,

    fn init() !Fixture {
        serial += 1;
        const namespace = try std.fmt.allocPrint(a, "multi-owner-test-{d}-{d}-{d}", .{ GetCurrentProcessId(), GetTickCount64(), serial });
        errdefer a.free(namespace);
        const path = @import("build_options").windows_owner_exe;
        const exe = if (std.mem.startsWith(u8, path, "/")) blk: {
            const distro = try io.getEnvVarOwned(a, "WSL_DISTRO_NAME");
            defer a.free(distro);
            const result = try std.fmt.allocPrint(a, "\\\\wsl.localhost\\{s}{s}", .{ distro, path });
            std.mem.replaceScalar(u8, result, '/', '\\');
            break :blk result;
        } else try a.dupe(u8, path);
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
                try client.connection.sendJson(.hello, p.Hello{ .protocol = p.protocol, .version = p.version, .ghostty = "multi-fixture-vt", .client = "multi-owner-test" });
                const frame = try client.connection.next(5000);
                try testing.expectEqual(p.Kind.welcome, frame.kind);
                const welcome = try p.parse(p.Welcome, a, frame.payload);
                defer welcome.deinit();
                try testing.expectEqual(p.SnapshotFormat.vt, welcome.value.snapshot);
                try testing.expect(p.hasFeature(welcome.value.features, "respawn"));
                try testing.expect(p.hasFeature(welcome.value.features, "create-id"));
                try testing.expect(p.validHost(welcome.value.host));
                return client;
            }
            Sleep(10);
        }
        return error.FixtureStartupTimeout;
    }

    fn deinit(self: *Fixture) void {
        // No process-name cleanup, production endpoint, or persistent-state path.
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

const Stream = struct {
    bytes: std.ArrayList(u8) = .empty,
    snapshot_ended: bool = false,
    snapshot_bytes: usize = 0,
    output_bytes: usize = 0,
    auto_credit: bool = true,
    exit: ?i32 = null,
};

const Client = struct {
    connection: owner.Connection,
    // Tests allocate only IDs 1..3; the bound also catches accidental reuse or
    // cross-session stream IDs without building an unbounded capture map.
    streams: [16]Stream = @splat(.{}),
    next_id: u64 = 1,
    taken: bool = false,
    ended: bool = false,

    fn deinit(self: *Client) void {
        self.connection.deinit();
        for (&self.streams) |*s| s.bytes.deinit(a);
    }

    fn stream(self: *Client, id: u32) !*Stream {
        if (id == 0 or id > self.streams.len) return error.InvalidStream;
        return &self.streams[id - 1];
    }

    fn credit(self: *Client, id: u32, count: usize) !void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, @intCast(count), .little);
        try self.connection.send(.credit, id, &bytes);
    }

    fn consume(self: *Client, frame: owner.Frame) !void {
        switch (frame.kind) {
            .snapshot, .output => {
                const s = try self.stream(frame.stream);
                if (frame.kind == .snapshot) {
                    try testing.expect(!s.snapshot_ended);
                    s.snapshot_bytes += frame.payload.len;
                } else {
                    try testing.expect(s.snapshot_ended);
                    s.output_bytes += frame.payload.len;
                }
                if (frame.payload.len > capture_limit - s.bytes.items.len) return error.CaptureLimit;
                try s.bytes.appendSlice(a, frame.payload);
                if (frame.kind == .output and s.auto_credit) try self.credit(frame.stream, frame.payload.len);
            },
            .snapshot_end => {
                const s = try self.stream(frame.stream);
                try testing.expect(!s.snapshot_ended);
                s.snapshot_ended = true;
            },
            .exit => (try self.stream(frame.stream)).exit = try p.decodeExit(frame.payload),
            .event => {
                try testing.expectEqual(@as(u32, 0), frame.stream);
                const event = try p.parse(p.Event, a, frame.payload);
                defer event.deinit();
                try testing.expectEqualStrings(session_id, event.value.session);
                switch (event.value.event) {
                    .taken => self.taken = true,
                    .session_end => self.ended = true,
                    .resync => return error.UnexpectedResync,
                }
            },
            else => return error.UnexpectedFrame,
        }
    }

    fn request(self: *Client, value: p.Request) !std.json.Parsed(p.Reply) {
        var req = value;
        req.id = self.next_id;
        self.next_id += 1;
        try self.connection.sendJson(.request, req);
        const deadline = GetTickCount64() + 15_000;
        while (GetTickCount64() < deadline) {
            const frame = try self.connection.next(5000);
            if (frame.kind != .reply) {
                try self.consume(frame);
                continue;
            }
            try testing.expectEqual(@as(u32, 0), frame.stream);
            const reply = try p.parse(p.Reply, a, frame.payload);
            errdefer reply.deinit();
            try testing.expectEqual(req.id, reply.value.id);
            return reply;
        }
        return error.ReplyTimeout;
    }

    fn ok(self: *Client, req: p.Request) !void {
        const reply = try self.request(req);
        defer reply.deinit();
        if (!reply.value.ok) std.debug.print("multi owner {s}: {s}\n", .{ @tagName(req.op), reply.value.@"error" orelse "missing error" });
        try testing.expect(reply.value.ok);
    }

    fn rejected(self: *Client, req: p.Request, expected: ?[]const u8) !void {
        const reply = try self.request(req);
        defer reply.deinit();
        try testing.expect(!reply.value.ok);
        if (expected) |name| try testing.expectEqualStrings(name, reply.value.@"error" orelse return error.MissingError);
    }

    fn create(self: *Client, script: []const u8) !void {
        const reply = try self.request(.{ .id = 0, .op = .create, .create_id = session_id, .spawn = .{
            .argv = &.{ "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script },
            .shell_integration = false,
            .cols = 120,
            .rows = 30,
        } });
        defer reply.deinit();
        try testing.expect(reply.value.ok);
        const session = reply.value.session orelse return error.MissingSession;
        try testing.expectEqual(@as(u64, 0), session.revision);
        try testing.expectEqual(@as(usize, 1), session.panes.len);
        try testing.expectEqual(@as(u32, 1), session.panes[0].id);
    }

    fn spawn(self: *Client, script: []const u8, id: u32, revision: u64) !void {
        const reply = try self.request(.{ .id = 0, .op = .spawn, .spawn = .{
            .argv = &.{ "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script },
            .shell_integration = false,
            .cols = 120,
            .rows = 30,
        } });
        defer reply.deinit();
        try testing.expect(reply.value.ok);
        try testing.expectEqual(@as(?u32, id), reply.value.pane);
        try testing.expectEqual(@as(?u64, revision), reply.value.revision);
    }

    fn listed(self: *Client, ids: []const u32, revision: u64, blob: []const u8) !std.json.Parsed(p.Reply) {
        const reply = try self.request(.{ .id = 0, .op = .list });
        errdefer reply.deinit();
        try testing.expect(reply.value.ok);
        const sessions = reply.value.sessions orelse return error.MissingSessions;
        try testing.expectEqual(@as(usize, 1), sessions.len);
        const session = sessions[0];
        try testing.expectEqualStrings(session_id, session.id);
        try testing.expect(session.attached);
        try testing.expectEqual(revision, session.revision);
        try testing.expectEqualStrings(blob, session.layout);
        try testing.expectEqual(ids.len, session.panes.len);
        for (ids, session.panes) |id, pane| try testing.expectEqual(id, pane.id);
        return reply;
    }

    fn until(self: *Client, id: u32, marker: []const u8) !void {
        const s = try self.stream(id);
        const deadline = GetTickCount64() + 30_000;
        while (GetTickCount64() < deadline) {
            if (s.snapshot_ended and std.mem.indexOf(u8, s.bytes.items, marker) != null) return;
            try self.consume(try self.connection.next(5000));
        }
        return error.MarkerTimeout;
    }

    fn exited(self: *Client, id: u32, expected: i32) !void {
        const s = try self.stream(id);
        const deadline = GetTickCount64() + 20_000;
        while (s.exit == null) {
            if (GetTickCount64() >= deadline) return error.ExitTimeout;
            try self.consume(try self.connection.next(5000));
        }
        try testing.expectEqual(@as(?i32, expected), s.exit);
    }

    fn attach(self: *Client, ids: []const u32) !void {
        for (ids) |id| {
            const s = try self.stream(id);
            s.snapshot_ended = false;
            s.snapshot_bytes = 0;
            s.bytes.clearRetainingCapacity();
        }
        try self.ok(.{ .id = 0, .op = .attach, .session = session_id });
        const deadline = GetTickCount64() + 15_000;
        for (ids) |id| while (!(try self.stream(id)).snapshot_ended) {
            if (GetTickCount64() >= deadline) return error.SnapshotTimeout;
            try self.consume(try self.connection.next(5000));
        };
    }
};

const waiting = "[Console]::WriteLine('READY'); while($true){$line=[Console]::ReadLine(); if($null -eq $line){break}; [Console]::WriteLine('ANSWER-'+$line)}";

test "Windows multi-pane membership preserves opaque layout and surviving stream identity" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var client = try fixture.connect();
    defer client.deinit();
    try client.create("$state='one'; [Console]::WriteLine('ONE-READY'); while($true){$line=[Console]::ReadLine(); [Console]::WriteLine($state+'-'+$line)}");
    try client.until(1, "ONE-READY");
    try client.ok(.{ .id = 0, .op = .layout, .revision = 0, .layout = layout });
    // Failed launch cannot consume the next ID, revise membership, or fall back.
    try client.rejected(.{ .id = 0, .op = .spawn, .spawn = .{ .argv = &.{"Z:\\hollow-multi-missing\\missing.exe"} } }, null);
    const failed = try client.listed(&.{1}, 1, layout);
    failed.deinit();
    try client.spawn(waiting, 2, 2);
    try client.until(2, "READY");
    try testing.expect(std.mem.indexOf(u8, client.streams[1].bytes.items, "ONE-READY") == null);
    try client.connection.send(.input, 2, "two-only\r");
    try client.until(2, "ANSWER-two-only");
    try testing.expect(std.mem.indexOf(u8, client.streams[0].bytes.items, "ANSWER-two-only") == null);
    const both = try client.listed(&.{ 1, 2 }, 2, layout);
    both.deinit();
    try client.ok(.{ .id = 0, .op = .close, .pane = 1 });
    const survivor = try client.listed(&.{2}, 3, layout);
    survivor.deinit();
    // Delayed frames for a removed pane must not tear down its sibling.
    try client.credit(1, 1);
    try client.connection.send(.input, 1, "stale\r");
    const size = p.encodeResize(101, 27);
    try client.connection.send(.resize, 2, &size);
    try client.credit(2, 1);
    try client.connection.send(.input, 2, "after-close\r");
    try client.until(2, "ANSWER-after-close");
    const resized = try client.listed(&.{2}, 3, layout);
    defer resized.deinit();
    try testing.expectEqual(@as(u16, 101), resized.value.sessions.?[0].panes[0].cols);
    try testing.expectEqual(@as(u16, 27), resized.value.sessions.?[0].panes[0].rows);
    try client.ok(.{ .id = 0, .op = .detach });
    try client.attach(&.{2});
    try testing.expect(client.streams[1].snapshot_bytes > 0);
    try testing.expect(std.mem.indexOf(u8, client.streams[1].bytes.items, "ANSWER-after-close") != null);
    try client.spawn(waiting, 3, 4);
    try client.until(3, "READY");
    try client.ok(.{ .id = 0, .op = .close, .pane = 2 });
    const last = try client.listed(&.{3}, 5, layout);
    last.deinit();
    try client.ok(.{ .id = 0, .op = .close, .pane = 3 });
    // request() consumes asynchronous frames: this assertion catches end before ACK.
    try testing.expect(!client.ended);
    const deadline = GetTickCount64() + 5000;
    while (!client.ended) {
        if (GetTickCount64() >= deadline) return error.SessionEndTimeout;
        try client.consume(try client.connection.next(5000));
    }
    const empty = try client.request(.{ .id = 0, .op = .list });
    defer empty.deinit();
    try testing.expect(empty.value.ok);
    try testing.expectEqual(@as(usize, 0), empty.value.sessions.?.len);
    try testing.expectEqual(@as(u32, 258), WaitForSingleObject(fixture.child.id.?, 0));
}

test "Windows multi-pane blocked input and output credit cannot starve sibling progress" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var client = try fixture.connect();
    defer client.deinit();
    try client.create("[Console]::WriteLine('FLOOD-READY'); $null=[Console]::ReadLine(); for($i=0;$i -lt 5000;$i++){[Console]::WriteLine('X'*80)}; [Console]::WriteLine('FLOOD-DONE'); Start-Sleep -Seconds 120");
    try client.until(1, "FLOOD-READY");
    try client.spawn(waiting, 2, 1);
    try client.until(2, "READY");
    const baseline = client.streams[0].output_bytes;
    client.streams[0].auto_credit = false;
    try client.connection.send(.input, 1, "flood\r");
    const deadline = GetTickCount64() + 30_000;
    while (client.streams[0].output_bytes - baseline < p.window) {
        if (GetTickCount64() >= deadline) return error.CreditWindowTimeout;
        try client.consume(try client.connection.next(5000));
        try testing.expect(client.streams[0].output_bytes - baseline <= p.window);
    }
    // Pane 1 never reads again. Fill beyond a ConPTY input pipe while its output
    // is also stalled, but stay well below the owner's bounded input admission.
    const input: [p.max_data]u8 = @splat('z');
    for (0..16) |_| try client.connection.send(.input, 1, &input);
    try client.connection.send(.input, 2, "sibling-progress\r");
    try client.until(2, "ANSWER-sibling-progress");
    try testing.expectEqual(@as(usize, p.window), client.streams[0].output_bytes - baseline);
    try testing.expect(std.mem.indexOf(u8, client.streams[0].bytes.items, "FLOOD-DONE") == null);
    client.streams[0].auto_credit = true;
    try client.credit(1, p.window);
    try client.until(1, "FLOOD-DONE");
}

fn markerPid(bytes: []const u8, marker: []const u8) !u32 {
    const start = (std.mem.indexOf(u8, bytes, marker) orelse return error.MissingPid) + marker.len;
    const end = std.mem.indexOfScalarPos(u8, bytes, start, '-') orelse return error.MissingPid;
    return std.fmt.parseInt(u32, bytes[start..end], 10);
}

test "Windows respawn preserves pane screen identity revision and sibling process state" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var client = try fixture.connect();
    defer client.deinit();
    try client.create("$state=[guid]::NewGuid().ToString('N'); [Console]::WriteLine('STATE-'+$state+'-READY'); while($true){$line=[Console]::ReadLine(); [Console]::WriteLine('CONTINUITY-'+$state+'-'+$line)}");
    try client.until(1, "-READY");
    const start = (std.mem.indexOf(u8, client.streams[0].bytes.items, "STATE-") orelse return error.MissingState) + 6;
    try testing.expect(client.streams[0].bytes.items.len >= start + 32);
    const state = client.streams[0].bytes.items[start..][0..32].*;
    try client.ok(.{ .id = 0, .op = .layout, .revision = 0, .layout = layout });
    // Every launch blocks before its first application output. After respawn,
    // attach can therefore inspect the old screen without a timing assumption.
    try client.spawn("$null=[Console]::ReadLine(); [Console]::WriteLine('RUN-'+$PID+'-DONE'); exit 301", 2, 2);
    // A list roundtrip drains the spawn snapshot before initial input.
    const initial = try client.listed(&.{ 1, 2 }, 2, layout);
    initial.deinit();
    try client.connection.send(.input, 2, "first\r");
    try client.until(2, "-DONE");
    try client.exited(2, 301);
    const original_pid = try markerPid(client.streams[1].bytes.items, "RUN-");
    const old_marker = try std.fmt.allocPrint(a, "RUN-{d}-DONE", .{original_pid});
    defer a.free(old_marker);
    const exited = try client.listed(&.{ 1, 2 }, 2, layout);
    defer exited.deinit();
    try testing.expectEqual(@as(?i32, 301), exited.value.sessions.?[0].panes[1].exit);
    try client.ok(.{ .id = 0, .op = .respawn, .pane = 2 });
    client.streams[1].exit = null;
    try client.rejected(.{ .id = 0, .op = .respawn, .pane = 2 }, "PaneAlive");
    const running = try client.listed(&.{ 1, 2 }, 2, layout);
    defer running.deinit();
    try testing.expectEqual(@as(?i32, null), running.value.sessions.?[0].panes[1].exit);
    try client.ok(.{ .id = 0, .op = .detach });
    try client.attach(&.{ 1, 2 });
    try testing.expect(std.mem.indexOf(u8, client.streams[1].bytes.items, old_marker) != null);
    // Keep snapshot bytes separate from new output when comparing process IDs.
    client.streams[1].bytes.clearRetainingCapacity();
    try client.connection.send(.input, 2, "second\r");
    try client.until(2, "-DONE");
    try testing.expect(original_pid != try markerPid(client.streams[1].bytes.items, "RUN-"));
    try client.exited(2, 301);
    try client.connection.send(.input, 1, "still-alive\r");
    const continued = try std.fmt.allocPrint(a, "CONTINUITY-{s}-still-alive", .{state});
    defer a.free(continued);
    try client.until(1, continued);
    const retained = try client.listed(&.{ 1, 2 }, 2, layout);
    retained.deinit();
}

test "Windows two-pane takeover snapshots each stream and close kills only its descendant job" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var first = try fixture.connect();
    defer first.deinit();
    try first.create("$child=Start-Process powershell.exe -ArgumentList '-NoProfile -NonInteractive -Command Start-Sleep -Seconds 120' -PassThru -WindowStyle Hidden; [Console]::WriteLine('CHILD-'+$child.Id+'-READY'); while($true){$line=[Console]::ReadLine(); [Console]::WriteLine('ONE-'+$line)}");
    try first.until(1, "-READY");
    const child_pid = try markerPid(first.streams[0].bytes.items, "CHILD-");
    const child = OpenProcess(0x00100000, .FALSE, child_pid) orelse return error.OpenProcessFailed;
    defer _ = CloseHandle(child);
    try testing.expectEqual(@as(u32, 258), WaitForSingleObject(child, 0));
    try first.spawn(waiting, 2, 1);
    try first.until(2, "READY");
    var second = try fixture.connect();
    defer second.deinit();
    try second.attach(&.{ 1, 2 });
    try testing.expect(second.streams[0].snapshot_bytes > 0);
    try testing.expect(second.streams[1].snapshot_bytes > 0);
    try testing.expect(std.mem.indexOf(u8, second.streams[0].bytes.items, "CHILD-") != null);
    try testing.expect(std.mem.indexOf(u8, second.streams[1].bytes.items, "CHILD-") == null);
    const deadline = GetTickCount64() + 5000;
    while (!first.taken) {
        if (GetTickCount64() >= deadline) return error.TakeoverTimeout;
        try first.consume(try first.connection.next(5000));
    }
    first.connection.send(.input, 1, "stale\r") catch {};
    first.connection.send(.input, 2, "stale\r") catch {};
    try second.connection.send(.input, 1, "current-one\r");
    try second.connection.send(.input, 2, "current-two\r");
    try second.until(1, "ONE-current-one");
    try second.until(2, "ANSWER-current-two");
    try testing.expect(std.mem.indexOf(u8, second.streams[0].bytes.items, "ONE-stale") == null);
    try testing.expect(std.mem.indexOf(u8, second.streams[1].bytes.items, "ANSWER-stale") == null);
    try second.ok(.{ .id = 0, .op = .close, .pane = 1 });
    try testing.expectEqual(@as(u32, 0), WaitForSingleObject(child, 10_000));
    try second.connection.send(.input, 2, "sibling-survived\r");
    try second.until(2, "ANSWER-sibling-survived");
    const listed = try second.listed(&.{2}, 2, "");
    listed.deinit();
}

extern "kernel32" fn CopyFileW([*:0]const u16, [*:0]const u16, windows.BOOL) callconv(.winapi) windows.BOOL;
extern "kernel32" fn MoveFileW([*:0]const u16, [*:0]const u16) callconv(.winapi) windows.BOOL;
extern "kernel32" fn DeleteFileW([*:0]const u16) callconv(.winapi) windows.BOOL;

const PrivateCommand = struct {
    path: []u8,
    original: [:0]u16,
    moved: [:0]u16,

    fn init(namespace: []const u8) !PrivateCommand {
        const temp = try io.getEnvVarOwned(a, "TEMP");
        defer a.free(temp);
        const source = try io.getEnvVarOwned(a, "ComSpec");
        defer a.free(source);
        const source_w = try std.unicode.utf8ToUtf16LeAllocZ(a, source);
        defer a.free(source_w);
        const path = try std.fmt.allocPrint(a, "{s}\\{s}.exe", .{ temp, namespace });
        errdefer a.free(path);
        const original = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
        errdefer a.free(original);
        const moved_path = try std.fmt.allocPrint(a, "{s}.moved", .{path});
        defer a.free(moved_path);
        const moved = try std.unicode.utf8ToUtf16LeAllocZ(a, moved_path);
        errdefer a.free(moved);
        // Fail if this unique destination already exists; never overwrite it.
        if (!CopyFileW(source_w, original, .TRUE).toBool()) return error.CopyFixtureCommandFailed;
        return .{ .path = path, .original = original, .moved = moved };
    }

    fn deinit(self: *PrivateCommand) void {
        _ = DeleteFileW(self.original);
        _ = DeleteFileW(self.moved);
        a.free(self.path);
        a.free(self.original);
        a.free(self.moved);
    }
};

test "Windows failed respawn never falls back or erases exited pane screen and metadata" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var command = try PrivateCommand.init(fixture.namespace);
    defer command.deinit();
    var client = try fixture.connect();
    defer client.deinit();
    try client.create(waiting);
    try client.until(1, "READY");
    try client.ok(.{ .id = 0, .op = .layout, .revision = 0, .layout = layout });
    const spawned = try client.request(.{ .id = 0, .op = .spawn, .spawn = .{
        .argv = &.{ command.path, "/D", "/C", "echo OLD-COMMAND-SCREEN & exit /B 7" },
        .shell_integration = false,
        .cols = 120,
        .rows = 30,
    } });
    defer spawned.deinit();
    try testing.expect(spawned.value.ok);
    try testing.expectEqual(@as(?u32, 2), spawned.value.pane);
    try client.until(2, "OLD-COMMAND-SCREEN");
    try client.exited(2, 7);
    // Only rename our private copy, never ComSpec or any system executable.
    try testing.expect(MoveFileW(command.original, command.moved).toBool());
    try client.rejected(.{ .id = 0, .op = .respawn, .pane = 2 }, null);
    const failed = try client.listed(&.{ 1, 2 }, 2, layout);
    defer failed.deinit();
    try testing.expectEqual(@as(?i32, 7), failed.value.sessions.?[0].panes[1].exit);
    try client.ok(.{ .id = 0, .op = .detach });
    try client.attach(&.{ 1, 2 });
    try testing.expect(std.mem.indexOf(u8, client.streams[1].bytes.items, "OLD-COMMAND-SCREEN") != null);
    try client.connection.send(.input, 1, "after-failed-respawn\r");
    try client.until(1, "ANSWER-after-failed-respawn");
    // Restore the same launch path; explicit retry succeeds with the same ID.
    try testing.expect(MoveFileW(command.moved, command.original).toBool());
    client.streams[1].exit = null;
    client.streams[1].bytes.clearRetainingCapacity();
    try client.ok(.{ .id = 0, .op = .respawn, .pane = 2 });
    try client.until(2, "OLD-COMMAND-SCREEN");
    try client.exited(2, 7);
    const restored = try client.listed(&.{ 1, 2 }, 2, layout);
    restored.deinit();
}
