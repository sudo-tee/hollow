//! Real native-local asynchronous transport; raw owner connection is only a
//! fixture guard and cleanup channel. Never touches production owner state.
const std = @import("std");
const testing = std.testing;
const a = testing.allocator;
const windows = std.os.windows;
const io = @import("io.zig");
const transport = @import("session/transport.zig");
const open = @import("session/open.zig");
const owner = @import("agent/session_windows.zig");
const pipe = @import("agent/session_pipe_windows.zig");
const vt = @import("agent/session_vt.zig");
const p = transport.p;

pub const std_options: std.Options = .{ .log_level = .warn };

extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn Sleep(u32) callconv(.winapi) void;
extern "kernel32" fn WaitForSingleObject(windows.HANDLE, u32) callconv(.winapi) u32;

const session_id = "123456789abcdef0123456789abcdef0";
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
    exe: []u8,
    child: std.process.Child,
    guard: owner.Connection,
    guard_live: bool = true,
    pid: i64,
    host: [p.max_host_len]u8 = undefined,
    host_len: usize,

    fn init() !Fixture {
        const exe = try executable();
        defer a.free(exe);
        return initExecutable(exe);
    }

    fn initExecutable(path: []const u8) !Fixture {
        serial += 1;
        const namespace = try std.fmt.allocPrint(a, "native-test-{d}-{d}-{d}", .{ GetCurrentProcessId(), GetTickCount64(), serial });
        errdefer a.free(namespace);
        const exe = try a.dupe(u8, path);
        errdefer a.free(exe);
        var child = try std.process.spawn(testing.io, .{
            .argv = &.{ exe, "session", "serve", "--namespace", namespace },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .inherit,
            .create_no_window = true,
        });
        errdefer child.kill(testing.io);
        var endpoint = try pipe.Endpoint.init(a, namespace);
        defer endpoint.deinit(a);
        const deadline = GetTickCount64() + 10_000;
        while (GetTickCount64() < deadline) {
            const handle = endpoint.connect() catch |err| switch (err) {
                error.PipeBusy => null,
                else => return err,
            };
            if (handle) |h| {
                var guard = try owner.Connection.init(a, h);
                errdefer guard.deinit();
                try guard.sendJson(.hello, p.Hello{ .protocol = p.protocol, .version = p.version, .ghostty = vt.buildIdentity(), .client = "native-test-guard" });
                const frame = try guard.next(5000);
                try testing.expectEqual(p.Kind.welcome, frame.kind);
                const welcome = try p.parse(p.Welcome, a, frame.payload);
                defer welcome.deinit();
                try testing.expect(p.validHost(welcome.value.host));
                var fixture: Fixture = .{ .namespace = namespace, .exe = exe, .child = child, .guard = guard, .pid = welcome.value.owner_pid, .host_len = welcome.value.host.len };
                @memcpy(fixture.host[0..fixture.host_len], welcome.value.host);
                return fixture;
            }
            Sleep(10);
        }
        return error.FixtureStartupTimeout;
    }

    fn deinit(self: *Fixture) void {
        if (self.guard_live) {
            self.guard.sendJson(.request, p.Request{ .id = 999, .op = .kill_server }) catch {};
            self.guard.deinit();
        }
        _ = WaitForSingleObject(self.child.id.?, 10_000);
        self.child.kill(testing.io);
        a.free(self.namespace);
        a.free(self.exe);
    }

    fn connect(self: *Fixture) !Client {
        const namespace = try a.dupe(u8, self.namespace);
        defer a.free(namespace);
        const connection = try transport.Connection.create(a, testing.io, .{
            .agent = .{ .path = self.exe },
            .ghostty_identity = vt.buildIdentity(),
            .namespace = namespace,
        });
        // Caller storage may disappear as soon as asynchronous create returns.
        @memset(namespace, 'x');
        return .{ .connection = connection };
    }
};

const Stream = struct {
    snapshot: std.ArrayList(u8) = .empty,
    output: std.ArrayList(u8) = .empty,
    snapshot_ended: bool = false,
    exit: ?i32 = null,
};

const Client = struct {
    connection: *transport.Connection,
    streams: [4]Stream = @splat(.{}),

    fn deinit(self: *Client) void {
        self.connection.destroy();
        for (&self.streams) |*s| {
            s.snapshot.deinit(a);
            s.output.deinit(a);
        }
    }

    fn stream(self: *Client, pane: u32) !*Stream {
        if (pane == 0 or pane > self.streams.len) return error.InvalidPane;
        return &self.streams[pane - 1];
    }

    fn consume(self: *Client, message: transport.Message) !void {
        switch (message.kind) {
            .welcome => {},
            .snapshot, .output => {
                const s = try self.stream(message.pane);
                try testing.expectEqual(message.kind == .output, s.snapshot_ended);
                const bytes = if (message.kind == .snapshot) &s.snapshot else &s.output;
                if (message.payload.len > capture_limit - bytes.items.len) return error.CaptureLimit;
                try bytes.appendSlice(a, message.payload);
                // Return credit only after the consumer owns the complete bytes.
                if (message.kind == .output) try self.connection.consumed(message);
            },
            .snapshot_end => {
                const s = try self.stream(message.pane);
                try testing.expect(!s.snapshot_ended);
                s.snapshot_ended = true;
            },
            .exit => (try self.stream(message.pane)).exit = try p.decodeExit(message.payload),
            .event => {},
            else => return error.UnexpectedFrame,
        }
    }

    fn next(self: *Client) !transport.Message {
        if (self.connection.pollUntil(self.connection.clock() + 20 * std.time.ns_per_s)) |message| return message;
        return self.connection.status().failure orelse error.FrameTimeout;
    }

    fn ready(self: *Client) !void {
        const deadline = GetTickCount64() + 20_000;
        while (GetTickCount64() < deadline) {
            const status = self.connection.status();
            if (status.phase == .ready) return;
            if (status.failure) |err| return err;
            Sleep(1);
        }
        return error.ConnectTimeout;
    }

    fn opened(self: *Client, value: p.Request) !open.Attachment {
        var operation = try open.Open.init(a, self.connection, value);
        defer operation.deinit();
        const deadline = GetTickCount64() + 30_000;
        while (GetTickCount64() < deadline) {
            switch (try operation.step()) {
                .pending => Sleep(1),
                .attached => |attachment| return attachment,
                .failed => |failure| return failure.reason,
            }
        }
        _ = operation.cancel();
        return error.OpenTimeout;
    }

    fn reply(self: *Client, id: u64) !std.json.Parsed(p.Reply) {
        const deadline = GetTickCount64() + 30_000;
        while (GetTickCount64() < deadline) {
            const message = try self.next();
            defer message.deinit();
            if (message.kind != .reply) {
                try self.consume(message);
                continue;
            }
            try testing.expectEqual(@as(?u64, id), message.request_id);
            const parsed = try std.json.parseFromSlice(p.Reply, a, message.payload, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
            errdefer parsed.deinit();
            try testing.expectEqual(id, parsed.value.id);
            try testing.expect(parsed.value.ok);
            return parsed;
        }
        return error.ReplyTimeout;
    }

    fn request(self: *Client, value: p.Request) !std.json.Parsed(p.Reply) {
        try self.ready();
        // Submit mutations exactly once; only poll while awaiting correlated ACK.
        return self.reply(try self.connection.request(value));
    }

    fn until(self: *Client, pane: u32, marker: []const u8) !void {
        const s = try self.stream(pane);
        const deadline = GetTickCount64() + 30_000;
        while (GetTickCount64() < deadline) {
            if (s.snapshot_ended and std.mem.indexOf(u8, s.output.items, marker) != null) return;
            const message = try self.next();
            defer message.deinit();
            try self.consume(message);
        }
        return error.MarkerTimeout;
    }

    fn input(self: *Client, pane: u32, bytes: []const u8) !void {
        try self.connection.input(self.connection.attachmentGeneration(), pane, bytes);
    }

    fn welcome(self: *Client, fixture: *Fixture) !void {
        const message = try self.next();
        defer message.deinit();
        try testing.expectEqual(p.Kind.welcome, message.kind);
        const parsed = try p.parse(p.Welcome, a, message.payload);
        defer parsed.deinit();
        try testing.expectEqual(fixture.pid, parsed.value.owner_pid);
        try testing.expectEqual(p.SnapshotFormat.binary, parsed.value.snapshot);
        var host: [p.max_host_len]u8 = undefined;
        try testing.expectEqualStrings(fixture.host[0..fixture.host_len], self.connection.host(&host));
    }
};

fn spawn(comptime script: []const u8) p.Spawn {
    return .{
        .argv = &.{ "powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script },
        .cols = 120,
        .rows = 30,
        .shell_integration = false,
    };
}

// The script's only mutable state is inside this PowerShell process. A new
// process cannot print the continued counter value after transport destruction.
const counter = "$n=40; [Console]::WriteLine('NATIVE-READY'); while ($null -ne ($s=[Console]::ReadLine())) { if ($s -eq 'inc') { $n++; [Console]::WriteLine(('NATIVE-VALUE-'+$n)) } elseif ($s -eq 'quit') { exit 7 } }";

fn expectSnapshot(bytes: []const u8, marker: []const u8) !void {
    const g = @import("ghostty_c");
    var decoder: g.GhosttySnapshotDecoder = null;
    try testing.expectEqual(g.GHOSTTY_SUCCESS, g.ghostty_snapshot_decoder_new_buf(null, &decoder, bytes.ptr, bytes.len));
    var terminal: g.GhosttyTerminal = null;
    // Decoder borrows the terminal after READY; free decoder first.
    defer if (terminal != null) g.ghostty_terminal_free(terminal);
    defer g.ghostty_snapshot_decoder_free(decoder);
    try testing.expectEqual(g.GHOSTTY_SUCCESS, g.ghostty_snapshot_decoder_ready(decoder, &terminal));
    while (true) {
        const result = g.ghostty_snapshot_decoder_next(decoder);
        if (result == g.GHOSTTY_NO_VALUE) break;
        try testing.expectEqual(g.GHOSTTY_SUCCESS, result);
    }
    var mirror: vt.Vt = .{ .allocator = a, .terminal = terminal };
    var formatted: std.ArrayList(u8) = .empty;
    defer formatted.deinit(a);
    try mirror.formatVt(a, &formatted);
    try testing.expect(std.mem.indexOf(u8, formatted.items, marker) != null);
}

test "native asynchronous create detach list and attach preserves owner and process state" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    {
        var client = try fixture.connect();
        defer client.deinit();
        try client.welcome(&fixture);
        const attached = try client.opened(.{ .id = 0, .op = .create, .create_id = session_id, .spawn = spawn(counter) });
        defer attached.deinit();
        try testing.expectEqualStrings(session_id, attached.reply.value.session.?.id);
        try testing.expect(client.connection.supportsCreateId());
        try client.until(1, "NATIVE-READY");
        try client.input(1, "inc\r");
        try client.until(1, "NATIVE-VALUE-41");
    }
    try testing.expectEqual(@as(u32, 258), WaitForSingleObject(fixture.child.id.?, 0));
    var client = try fixture.connect();
    defer client.deinit();
    try client.welcome(&fixture);
    const listed = try client.request(.{ .id = 0, .op = .list });
    defer listed.deinit();
    try testing.expectEqual(@as(usize, 1), listed.value.sessions.?.len);
    try testing.expectEqualStrings(session_id, listed.value.sessions.?[0].id);
    const attached = try client.opened(.{ .id = 0, .op = .attach, .session = session_id });
    defer attached.deinit();
    try client.input(1, "inc\r");
    try client.until(1, "NATIVE-VALUE-42");
    try expectSnapshot((try client.stream(1)).snapshot.items, "NATIVE-VALUE-41");
}

test "WSL keepalive admission survives all GUI clients and retains guest process state" {
    const guest = @import("build_options").keepalive_test_agent orelse return error.SkipZigTest;
    const distro = @import("build_options").keepalive_test_distro orelse return error.SkipZigTest;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const options = try wslOptions(arena.allocator(), &fixture, guest, distro);
    defer cleanupGuest(options);
    var sid: [32]u8 = undefined;
    var guest_pid: i64 = 0;
    {
        var captured = options;
        const mutable_distro = try arena.allocator().dupe(u8, distro);
        captured.connector.argv = try arena.allocator().dupe([]const u8, options.connector.argv);
        @constCast(captured.connector.argv)[2] = mutable_distro;
        captured.wsl.?.distro = mutable_distro;
        var client: Client = .{ .connection = try transport.Connection.create(a, testing.io, captured) };
        defer client.deinit();
        @memset(mutable_distro, 'x'); // Both connector and WSL identity are owned.
        const message = try client.next();
        defer message.deinit();
        try testing.expectEqual(p.Kind.welcome, message.kind);
        const welcome = try p.parse(p.Welcome, a, message.payload);
        defer welcome.deinit();
        guest_pid = welcome.value.owner_pid;
        const attached = try client.opened(.{ .id = 0, .op = .create, .spawn = .{
            .argv = &.{ "/bin/sh", "-c", "keeper_value=40; printf 'WSL-KEEPER-READY\\n'; while read line; do keeper_value=$((keeper_value+1)); printf 'WSL-KEEPER-%s\\n' \"$keeper_value\"; done" },
            .shell_integration = false,
        } });
        defer attached.deinit();
        @memcpy(&sid, attached.reply.value.session.?.id);
        try client.until(1, "WSL-KEEPER-READY");
        try client.input(1, "inc\n");
        try client.until(1, "WSL-KEEPER-41");
        // No native guard or native workspace may mask the keeper lifetime.
        fixture.guard.deinit();
        fixture.guard_live = false;
    }
    Sleep(1500);
    try testing.expectEqual(@as(u32, 258), WaitForSingleObject(fixture.child.id.?, 0));
    {
        var client: Client = .{ .connection = try transport.Connection.create(a, testing.io, options) };
        defer client.deinit();
        const message = try client.next();
        defer message.deinit();
        const welcome = try p.parse(p.Welcome, a, message.payload);
        defer welcome.deinit();
        try testing.expectEqual(guest_pid, welcome.value.owner_pid);
        const attached = try client.opened(.{ .id = 0, .op = .attach, .session = &sid });
        defer attached.deinit();
        try client.input(1, "inc\n");
        try client.until(1, "WSL-KEEPER-42");
        const killed = try client.request(.{ .id = 0, .op = .kill, .session = &sid });
        killed.deinit();
    }
    // Empty observation after the unpin drain grace releases the last keeper;
    // with no native sessions/clients, the Windows owner then exits itself.
    try testing.expectEqual(@as(u32, 0), WaitForSingleObject(fixture.child.id.?, 40_000));
}

test "WSL keeper failure rejects admission before a create can be submitted" {
    const guest = @import("build_options").keepalive_test_agent orelse return error.SkipZigTest;
    const distro = @import("build_options").keepalive_test_distro orelse return error.SkipZigTest;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var options = try wslOptions(arena.allocator(), &fixture, guest, distro);
    options.agent.path = "/tmp/opencode/keeper-fixture-nonexistent/agent";
    var client: Client = .{ .connection = try transport.Connection.create(a, testing.io, options) };
    defer client.deinit();
    const id = try client.connection.request(.{ .id = 0, .op = .create, .spawn = .{} });
    try testing.expectError(error.KeepaliveRejected, client.ready());
    try testing.expectEqual(transport.RequestState.not_sent, client.connection.requestState(id));
}

fn wslOptions(temp: std.mem.Allocator, fixture: *Fixture, guest: []const u8, distro: []const u8) !transport.Options {
    return .{
        .connector = .{ .argv = try temp.dupe([]const u8, &.{ "wsl.exe", "--distribution", distro, "--cd", "/", "--exec" }) },
        .agent = .{ .path = guest },
        .ghostty_identity = vt.buildIdentity(),
        .wsl = .{ .distro = distro, .agent = "/pending-deploy", .session_dir = try std.fmt.allocPrint(temp, "/tmp/opencode/wsl dir-{s}", .{fixture.namespace}) },
        .wsl_owner = fixture.exe,
        .wsl_namespace = fixture.namespace,
    };
}

fn cleanupGuest(options: transport.Options) void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    const directory = options.wsl.?.session_dir.?;
    const env = std.fmt.allocPrint(temp, "HOLLOW_SESSION_DIR={s}", .{directory}) catch return;
    const state = std.fmt.allocPrint(temp, "XDG_STATE_HOME={s}/state", .{directory}) catch return;
    var plain = options;
    plain.connector.argv = options.connector.command(temp, &.{ "/usr/bin/env", env, state }) catch return;
    plain.wsl = null;
    plain.wsl_owner = null;
    plain.wsl_namespace = null;
    var client: Client = .{ .connection = transport.Connection.create(a, testing.io, plain) catch return };
    defer client.deinit();
    const reply = client.request(.{ .id = 0, .op = .kill_server }) catch return;
    reply.deinit();
}

test "native cached live owner survives replacement of its test-owned bundle source" {
    const cache = @import("session/native_windows_cache.zig");
    const Sha256 = std.crypto.hash.sha2.Sha256;
    const temp = try testing.environ.getAlloc(a, "TEMP");
    defer a.free(temp);
    var random: [16]u8 = undefined;
    std.Io.random(testing.io, &random);
    const name = try std.fmt.allocPrint(a, "hollow-live-cache-{s}", .{std.fmt.bytesToHex(random, .lower)});
    defer a.free(name);
    const root = try std.fs.path.join(a, &.{ temp, name });
    defer a.free(root);
    // Exclusive creation: never adopt or clean up another test's directory.
    try std.Io.Dir.createDirAbsolute(testing.io, root, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    const source = try std.fs.path.join(a, &.{ root, "test bundle owner.exe" });
    defer a.free(source);
    const cache_root = try std.fs.path.join(a, &.{ root, "private cache" });
    defer a.free(cache_root);
    const compiled = try executable();
    defer a.free(compiled);
    try std.Io.Dir.copyFile(.cwd(), compiled, .cwd(), source, testing.io, .{});
    var original_digest: [Sha256.digest_length]u8 = undefined;
    const original_size = blk: {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, source, a, .limited(64 * 1024 * 1024));
        defer a.free(bytes);
        Sha256.hash(bytes, &original_digest, .{});
        break :blk bytes.len;
    };
    const cached = try cache.install(testing.io, a, source, cache_root);
    defer a.free(cached);
    var fixture = try Fixture.initExecutable(cached);
    // Owner and bridge processes must end before removing their cached image.
    defer fixture.deinit();
    {
        var client = try fixture.connect();
        defer client.deinit();
        try client.welcome(&fixture);
        const attached = try client.opened(.{ .id = 0, .op = .create, .create_id = session_id, .spawn = spawn(counter) });
        defer attached.deinit();
        try client.until(1, "NATIVE-READY");
        try client.input(1, "inc\r");
        try client.until(1, "NATIVE-VALUE-41");
        // Simulate GUI installation overwriting only this fixture's source.
        // Never execute the deliberately invalid replacement image.
        const file = try std.Io.Dir.createFileAbsolute(testing.io, source, .{});
        defer file.close(testing.io);
        try file.writePositionalAll(testing.io, "test-only replacement bundle, not an executable", 0);
    }
    try testing.expectEqual(@as(u32, 258), WaitForSingleObject(fixture.child.id.?, 0));
    var client = try fixture.connect();
    defer client.deinit();
    try client.welcome(&fixture); // Same live owner PID and host identity.
    const attached = try client.opened(.{ .id = 0, .op = .attach, .session = session_id });
    defer attached.deinit();
    try client.input(1, "inc\r");
    try client.until(1, "NATIVE-VALUE-42");
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, cached, a, .limited(64 * 1024 * 1024));
    defer a.free(bytes);
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    try testing.expectEqual(original_size, bytes.len);
    try testing.expectEqualSlices(u8, &original_digest, &digest);
    const updated = try cache.install(testing.io, a, source, cache_root);
    defer a.free(updated);
    try testing.expect(!std.mem.eql(u8, cached, updated));
    try testing.expectEqual(@as(u32, 258), WaitForSingleObject(fixture.child.id.?, 0));
}

test "native transport multipane layout close and respawn survive view destruction" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    {
        var client = try fixture.connect();
        defer client.deinit();
        const attached = try client.opened(.{ .id = 0, .op = .create, .create_id = session_id, .spawn = spawn(counter) });
        defer attached.deinit();
        try testing.expect(client.connection.supportsRespawn());
        try client.until(1, "NATIVE-READY");
        const added = try client.reply(try client.connection.spawnAttached(client.connection.attachmentGeneration(), spawn(counter)));
        defer added.deinit();
        try testing.expectEqual(@as(?u32, 2), added.value.pane);
        try testing.expectEqual(@as(?u64, 1), added.value.revision);
        try client.until(2, "NATIVE-READY");
        const layout = try client.reply(try client.connection.requestAttachedLayout(client.connection.attachmentGeneration(), 1, "native-two-pane-layout"));
        defer layout.deinit();
        try testing.expectEqual(@as(?u64, 2), layout.value.revision);
        try client.input(2, "inc\r");
        try client.until(2, "NATIVE-VALUE-41");
    }
    var client = try fixture.connect();
    defer client.deinit();
    try client.welcome(&fixture);
    const listed = try client.request(.{ .id = 0, .op = .list });
    defer listed.deinit();
    const session = listed.value.sessions.?[0];
    try testing.expectEqual(@as(usize, 2), session.panes.len);
    try testing.expectEqual(@as(u64, 2), session.revision);
    try testing.expectEqualStrings("native-two-pane-layout", session.layout);
    const attached = try client.opened(.{ .id = 0, .op = .attach, .session = session_id });
    defer attached.deinit();
    try client.input(1, "inc\r");
    try client.until(1, "NATIVE-VALUE-41");
    try client.input(2, "inc\r");
    try client.until(2, "NATIVE-VALUE-42");
    try client.input(2, "quit\r");
    const deadline = GetTickCount64() + 20_000;
    while ((try client.stream(2)).exit == null) {
        if (GetTickCount64() >= deadline) return error.ExitTimeout;
        const message = try client.next();
        defer message.deinit();
        try client.consume(message);
    }
    try testing.expectEqual(@as(?i32, 7), (try client.stream(2)).exit);
    (try client.stream(2)).output.clearRetainingCapacity();
    const respawned = try client.reply(try client.connection.respawnPane(client.connection.attachmentGeneration(), 2));
    defer respawned.deinit();
    try client.until(2, "NATIVE-READY");
    try client.input(2, "inc\r");
    try client.until(2, "NATIVE-VALUE-41");
    const closed = try client.reply(try client.connection.closePane(client.connection.attachmentGeneration(), 2));
    defer closed.deinit();
    try testing.expectEqual(@as(?u64, 3), closed.value.revision);
    const remaining = try client.request(.{ .id = 0, .op = .list });
    defer remaining.deinit();
    try testing.expectEqual(@as(usize, 1), remaining.value.sessions.?[0].panes.len);
    try testing.expectEqual(@as(u64, 3), remaining.value.sessions.?[0].revision);
    try testing.expectEqualStrings("native-two-pane-layout", remaining.value.sessions.?[0].layout);
    try client.input(1, "inc\r");
    try client.until(1, "NATIVE-VALUE-42");
}

test "native open cancellation before submission creates nothing and idle close joins" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    {
        var client = try fixture.connect();
        defer client.deinit();
        var operation = try open.Open.init(a, client.connection, .{ .id = 0, .op = .create, .spawn = spawn(counter) });
        defer operation.deinit();
        const failure = operation.cancel();
        try testing.expectEqual(open.Outcome.not_sent, failure.outcome);
        try testing.expectEqual(error.Canceled, failure.reason);
    }
    var client = try fixture.connect();
    try client.welcome(&fixture);
    const listed = try client.request(.{ .id = 0, .op = .list });
    defer listed.deinit();
    try testing.expectEqual(@as(usize, 0), listed.value.sessions.?.len);
    const start = GetTickCount64();
    client.deinit();
    try testing.expect(GetTickCount64() - start < 5000);
}

test "native missing owner is DeployFailed not_sent and invalid namespace fails admission" {
    const connection = try transport.Connection.create(a, testing.io, .{
        .agent = .{ .path = "Z:\\hollow-native-owner-nonexistent\\missing.exe" },
        .ghostty_identity = vt.buildIdentity(),
        .namespace = "native-missing-owner",
    });
    defer connection.destroy();
    var operation = try open.Open.init(a, connection, .{ .id = 0, .op = .create, .spawn = spawn(counter) });
    defer operation.deinit();
    const deadline = GetTickCount64() + 10_000;
    while (GetTickCount64() < deadline) {
        switch (try operation.step()) {
            .pending => Sleep(1),
            .attached => |attachment| {
                attachment.deinit();
                return error.UnexpectedAttachment;
            },
            .failed => |failure| {
                try testing.expectEqual(error.DeployFailed, failure.reason);
                try testing.expectEqual(open.Outcome.not_sent, failure.outcome);
                try testing.expect(connection.deploymentFailure() != null);
                break;
            },
        }
    }
    try testing.expect(operation.isFinished());
    try testing.expectError(error.InvalidArgument, transport.Connection.create(a, testing.io, .{
        .ghostty_identity = vt.buildIdentity(),
        .namespace = "../production",
    }));
    try testing.expectError(error.InvalidArgument, transport.Connection.create(a, testing.io, .{
        .connector = .{ .argv = &.{"wsl.exe"} },
        .ghostty_identity = vt.buildIdentity(),
        .namespace = "native-not-a-guest",
    }));
}

test "native resolver accepts literal spaced explicit and bundled paths without executing" {
    const native = @import("session/native_windows.zig");
    const deploy = @import("host/deploy.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "agents with spaces/windows-x86_64");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "agents with spaces/windows-x86_64/hollow-agent.exe", .data = "test fixture, not executable" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    defer a.free(root);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const directory = try std.fs.path.join(alloc, &.{ root, "agents with spaces" });
    const path = try std.fs.path.join(alloc, &.{ directory, "windows-x86_64", "hollow-agent.exe" });
    var failure: deploy.Failure = .{};
    try testing.expectEqualStrings(path, try native.resolve(testing.io, alloc, .{ .path = path }, &failure));
    try testing.expectEqualStrings(path, try native.resolve(testing.io, alloc, .{ .dir = directory }, &failure));
    const argv = try native.command(alloc, path, "native-literal-fixture");
    try testing.expectEqual(@as(usize, 5), argv.len);
    try testing.expectEqualStrings(path, argv[0]);
    try testing.expectEqualStrings("session", argv[1]);
    try testing.expectEqualStrings("connect", argv[2]);
    try testing.expectEqualStrings("--namespace", argv[3]);
    try testing.expectEqualStrings("native-literal-fixture", argv[4]);
}
