//! Process-level bridge regressions. Only test-owned namespaces and children.
const std = @import("std");
const windows = std.os.windows;
const testing = std.testing;
const a = testing.allocator;
const io = @import("io.zig");
const owner = @import("agent/session_windows.zig");
const pipe = @import("agent/session_pipe_windows.zig");
const p = @import("agent/session_protocol.zig");

extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn Sleep(u32) callconv(.winapi) void;
extern "kernel32" fn WaitForSingleObject(windows.HANDLE, u32) callconv(.winapi) u32;
extern "kernel32" fn ReadFile(windows.HANDLE, [*]u8, u32, *u32, ?*anyopaque) callconv(.winapi) windows.BOOL;
extern "kernel32" fn WriteFile(windows.HANDLE, [*]const u8, u32, *u32, ?*anyopaque) callconv(.winapi) windows.BOOL;
extern "kernel32" fn PeekNamedPipe(windows.HANDLE, ?*anyopaque, u32, ?*u32, *u32, ?*u32) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) windows.HANDLE;
extern "kernel32" fn DuplicateHandle(windows.HANDLE, windows.HANDLE, windows.HANDLE, *windows.HANDLE, u32, windows.BOOL, u32) callconv(.winapi) windows.BOOL;
extern "kernel32" fn CreatePipe(*windows.HANDLE, *windows.HANDLE, ?*windows.SECURITY_ATTRIBUTES, u32) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetStdHandle(u32) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn SetStdHandle(u32, ?windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn SetHandleInformation(windows.HANDLE, u32, u32) callconv(.winapi) windows.BOOL;

var serial: u32 = 0;

fn namespace() ![]u8 {
    serial += 1;
    return std.fmt.allocPrint(a, "bridge-test-{d}-{d}-{d}", .{ GetCurrentProcessId(), GetTickCount64(), serial });
}

fn executable() ![]u8 {
    const path = @import("build_options").windows_owner_exe;
    if (!std.mem.startsWith(u8, path, "/")) return a.dupe(u8, path);
    const distro = try io.getEnvVarOwned(a, "WSL_DISTRO_NAME");
    defer a.free(distro);
    const result = try std.fmt.allocPrint(a, "\\\\wsl.localhost\\{s}{s}", .{ distro, path });
    std.mem.replaceScalar(u8, result, '/', '\\');
    return result;
}

fn complete(op: *pipe.Operation, handle: windows.HANDLE, timeout: u32) !usize {
    if (WaitForSingleObject(op.event, timeout) != 0) return error.Timeout;
    return (try op.result(handle)) orelse error.IncompleteOperation;
}

fn write(handle: windows.HANDLE, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        var count: u32 = 0;
        if (!WriteFile(handle, bytes[offset..].ptr, @intCast(bytes.len - offset), &count, null).toBool()) return error.WriteFailed;
        if (count == 0) return error.WriteFailed;
        offset += count;
    }
}

fn read(handle: windows.HANDLE, bytes: []u8) !void {
    const deadline = GetTickCount64() + 5000;
    var offset: usize = 0;
    while (offset < bytes.len) {
        var available: u32 = 0;
        if (!PeekNamedPipe(handle, null, 0, null, &available, null).toBool()) return error.UnexpectedEof;
        if (available == 0) {
            if (GetTickCount64() >= deadline) return error.Timeout;
            Sleep(1);
            continue;
        }
        var count: u32 = 0;
        if (!ReadFile(handle, bytes[offset..].ptr, @intCast(@min(bytes.len - offset, available)), &count, null).toBool()) return error.ReadFailed;
        if (count == 0) return error.UnexpectedEof;
        offset += count;
    }
}

const Client = struct {
    child: std.process.Child,

    fn init(exe: []const u8, ns: []const u8) !Client {
        return initOutput(exe, ns, null);
    }

    fn initOutput(exe: []const u8, ns: []const u8, output: ?std.Io.File) !Client {
        // Zig's Windows `.file` reopens handles, unsupported for anonymous pipes.
        // Tests run serially; temporarily inherit one shared output handle.
        const old_stdout = GetStdHandle(0xfffffff5);
        const old_stderr = GetStdHandle(0xfffffff4);
        defer if (output != null) {
            _ = SetStdHandle(0xfffffff5, old_stdout);
            _ = SetStdHandle(0xfffffff4, old_stderr);
        };
        if (output) |file| {
            try testing.expect(SetStdHandle(0xfffffff5, file.handle).toBool());
            try testing.expect(SetStdHandle(0xfffffff4, file.handle).toBool());
        }
        return .{ .child = try std.process.spawn(io.get(), .{
            .argv = &.{ exe, "session", "connect", "--namespace", ns },
            .stdin = .pipe,
            .stdout = if (output != null) .inherit else .pipe,
            .stderr = if (output != null) .inherit else .pipe,
            .create_no_window = true,
        }) };
    }

    fn deinit(self: *Client) void {
        // Child.kill also reaps and closes any remaining process-owned pipes.
        self.child.kill(io.get());
    }

    fn closeInput(self: *Client) void {
        self.child.stdin.?.close(io.get());
        self.child.stdin = null;
    }

    fn closeOutput(self: *Client) void {
        self.child.stdout.?.close(io.get());
        self.child.stdout = null;
    }

    fn expectExit(self: *Client, success: bool, timeout: u32) !void {
        try testing.expectEqual(@as(u32, 0), WaitForSingleObject(self.child.id.?, timeout));
        // Leave reaping to deinit so stdout remains available for EOF assertions.
        var code: u32 = 0;
        try testing.expect(GetExitCodeProcess(self.child.id.?, &code).toBool());
        if (success != (code == 0) and self.child.stderr != null) {
            var buf: [512]u8 = undefined;
            var available: u32 = 0;
            if (PeekNamedPipe(self.child.stderr.?.handle, null, 0, null, &available, null).toBool() and available > 0) {
                const len = @min(available, buf.len);
                read(self.child.stderr.?.handle, buf[0..len]) catch return error.DiagnosticReadFailed;
                std.debug.print("bridge exit {d}: {s}\n", .{ code, buf[0..len] });
            }
        }
        try testing.expectEqual(success, code == 0);
    }

    fn expectOutputEof(self: *Client) !void {
        var available: u32 = 0;
        const ok = PeekNamedPipe(self.child.stdout.?.handle, null, 0, null, &available, null).toBool();
        try testing.expectEqual(@as(u32, 0), available);
        try testing.expect(!ok);
        try testing.expectEqual(@as(u32, 109), GetLastError());
    }

    extern "kernel32" fn GetExitCodeProcess(windows.HANDLE, *u32) callconv(.winapi) windows.BOOL;
};

const Stub = struct {
    ns: []u8,
    exe: []u8,
    server: windows.HANDLE,

    fn init() !Stub {
        const ns = try namespace();
        errdefer a.free(ns);
        const exe = try executable();
        errdefer a.free(exe);
        var endpoint = try pipe.Endpoint.init(a, ns);
        defer endpoint.deinit(a);
        return .{ .ns = ns, .exe = exe, .server = try endpoint.server(true) };
    }

    fn deinit(self: *Stub) void {
        pipe.disconnect(self.server);
        pipe.close(self.server);
        a.free(self.ns);
        a.free(self.exe);
    }

    fn client(self: *Stub) !Client {
        return self.clientOutput(null);
    }

    fn clientOutput(self: *Stub, output: ?std.Io.File) !Client {
        var accept = try pipe.Operation.init();
        defer accept.deinit();
        defer accept.cancel(self.server);
        try accept.accept(self.server);
        var result = try Client.initOutput(self.exe, self.ns, output);
        errdefer result.deinit();
        _ = try complete(&accept, self.server, 5000);
        // Accept can complete before connectOrStart validates endpoint security.
        // Observe raw traffic before a test disconnects or closes its stdio.
        try write(result.child.stdin.?.handle, "\x00");
        var reader = try pipe.Operation.init();
        defer reader.deinit();
        defer reader.cancel(self.server);
        var ready: [1]u8 = undefined;
        try reader.read(self.server, &ready);
        try testing.expectEqual(@as(usize, 1), try complete(&reader, self.server, 5000));
        try testing.expectEqual(@as(u8, 0), ready[0]);
        return result;
    }
};

fn sendJson(client: *Client, kind: p.Kind, value: anytype) !void {
    const payload = try std.json.Stringify.valueAlloc(a, value, .{});
    defer a.free(payload);
    const header = p.header(kind, 0, @intCast(payload.len)).encode();
    try write(client.child.stdin.?.handle, &header);
    try write(client.child.stdin.?.handle, payload);
}

fn receive(client: *Client, kind: p.Kind) ![]u8 {
    var header: [p.header_len]u8 = undefined;
    try read(client.child.stdout.?.handle, &header);
    const decoded = try p.Header.decode(&header);
    try testing.expectEqual(@backingInt(kind), @backingInt(decoded.kind));
    try testing.expectEqual(@as(u32, 0), decoded.stream);
    try testing.expect(decoded.len <= p.control_limit);
    const payload = try a.alloc(u8, decoded.len);
    errdefer a.free(payload);
    try read(client.child.stdout.?.handle, payload);
    return payload;
}

test "Windows connect CLI hello/list is protocol-only and stdin EOF leaves control client alive" {
    const ns = try namespace();
    defer a.free(ns);
    const exe = try executable();
    defer a.free(exe);
    var child = try std.process.spawn(io.get(), .{
        .argv = &.{ exe, "session", "serve", "--namespace", ns },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
        .create_no_window = true,
    });
    defer child.kill(io.get());
    var endpoint = try pipe.Endpoint.init(a, ns);
    defer endpoint.deinit(a);
    const deadline = GetTickCount64() + 5000;
    const handle = while (true) {
        if (try endpoint.connect()) |handle| break handle;
        if (GetTickCount64() >= deadline) return error.Timeout;
        Sleep(10);
    };
    var control = try owner.Connection.init(a, handle);
    defer control.deinit();
    defer control.sendJson(.request, p.Request{ .id = 99, .op = .kill_server }) catch {};
    try control.sendJson(.hello, p.Hello{ .protocol = p.protocol, .version = p.version, .ghostty = "bootstrap", .client = "bridge-control" });
    _ = try control.next(5000);

    var client = try Client.init(exe, ns);
    defer client.deinit();
    try sendJson(&client, .hello, p.Hello{ .protocol = p.protocol, .version = p.version, .ghostty = "bootstrap", .client = "bridge-test" });
    const welcome_bytes = try receive(&client, .welcome);
    defer a.free(welcome_bytes);
    const welcome = try std.json.parseFromSlice(p.Welcome, a, welcome_bytes, .{});
    defer welcome.deinit();
    try testing.expectEqualStrings("bootstrap", welcome.value.ghostty);
    try testing.expectEqual(p.SnapshotFormat.vt, welcome.value.snapshot);
    try testing.expectEqual(@as(usize, 0), welcome.value.features.len);
    try sendJson(&client, .request, p.Request{ .id = 17, .op = .list });
    const reply_bytes = try receive(&client, .reply);
    defer a.free(reply_bytes);
    const reply = try std.json.parseFromSlice(p.Reply, a, reply_bytes, .{});
    defer reply.deinit();
    try testing.expect(reply.value.ok);
    try testing.expectEqual(@as(u64, 17), reply.value.id);
    try testing.expectEqual(@as(usize, 0), reply.value.sessions.?.len);
    // EOF detaches immediately; consume replies before closing stdin.
    client.closeInput();
    try client.expectExit(true, 2000);
    try client.expectOutputEof();
    try control.sendJson(.request, p.Request{ .id = 18, .op = .list });
    const frame = try control.next(5000);
    try testing.expectEqual(p.Kind.reply, frame.kind);
    try testing.expectEqual(@as(u32, 258), WaitForSingleObject(child.id.?, 0));
}

test "Windows connect owner EOF cancels blocked stdin with caller input still open" {
    var stub = try Stub.init();
    defer stub.deinit();
    var client = try stub.client();
    defer client.deinit();
    pipe.disconnect(stub.server);
    try client.expectExit(true, 2000);
    try client.expectOutputEof();
}

test "Windows connect closed stdout cancels blocked stdin and owner read" {
    var stub = try Stub.init();
    defer stub.deinit();
    var client = try stub.client();
    defer client.deinit();
    client.closeOutput();
    var writer = try pipe.Operation.init();
    defer writer.deinit();
    defer writer.cancel(stub.server);
    try writer.write(stub.server, "not-a-frame");
    _ = try complete(&writer, stub.server, 5000);
    try client.expectExit(true, 2000);
    var reader = try pipe.Operation.init();
    defer reader.deinit();
    defer reader.cancel(stub.server);
    var buf: [1]u8 = undefined;
    if (reader.read(stub.server, &buf)) |_| {
        if (complete(&reader, stub.server, 2000)) |n| try testing.expectEqual(@as(usize, 0), n) else |err| try testing.expectEqual(error.BrokenPipe, err);
    } else |err| try testing.expectEqual(error.BrokenPipe, err);
}

test "Windows connect blocked stdout deadline cancels idle stdin and pending owner output" {
    var stub = try Stub.init();
    defer stub.deinit();
    var output_read: windows.HANDLE = undefined;
    var output_write: windows.HANDLE = undefined;
    try testing.expect(CreatePipe(&output_read, &output_write, null, 4096).toBool());
    defer pipe.close(output_read);
    defer pipe.close(output_write);
    try testing.expect(SetHandleInformation(output_write, 1, 1).toBool());
    // Both streams share one undrained pipe. Even an error diagnostic can block.
    var client = try stub.clientOutput(.{ .handle = output_write, .flags = .{ .nonblocking = false } });
    defer client.deinit();
    var writer = try pipe.Operation.init();
    defer writer.deinit();
    const bytes = try a.alloc(u8, 512 * 1024);
    defer a.free(bytes);
    defer writer.cancel(stub.server);
    @memset(bytes, 0xa5);
    try writer.write(stub.server, bytes);
    // Never drain stdout and never close stdin: only the bridge deadline can exit.
    try client.expectExit(false, 5500);
}

const Feeder = struct {
    handle: windows.HANDLE,
    bytes: []const u8,

    fn run(self: Feeder) void {
        defer pipe.close(self.handle);
        write(self.handle, self.bytes) catch {};
    }
};

test "Windows connect unread owner pipe applies bounded backpressure and write deadline" {
    var stub = try Stub.init();
    defer stub.deinit();
    const bytes = try a.alloc(u8, 512 * 1024);
    defer a.free(bytes);
    @memset(bytes, 0x5a);
    var client = try stub.client();
    // Feeder owns a duplicate so cleanup never closes an active WriteFile handle.
    var input: windows.HANDLE = undefined;
    if (!DuplicateHandle(GetCurrentProcess(), client.child.stdin.?.handle, GetCurrentProcess(), &input, 0, .FALSE, 2).toBool()) {
        client.deinit();
        return error.DuplicateHandleFailed;
    }
    const thread = std.Thread.spawn(.{}, Feeder.run, .{Feeder{ .handle = input, .bytes = bytes }}) catch |err| {
        pipe.close(input);
        client.deinit();
        return err;
    };
    defer {
        // On assertion failure, terminate only this child before joining feeder.
        client.deinit();
        thread.join();
    }
    // Stub deliberately reads nothing after readiness; stdout remains idle.
    try client.expectExit(false, 7000);
    try client.expectOutputEof();
}

test "Windows connect passes large arbitrary bytes exactly once without frame parsing" {
    var stub = try Stub.init();
    defer stub.deinit();
    var client = try stub.client();
    defer client.deinit();
    var reader = try pipe.Operation.init();
    defer reader.deinit();
    defer reader.cancel(stub.server);
    var writer = try pipe.Operation.init();
    defer writer.deinit();
    defer writer.cancel(stub.server);
    var sent: [4096]u8 = undefined;
    var received: [4096]u8 = undefined;
    var echoed: [4096]u8 = undefined;
    // Half a MiB with NULs, invalid headers, and changing chunk identities.
    for (0..128) |chunk| {
        for (&sent, 0..) |*byte, index| byte.* = @truncate(index * 31 + chunk);
        try write(client.child.stdin.?.handle, &sent);
        var offset: usize = 0;
        while (offset < received.len) {
            try reader.read(stub.server, received[offset..]);
            const count = try complete(&reader, stub.server, 5000);
            try testing.expect(count > 0);
            offset += count;
        }
        try testing.expectEqualSlices(u8, &sent, &received);
        try writer.write(stub.server, &received);
        try testing.expectEqual(received.len, try complete(&writer, stub.server, 5000));
        try read(client.child.stdout.?.handle, &echoed);
        try testing.expectEqualSlices(u8, &sent, &echoed);
    }
    // No handshake, extra data, duplicated request, or replay may follow.
    try reader.read(stub.server, &received);
    try testing.expectEqual(@as(u32, 258), WaitForSingleObject(reader.event, 100));
    client.closeInput();
    try client.expectExit(true, 2000);
    // EOF must close the transport, not manufacture a remote close request.
    if (complete(&reader, stub.server, 2000)) |n| {
        try testing.expectEqual(@as(usize, 0), n);
    } else |err| try testing.expectEqual(error.BrokenPipe, err);
    try client.expectOutputEof();
}
