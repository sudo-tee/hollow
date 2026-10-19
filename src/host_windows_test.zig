//! Native Windows fs/exec execution, without GUI, Lua, or experimental PTYs.
//! WSL case requires an explicit existing distro and preinstalled agent.
const std = @import("std");
const builtin = @import("builtin");
const host = @import("host.zig");
const a = std.testing.allocator;

fn clock() i128 {
    return std.Io.Clock.awake.now(std.testing.io).toNanoseconds();
}

fn wait(manager: *host.Manager, ticket: host.Ticket) !host.operations.Result {
    const deadline = clock() + 15000 * std.time.ns_per_ms;
    while (clock() < deadline) {
        if (try manager.poll(ticket)) |result| return result;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(2), .awake);
    }
    return error.Timeout;
}

fn request(manager: *host.Manager, handle: host.Handle, operation: host.operations.Operation) !host.operations.Result {
    var result = try wait(manager, try manager.request(handle, operation, 10000));
    errdefer result.deinit();
    if (result.value == .failure) {
        std.debug.print("host failure: {s}: {s}\n", .{ result.value.failure.code, result.value.failure.message });
        return error.OperationFailed;
    }
    return result;
}

fn systemPath(name: []const u8) ![]u8 {
    const root = try std.testing.environ.getAlloc(a, "SystemRoot");
    defer a.free(root);
    return std.fs.path.join(a, &.{ root, "System32", name });
}

test "native Windows local fs exec and cancellation" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var manager = host.Manager.init(a, std.testing.io);
    defer manager.deinit();
    const local = try manager.connectLocal("windows-local");
    var info = try request(&manager, local, .{ .info = {} });
    defer info.deinit();
    try std.testing.expectEqualStrings("windows", info.value.info.os);
    const cmd = try systemPath("cmd.exe");
    defer a.free(cmd);
    const root = try std.testing.environ.getAlloc(a, "SystemRoot");
    defer a.free(root);
    var stat = try request(&manager, local, .{ .stat = cmd });
    defer stat.deinit();
    try std.testing.expectEqualStrings("file", stat.value.stat.kind);
    var read = try request(&manager, local, .{ .read = .{ .path = cmd, .limit = 2 } });
    defer read.deinit();
    try std.testing.expectEqualStrings("MZ", read.value.read.bytes);
    var list = try request(&manager, local, .{ .list = .{ .path = root, .limit = 2 } });
    defer list.deinit();
    try std.testing.expectEqual(@as(usize, 2), list.value.list.entries.len);
    var exec = try request(&manager, local, .{ .exec = .{ .argv = &.{ cmd, "/d", "/c", "echo native&echo err>&2&exit /b 7" }, .cwd = root } });
    defer exec.deinit();
    try std.testing.expectEqual(@as(i32, 7), exec.value.exec.exit_code);
    try std.testing.expectEqualStrings("native\r\n", exec.value.exec.stdout);
    try std.testing.expectEqualStrings("err\r\n", exec.value.exec.stderr);
    // Direct owned process, not a shell plus an uncontained sleeping child.
    const ping = try systemPath("ping.exe");
    defer a.free(ping);
    const ticket = try manager.request(local, .{ .exec = .{ .argv = &.{ ping, "-n", "30", "127.0.0.1" } } }, 10000);
    try manager.cancel(ticket);
    var canceled = try wait(&manager, ticket);
    defer canceled.deinit();
    try std.testing.expectEqualStrings("cancelled", canceled.value.failure.code);
    try manager.close(local);
    const fresh = try manager.connectLocal("windows-local");
    try std.testing.expect(fresh.generation != local.generation);
    try std.testing.expectError(error.StaleHost, manager.request(local, .{ .info = {} }, 1000));
}

test "native Windows persistent WSL fs exec bytes cancellation and reconnect" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const distro = std.testing.environ.getAlloc(a, "HOLLOW_TEST_WSL_DISTRO") catch return error.SkipZigTest;
    defer a.free(distro);
    const agent = try std.testing.environ.getAlloc(a, "HOLLOW_TEST_WSL_AGENT");
    defer a.free(agent);
    if (distro.len == 0 or distro[0] == '-' or agent.len == 0 or agent[0] != '/') return error.InvalidArgument;
    const launcher = try systemPath("wsl.exe");
    defer a.free(launcher);
    const argv = [_][]const u8{ launcher, "--distribution", distro, "--cd", "/", "--exec", agent, "stdio" };
    var manager = host.Manager.init(a, std.testing.io);
    defer manager.deinit();
    const remote = try manager.connectAgent("windows-wsl", &argv);
    try ready(&manager, remote);
    var info = try request(&manager, remote, .{ .info = {} });
    defer info.deinit();
    try std.testing.expectEqualStrings("linux", info.value.info.os);
    const env = [_]host.operations.Env{.{ .key = "HOLLOW_SMOKE", .value = "v\xfe" }};
    var exec = try request(&manager, remote, .{ .exec = .{
        .argv = &.{ "/bin/sh", "-c", "printf '\\000'; printf '%s|%s|%s' \"$1\" \"$2\" \"$HOLLOW_SMOKE\"; printf 'err:%s' \"$PWD\" >&2; exit 7", "probe", "", "x\xff" },
        .cwd = "/tmp",
        .env = &env,
    } });
    defer exec.deinit();
    try std.testing.expectEqual(@as(i32, 7), exec.value.exec.exit_code);
    try std.testing.expectEqualStrings("\x00|x\xff|v\xfe", exec.value.exec.stdout);
    try std.testing.expectEqualStrings("err:/tmp", exec.value.exec.stderr);
    var read = try request(&manager, remote, .{ .read = .{ .path = "/etc/os-release", .limit = 64 } });
    defer read.deinit();
    try std.testing.expect(read.value.read.bytes.len > 0);
    var stat = try request(&manager, remote, .{ .stat = "/tmp" });
    defer stat.deinit();
    try std.testing.expectEqualStrings("directory", stat.value.stat.kind);
    var list = try request(&manager, remote, .{ .list = .{ .path = "/tmp", .limit = 2 } });
    defer list.deinit();
    try std.testing.expect(list.value.list.entries.len <= 2);
    {
        var fixture = try request(&manager, remote, .{ .exec = .{ .argv = &.{ "/usr/bin/mktemp", "/tmp/hollow-win-fs-XXXXXX" } } });
        defer fixture.deinit();
        try std.testing.expectEqual(@as(i32, 0), fixture.value.exec.exit_code);
        const base = std.mem.trimEnd(u8, fixture.value.exec.stdout, "\n");
        const prefix = "/tmp/hollow-win-fs-";
        try std.testing.expect(std.mem.startsWith(u8, base, prefix) and base.len == prefix.len + 6);
        for (base[prefix.len..]) |byte| try std.testing.expect(std.ascii.isAlphanumeric(byte));
        const byte_path = try std.mem.concat(a, u8, &.{ base, ".\xff" });
        defer a.free(byte_path);
        errdefer cleanup(&manager, remote, base, byte_path) catch {};
        var write = try request(&manager, remote, .{ .exec = .{ .argv = &.{ "/bin/sh", "-c", "printf '\\000\\377DATA' > \"$1\"", "probe", byte_path } } });
        defer write.deinit();
        try std.testing.expectEqual(@as(i32, 0), write.value.exec.exit_code);
        var binary = try request(&manager, remote, .{ .read = .{ .path = byte_path, .limit = 16 } });
        defer binary.deinit();
        try std.testing.expectEqualStrings("\x00\xffDATA", binary.value.read.bytes);
        try std.testing.expect(binary.value.read.eof);
        var byte_stat = try request(&manager, remote, .{ .stat = byte_path });
        defer byte_stat.deinit();
        try std.testing.expectEqual(@as(u64, 6), byte_stat.value.stat.size);
        try cleanup(&manager, remote, base, byte_path);
    }
    const ticket = try manager.request(remote, .{ .exec = .{ .argv = &.{ "/bin/sleep", "30" } } }, 10000);
    try manager.cancel(ticket);
    var canceled = try wait(&manager, ticket);
    defer canceled.deinit();
    try std.testing.expectEqualStrings("cancelled", canceled.value.failure.code);
    const pending = try manager.request(remote, .{ .exec = .{ .argv = &.{ "/bin/sleep", "30" } } }, 10000);
    try manager.close(remote);
    const deadline = clock() + 10000 * std.time.ns_per_ms;
    while (try manager.status(remote) != .disconnected) {
        if (clock() >= deadline) return error.Timeout;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(2), .awake);
    }
    const fresh = try manager.connectAgent("windows-wsl", &argv);
    try ready(&manager, fresh);
    try std.testing.expect(fresh.generation != remote.generation);
    var old = try wait(&manager, pending);
    defer old.deinit();
    try std.testing.expectEqualStrings("transport_disconnected", old.value.failure.code);
    var alive = try request(&manager, fresh, .{ .info = {} });
    defer alive.deinit();
    try std.testing.expectEqualStrings("linux", alive.value.info.os);
}

fn cleanup(manager: *host.Manager, handle: host.Handle, base: []const u8, byte_path: []const u8) !void {
    // Only the two exact files created from our validated mktemp result.
    var removed = try request(manager, handle, .{ .exec = .{ .argv = &.{ "/bin/rm", "-f", "--", base, byte_path } } });
    defer removed.deinit();
    try std.testing.expectEqual(@as(i32, 0), removed.value.exec.exit_code);
}

fn ready(manager: *host.Manager, handle: host.Handle) !void {
    const deadline = clock() + 10000 * std.time.ns_per_ms;
    while (clock() < deadline) {
        switch (try manager.status(handle)) {
            .ready => return,
            .disconnected => return error.TransportDisconnected,
            .connecting => {},
        }
        try std.Io.sleep(std.testing.io, .fromMilliseconds(2), .awake);
    }
    return error.Timeout;
}
