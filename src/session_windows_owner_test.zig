//! Real Windows owner tests. Every endpoint uses a fresh private fixture token.
const std = @import("std");
const windows = std.os.windows;
const testing = std.testing;
const a = testing.allocator;
const io = @import("io.zig");
const owner = @import("agent/session_windows.zig");
const pipe = @import("agent/session_pipe_windows.zig");
const p = @import("agent/session_protocol.zig");
const WindowsJob = @import("pty/windows_job.zig").Job;

extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) windows.DWORD;
extern "kernel32" fn OpenProcess(windows.DWORD, windows.BOOL, windows.DWORD) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn CloseHandle(windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn WaitForSingleObject(windows.HANDLE, windows.DWORD) callconv(.winapi) windows.DWORD;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) windows.HANDLE;
extern "kernel32" fn IsProcessInJob(windows.HANDLE, ?windows.HANDLE, *windows.BOOL) callconv(.winapi) windows.BOOL;
extern "kernel32" fn QueryInformationJobObject(?windows.HANDLE, windows.DWORD, *anyopaque, windows.DWORD, ?*windows.DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn Sleep(windows.DWORD) callconv(.winapi) void;
extern "kernel32" fn SetInformationJobObject(windows.HANDLE, windows.DWORD, *const anyopaque, windows.DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn WriteFile(windows.HANDLE, [*]const u8, windows.DWORD, *windows.DWORD, ?*anyopaque) callconv(.winapi) windows.BOOL;
extern "kernel32" fn ReadFile(windows.HANDLE, [*]u8, windows.DWORD, *windows.DWORD, ?*anyopaque) callconv(.winapi) windows.BOOL;
extern "kernel32" fn PeekNamedPipe(windows.HANDLE, ?[*]u8, windows.DWORD, ?*windows.DWORD, ?*windows.DWORD, ?*windows.DWORD) callconv(.winapi) windows.BOOL;

const BasicLimits = extern struct {
    process_user_time: i64 = 0,
    job_user_time: i64 = 0,
    flags: windows.DWORD = 0,
    minimum_working_set: usize = 0,
    maximum_working_set: usize = 0,
    active_processes: windows.DWORD = 0,
    affinity: usize = 0,
    priority: windows.DWORD = 0,
    scheduling: windows.DWORD = 0,
};

fn restrictiveJob() !bool {
    var member: windows.BOOL = .FALSE;
    try testing.expect(IsProcessInJob(GetCurrentProcess(), null, &member).toBool());
    if (!member.toBool()) return false;
    var limits: BasicLimits = .{};
    try testing.expect(QueryInformationJobObject(null, 2, &limits, @sizeOf(BasicLimits), null).toBool());
    return limits.flags & (0x800 | 0x1000) == 0;
}

fn startFixture(exe: []const u8, namespace: []const u8) !std.process.Child {
    // Test-only direct child, deliberately without production breakaway flags.
    return std.process.spawn(io.get(), .{
        .argv = &.{ exe, "session", "serve", "--namespace", namespace },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
        .create_no_window = true,
    });
}

fn connectFixture(namespace: []const u8) !owner.Connection {
    var endpoint = try pipe.Endpoint.init(a, namespace);
    defer endpoint.deinit(a);
    const deadline = io.milliTimestamp() + 5000;
    while (io.milliTimestamp() < deadline) {
        const handle = endpoint.connect() catch |err| switch (err) {
            error.PipeBusy => null,
            else => return err,
        };
        if (handle) |h| return owner.Connection.init(a, h);
        Sleep(10);
    }
    return error.FixtureStartupTimeout;
}

var serial: u32 = 0;

fn executable() ![]u8 {
    const path = @import("build_options").windows_owner_exe;
    if (!std.mem.startsWith(u8, path, "/")) return a.dupe(u8, path);
    // addOptionPath resolves on the build host. Cross-run Windows tests need
    // the WSL share spelling of that immutable compiler output instead.
    const distro = try io.getEnvVarOwned(a, "WSL_DISTRO_NAME");
    defer a.free(distro);
    const result = try std.fmt.allocPrint(a, "\\\\wsl.localhost\\{s}{s}", .{ distro, path });
    std.mem.replaceScalar(u8, result, '/', '\\');
    return result;
}

const Fixture = struct {
    namespace: []u8,
    exe: []u8,
    connection: owner.Connection,
    process: windows.HANDLE,
    child: std.process.Child,
    pid: i64,

    fn init() !Fixture {
        serial += 1;
        const namespace = try std.fmt.allocPrint(a, "owner-test-{d}-{d}-{d}", .{ GetCurrentProcessId(), io.nanoTimestamp(), serial });
        errdefer a.free(namespace);
        const exe = try executable();
        errdefer a.free(exe);
        var child = try startFixture(exe, namespace);
        errdefer child.kill(io.get());
        var connection = try connectFixture(namespace);
        errdefer connection.deinit();
        const pid = try hello(&connection);
        return .{ .namespace = namespace, .exe = exe, .connection = connection, .process = child.id.?, .child = child, .pid = pid };
    }

    fn deinit(self: *Fixture) void {
        // Never touch the production namespace or use process-name cleanup.
        self.connection.sendJson(.request, p.Request{ .id = 999, .op = .kill_server }) catch {};
        self.connection.deinit();
        _ = WaitForSingleObject(self.process, 10_000);
        self.child.kill(io.get());
        a.free(self.namespace);
        a.free(self.exe);
    }

    fn connect(self: *Fixture) !owner.Connection {
        return connectFixture(self.namespace);
    }
};

fn hello(connection: *owner.Connection) !i64 {
    try connection.sendJson(.hello, p.Hello{ .protocol = p.protocol, .version = p.version, .ghostty = "bootstrap", .client = "owner-test" });
    const frame = try connection.next(5000);
    try testing.expectEqual(p.Kind.welcome, frame.kind);
    try testing.expectEqual(@as(u32, 0), frame.stream);
    const parsed = try std.json.parseFromSlice(p.Welcome, a, frame.payload, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqualStrings(p.protocol, parsed.value.protocol);
    try testing.expectEqual(@as(u32, p.version), parsed.value.version);
    try testing.expect(parsed.value.ghostty.len > 0);
    try testing.expect(!std.mem.eql(u8, "bootstrap", parsed.value.ghostty));
    try testing.expectEqual(p.SnapshotFormat.vt, parsed.value.snapshot);
    try testing.expect(p.hasFeature(parsed.value.features, "create-id"));
    try testing.expect(p.hasFeature(parsed.value.features, "respawn"));
    try testing.expect(p.validHost(parsed.value.host));
    try testing.expect(parsed.value.owner_pid > 0);
    return parsed.value.owner_pid;
}

fn request(connection: *owner.Connection, value: p.Request) !std.json.Parsed(p.Reply) {
    try connection.sendJson(.request, value);
    const frame = try connection.next(5000);
    try testing.expectEqual(p.Kind.reply, frame.kind);
    try testing.expectEqual(@as(u32, 0), frame.stream);
    const parsed = try std.json.parseFromSlice(p.Reply, a, frame.payload, .{ .ignore_unknown_fields = true });
    errdefer parsed.deinit();
    try testing.expectEqual(value.id, parsed.value.id);
    return parsed;
}

fn expectEmpty(connection: *owner.Connection) !void {
    const reply = try request(connection, .{ .id = 1, .op = .list });
    defer reply.deinit();
    try testing.expect(reply.value.ok);
    try testing.expect(reply.value.@"error" == null);
    try testing.expectEqual(@as(usize, 0), (reply.value.sessions orelse return error.MissingSessions).len);
}

test "Windows owner rejects unattached spawn without disconnecting" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try expectEmpty(&fixture.connection);
    const reply = try request(&fixture.connection, .{ .id = 2, .op = .spawn, .spawn = .{} });
    defer reply.deinit();
    try testing.expect(!reply.value.ok);
    try testing.expectEqualStrings("NotAttached", reply.value.@"error" orelse return error.MissingError);
    try expectEmpty(&fixture.connection);
}

test "Windows owner singleton rejects second serve while original stays usable" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const result = try std.process.run(a, io.get(), .{
        .argv = &.{ fixture.exe, "session", "serve", "--namespace", fixture.namespace },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(10) } },
    });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    switch (result.term) {
        .exited => |code| try testing.expect(code != 0),
        else => return error.UnexpectedTermination,
    }
    try testing.expectEqual(@as(windows.DWORD, 258), WaitForSingleObject(fixture.process, 0));
    var second = try fixture.connect();
    defer second.deinit();
    try testing.expectEqual(fixture.pid, try hello(&second));
    try expectEmpty(&fixture.connection);
}

test "Windows session-only CLI lists fixture and rejects deferred modes" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const listed = try std.process.run(a, io.get(), .{
        .argv = &.{ fixture.exe, "session", "list", "--namespace", fixture.namespace },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(10) } },
    });
    defer a.free(listed.stdout);
    defer a.free(listed.stderr);
    try testing.expect(listed.term.success());
    const reply = try std.json.parseFromSlice(p.Reply, a, listed.stdout, .{});
    defer reply.deinit();
    try testing.expect(reply.value.ok);
    try testing.expectEqual(@as(usize, 0), (reply.value.sessions orelse return error.MissingSessions).len);
    const unsupported = try std.process.run(a, io.get(), .{
        .argv = &.{ fixture.exe, "stdio" },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(10) } },
    });
    defer a.free(unsupported.stdout);
    defer a.free(unsupported.stderr);
    switch (unsupported.term) {
        .exited => |code| try testing.expect(code != 0),
        else => return error.UnexpectedTermination,
    }
    try expectEmpty(&fixture.connection);
}

const Starter = struct {
    namespace: []const u8,
    exe: []const u8,
    connection: ?owner.Connection = null,
    failure: ?anyerror = null,

    fn run(self: *Starter) void {
        const handle = owner.connectOrStart(a, io.get(), self.namespace, self.exe) catch |err| {
            self.failure = err;
            return;
        };
        self.connection = owner.Connection.init(a, handle) catch |err| {
            self.failure = err;
            return;
        };
    }
};

test "Windows concurrent starters converge on one owner without replaying requests" {
    const exe = try executable();
    defer a.free(exe);
    serial += 1;
    const namespace = try std.fmt.allocPrint(a, "owner-race-{d}-{d}-{d}", .{ GetCurrentProcessId(), io.nanoTimestamp(), serial });
    defer a.free(namespace);
    if (try restrictiveJob()) {
        try testing.expectError(error.OwnerStartFailed, owner.connectOrStart(a, io.get(), namespace, exe));
        var endpoint = try pipe.Endpoint.init(a, namespace);
        defer endpoint.deinit(a);
        const unexpected = try endpoint.connect();
        defer if (unexpected) |handle| pipe.close(handle);
        try testing.expect(unexpected == null);
        std.debug.print("production auto-start success path skipped: parent job forbids breakaway; OwnerStartFailed and absent endpoint verified\n", .{});
        return error.SkipZigTest;
    }
    var first = Starter{ .namespace = namespace, .exe = exe };
    var second = Starter{ .namespace = namespace, .exe = exe };
    const thread = try std.Thread.spawn(.{}, Starter.run, .{&first});
    Starter.run(&second);
    thread.join();
    defer if (first.connection) |*connection| {
        connection.sendJson(.request, p.Request{ .id = 999, .op = .kill_server }) catch {};
        connection.deinit();
    };
    defer if (second.connection) |*connection| connection.deinit();
    if (first.failure) |err| return err;
    if (second.failure) |err| return err;
    const pid = try hello(&first.connection.?);
    try testing.expectEqual(pid, try hello(&second.connection.?));
    try expectEmpty(&first.connection.?);
    try expectEmpty(&second.connection.?);
}

test "Windows production owner survives closure of launcher's kill-on-close job" {
    if (try restrictiveJob()) {
        std.debug.print("launcher job survival skipped: parent job forbids breakaway; concurrent starters test verifies fail-closed startup\n", .{});
        return error.SkipZigTest;
    }
    const exe = try executable();
    defer a.free(exe);
    serial += 1;
    const namespace = try std.fmt.allocPrint(a, "owner-job-{d}-{d}-{d}", .{ GetCurrentProcessId(), io.nanoTimestamp(), serial });
    defer a.free(namespace);

    var job = try WindowsJob.create();
    defer job.close();
    const ExtendedLimits = extern struct {
        basic: BasicLimits = .{},
        io_counters: [6]u64 = @splat(0),
        process_memory: usize = 0,
        job_memory: usize = 0,
        peak_process_memory: usize = 0,
        peak_job_memory: usize = 0,
    };
    // Preserve KILL_ON_JOB_CLOSE and explicitly permit production breakaway.
    const limits: ExtendedLimits = .{ .basic = .{ .flags = 0x2000 | 0x800 } };
    try testing.expect(SetInformationJobObject(job.handle.?, 9, &limits, @sizeOf(ExtendedLimits)).toBool());

    const quoted_exe = try std.mem.replaceOwned(u8, a, exe, "'", "''");
    defer a.free(quoted_exe);
    // Stdin gates launch until job assignment. Keep the actual CLI bridge's
    // redirected stdin open: a short-lived list client could let the empty
    // owner exit before our guard connects. R marks bridge process startup;
    // closing the job must kill both launcher and bridge, not the owner.
    const script = try std.fmt.allocPrint(
        a,
        "[void][Console]::ReadLine(); $bridge=New-Object System.Diagnostics.Process; $bridge.StartInfo.FileName='{s}'; $bridge.StartInfo.Arguments='session connect --namespace {s}'; $bridge.StartInfo.UseShellExecute=$false; $bridge.StartInfo.RedirectStandardInput=$true; $bridge.StartInfo.RedirectStandardOutput=$true; [void]$bridge.Start(); [Console]::Out.Write('R'); $bridge.WaitForExit(); exit $bridge.ExitCode",
        .{ quoted_exe, namespace },
    );
    defer a.free(script);
    var launcher = try std.process.spawn(io.get(), .{
        .argv = &.{ "powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
        .create_no_window = true,
    });
    defer launcher.kill(io.get());
    try job.assign(launcher.id.?);
    var member: windows.BOOL = .FALSE;
    try testing.expect(IsProcessInJob(launcher.id.?, job.handle, &member).toBool());
    try testing.expect(member.toBool());
    var count: windows.DWORD = 0;
    try testing.expect(WriteFile(launcher.stdin.?.handle, "\n", 1, &count, null).toBool());
    try testing.expectEqual(@as(windows.DWORD, 1), count);

    var connection = try connectFixture(namespace);
    defer connection.deinit();
    defer connection.sendJson(.request, p.Request{ .id = 999, .op = .kill_server }) catch {};
    const pid = try hello(&connection);
    const process = OpenProcess(0x00100000 | 0x1000, .FALSE, @intCast(pid)) orelse return error.OpenProcessFailed;
    defer _ = CloseHandle(process);
    try testing.expect(IsProcessInJob(process, job.handle, &member).toBool());
    try testing.expect(!member.toBool());

    const deadline = io.milliTimestamp() + 10_000;
    while (true) {
        var available: windows.DWORD = 0;
        try testing.expect(PeekNamedPipe(launcher.stdout.?.handle, null, 0, null, &available, null).toBool());
        if (available > 0) break;
        if (io.milliTimestamp() >= deadline) return error.LauncherTimeout;
        Sleep(10);
    }
    var marker: [1]u8 = undefined;
    try testing.expect(ReadFile(launcher.stdout.?.handle, &marker, 1, &count, null).toBool());
    try testing.expectEqual(@as(windows.DWORD, 1), count);
    try testing.expectEqualStrings("R", &marker);
    try testing.expectEqual(@as(windows.DWORD, 258), WaitForSingleObject(launcher.id.?, 0));
    job.close();
    try testing.expectEqual(@as(windows.DWORD, 0), WaitForSingleObject(launcher.id.?, 5000));
    try testing.expectEqual(@as(windows.DWORD, 258), WaitForSingleObject(process, 250));
    try expectEmpty(&connection);
    const handle = try owner.connectOrStart(a, io.get(), namespace, exe);
    var sibling = try owner.Connection.init(a, handle);
    defer sibling.deinit();
    try testing.expectEqual(pid, try hello(&sibling));
    try expectEmpty(&sibling);
    try expectEmpty(&connection);
}

test "Windows production startup fails closed for invalid executable" {
    serial += 1;
    const namespace = try std.fmt.allocPrint(a, "owner-invalid-{d}-{d}-{d}", .{ GetCurrentProcessId(), io.nanoTimestamp(), serial });
    defer a.free(namespace);
    try testing.expectError(error.OwnerStartFailed, owner.connectOrStart(a, io.get(), namespace, "Z:\\hollow-owner-test-nonexistent\\missing.exe"));
    var endpoint = try pipe.Endpoint.init(a, namespace);
    defer endpoint.deinit(a);
    const unexpected = try endpoint.connect();
    defer if (unexpected) |handle| pipe.close(handle);
    try testing.expect(unexpected == null);
}

test "Windows malformed and oversized frames disconnect only offending client" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const headers = [_][p.header_len]u8{
        p.header(.hello, 0, p.control_limit + 1).encode(),
        p.header(.request, 1, 0).encode(),
        p.header(.welcome, 0, 0).encode(),
    };
    for (headers) |header| {
        var bad = try fixture.connect();
        defer bad.deinit();
        try bad.write(&header, 5000);
        if (bad.next(5000)) |_| return error.InvalidFrameAccepted else |err| {
            // A deadline is not proof that the malformed client was dropped.
            try testing.expect(err != error.Timeout);
        }
        try expectEmpty(&fixture.connection);
    }
}

test "Windows kill-server cancels idle handshake readers and permits fresh owner" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var idle = try fixture.connect();
    defer idle.deinit();
    try fixture.connection.sendJson(.request, p.Request{ .id = 3, .op = .kill_server });
    // Do not issue a read until shutdown completes: DisconnectNamedPipe can
    // discard a successfully written ACK that the client has not consumed.
    try testing.expectEqual(@as(windows.DWORD, 0), WaitForSingleObject(fixture.process, 4000));
    const frame = try fixture.connection.next(5000);
    try testing.expectEqual(p.Kind.reply, frame.kind);
    try testing.expectEqual(@as(u32, 0), frame.stream);
    const reply = try std.json.parseFromSlice(p.Reply, a, frame.payload, .{ .ignore_unknown_fields = true });
    defer reply.deinit();
    try testing.expectEqual(@as(u64, 3), reply.value.id);
    try testing.expect(reply.value.ok);
    try testing.expect(reply.value.@"error" == null);
    var restarted_child = try startFixture(fixture.exe, fixture.namespace);
    defer restarted_child.kill(io.get());
    var restarted = try fixture.connect();
    defer restarted.deinit();
    defer restarted.sendJson(.request, p.Request{ .id = 999, .op = .kill_server }) catch {};
    try testing.expect(try hello(&restarted) != fixture.pid);
    try expectEmpty(&restarted);
}

test "Windows owner exits naturally after final client disconnects" {
    var fixture = try Fixture.init();
    // Transfer connection ownership so cleanup does not touch a freed client.
    fixture.connection.deinit();
    defer {
        fixture.child.kill(io.get());
        a.free(fixture.namespace);
        a.free(fixture.exe);
    }
    try testing.expectEqual(@as(windows.DWORD, 0), WaitForSingleObject(fixture.process, 4000));
}

test "Windows healthy connection stays usable beyond partial-frame deadline" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    Sleep(6000);
    // Hello already completed in Fixture.init; duplicate hello is invalid.
    // A new list frame must not inherit the previous frame's expired deadline.
    try expectEmpty(&fixture.connection);
}

test {
    _ = @import("agent/session_keepalive_windows.zig");
    // Include colocated pipe security tests in this standalone test root.
    testing.refAllDecls(pipe);
    _ = @import("session_windows_bridge_test.zig");
    _ = @import("session_windows_live_test.zig");
    _ = @import("session_windows_multi_test.zig");
}
