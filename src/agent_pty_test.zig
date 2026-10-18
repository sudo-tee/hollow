const std = @import("std");
const AgentPty = @import("pty/agent.zig").AgentPty;
const a = std.testing.allocator;

fn create(argv: []const []const u8) !AgentPty {
    const path = try std.testing.environ.getAlloc(a, "HOLLOW_TEST_AGENT");
    defer a.free(path);
    const configured = std.testing.environ.getAlloc(a, "HOLLOW_TEST_CONNECTOR_ARGV") catch null;
    defer if (configured) |bytes| a.free(bytes);
    if (configured) |json| {
        const args = try std.json.parseFromSlice([]const []const u8, a, json, .{});
        defer args.deinit();
        return AgentPty.spawn(a, .{ .connector_argv = args.value, .argv = argv }, 80, 24, .{});
    }
    return AgentPty.spawn(a, .{ .connector_argv = &.{ path, "stdio" }, .argv = argv }, 80, 24, .{});
}
fn clock() i128 {
    return std.Io.Clock.awake.now(std.testing.io).toNanoseconds();
}
fn pause() !void {
    try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
}
fn until(pty: *AgentPty, needle: []const u8) !void {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(a);
    const deadline = clock() + 8 * std.time.ns_per_s;
    while (clock() < deadline) {
        var buffer: [16384]u8 = undefined;
        const count = try pty.read(&buffer);
        try output.appendSlice(a, buffer[0..count]);
        if (std.mem.indexOf(u8, output.items, needle) != null) return;
        if (!pty.isAlive()) return error.EarlyExit;
        if (output.items.len > 1024 * 1024) return error.OutputLimit;
        try pause();
    }
    return error.Timeout;
}
fn finished(pty: *AgentPty) !void {
    const deadline = clock() + 8 * std.time.ns_per_s;
    while (pty.isAlive()) {
        var bytes: [16384]u8 = undefined;
        _ = try pty.read(&bytes);
        if (clock() > deadline) return error.Timeout;
        try pause();
    }
}

test "native agent PTY starts asynchronously, preserves queued input and exit status" {
    var pty = try create(&.{ "/bin/sh", "-c", "stty -echo; printf READY; read v; printf '<%s>' \"$v\"; exit 7" });
    defer pty.deinit();
    try until(&pty, "READY");
    try pty.writeAll("hello\n");
    try until(&pty, "<hello>");
    try finished(&pty);
    try std.testing.expectEqual(@as(?u32, 7), pty.exitStatus());
    try std.testing.expectEqual(@as(usize, 0), pty.childPid());
}

test "native agent PTY resize and Ctrl-C use terminal foreground semantics" {
    var pty = try create(&.{ "/bin/sh", "-c", "stty -echo; trap 'stty size' WINCH; printf READY; while :; do read v; done" });
    defer pty.deinit();
    try until(&pty, "READY");
    pty.resize(123, 47);
    try until(&pty, "47 123");
    var shell = try create(&.{ "/bin/sh", "-i" });
    defer shell.deinit();
    try shell.writeAll("printf SHELL_READY\\n\n");
    try until(&shell, "SHELL_READY");
    try shell.writeAll("sleep 30\n");
    try std.Io.sleep(std.testing.io, .fromMilliseconds(100), .awake);
    try shell.writeAll("\x03");
    try shell.writeAll("printf AFTER_INTERRUPT\\n\n");
    try until(&shell, "AFTER_INTERRUPT");
    try shell.writeAll("exit 0\n");
    try finished(&shell);
    try std.testing.expectEqual(@as(?u32, 0), shell.exitStatus());
}

test "native agent PTY streams beyond capture limit and drains final bytes before exit" {
    var pty = try create(&.{ "/bin/sh", "-c", "stty raw -echo; head -c 2097152 /dev/zero; exit 9" });
    defer pty.deinit();
    const deadline = clock() + 15 * std.time.ns_per_s;
    var total: usize = 0;
    while (pty.isAlive()) {
        var buffer: [16384]u8 = undefined;
        const count = try pty.read(&buffer);
        for (buffer[0..count]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
        total += count;
        try std.testing.expect(pty.pendingOutputBytes() <= 65536);
        if (clock() > deadline) return error.Timeout;
        if (count == 0) try pause();
    }
    try std.testing.expectEqual(@as(usize, 2097152), total);
    try std.testing.expectEqual(@as(?u32, 9), pty.exitStatus());
}

test "native agent PTY input admission is bounded, atomic and deadline-aware" {
    var pty = try create(&.{ "/bin/sh", "-c", "sleep 30" });
    defer pty.deinit();
    const huge = try a.alloc(u8, 65537);
    defer a.free(huge);
    @memset(huge, 'x');
    try std.testing.expectError(error.InputQueueFull, pty.writeAll(huge));
    try std.testing.expectEqual(@as(usize, 0), pty.input.items.len);
    try std.testing.expectEqual(@as(usize, 0), try pty.writeAllUntil("not queued", clock() - 1));
    try std.testing.expectEqual(@as(usize, 0), pty.input.items.len);
    pty.close();
    pty.close();
    try std.testing.expectError(error.WriteFailed, pty.writeAll("late"));
}

test "native agent PTY failed launch terminates without a local PID or reconnect" {
    var pty = try create(&.{"/hollow-missing-native-pty-program"});
    defer pty.deinit();
    try finished(&pty);
    try std.testing.expectEqual(@as(?u32, 125), pty.exitStatus());
}

test "native agent PTY retries full remote input without losing or duplicating bytes" {
    var pty = try create(&.{ "/bin/sh", "-c", "stty raw -echo; ready=0; trap 'ready=1' WINCH; printf READY; while [ \"$ready\" = 0 ]; do sleep 0.01; done; head -c 196608 | sha256sum; printf DRAINED" });
    defer pty.deinit();
    try until(&pty, "READY");
    const payload = try a.alloc(u8, 196608);
    defer a.free(payload);
    for (payload, 0..) |*byte, index| byte.* = @intCast('a' + index / 16384);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
    const expected = std.fmt.bytesToHex(digest, .lower);
    var sent: usize = 0;
    var retried = false;
    const deadline = clock() + 8 * std.time.ns_per_s;
    while (sent < 196608) {
        sent += try pty.writeAllUntil(payload[sent..][0..16384], deadline);
        if (!retried and pty.retry_at != 0) {
            retried = true;
            pty.resize(81, 25); // Release the reader only after real backpressure.
        }
        if (clock() > deadline) return error.Timeout;
        try pause();
    }
    try until(&pty, &expected);
    try finished(&pty);
    try std.testing.expect(retried);
    try std.testing.expectEqual(@as(?u32, 0), pty.exitStatus());
}

test "native agent PTY wake callback reports startup and scheduled input retry" {
    const path = try std.testing.environ.getAlloc(a, "HOLLOW_TEST_AGENT");
    defer a.free(path);
    var count = std.atomic.Value(usize).init(0);
    const Callback = struct {
        fn wake(context: *anyopaque) void {
            const counter: *std.atomic.Value(usize) = @ptrCast(@alignCast(context));
            _ = counter.fetchAdd(1, .monotonic);
        }
    };
    var pty = try AgentPty.spawn(a, .{ .connector_argv = &.{ path, "stdio" }, .argv = &.{ "/bin/sh", "-c", "sleep 30" } }, 80, 24, .{ .context = &count, .callback = Callback.wake });
    defer pty.deinit();
    const deadline = clock() + 8 * std.time.ns_per_s;
    while (pty.connection.status() == .connecting) {
        if (clock() > deadline) return error.Timeout;
        try pause();
    }
    try std.testing.expect(count.load(.monotonic) >= 1);
    const before = count.load(.monotonic);
    pty.connection.wakeAfter(10);
    while (count.load(.monotonic) == before) {
        if (clock() > deadline) return error.Timeout;
        try pause();
    }
    try std.Io.sleep(std.testing.io, .fromMilliseconds(30), .awake);
    try std.testing.expectEqual(before + 1, count.load(.monotonic));
}

test "native agent PTY transport loss fails only its own pane without replay" {
    var one = try create(&.{ "/bin/sh", "-c", "printf ONE; exec sleep 30" });
    defer one.deinit();
    var two = try create(&.{ "/bin/sh", "-c", "stty -echo; printf TWO; read v; printf '<%s>' \"$v\"; exit 3" });
    defer two.deinit();
    try until(&one, "ONE");
    try until(&two, "TWO");
    const generation = one.connection.generation;
    one.connection.close();
    try finished(&one);
    try std.testing.expectEqual(@as(?u32, 125), one.exitStatus());
    try std.testing.expectEqual(generation, one.connection.generation);
    try std.testing.expectError(error.WriteFailed, one.writeAll("not replayed"));
    try two.writeAll("survivor\n");
    try until(&two, "<survivor>");
    try finished(&two);
    try std.testing.expectEqual(@as(?u32, 3), two.exitStatus());
}

test "pane PTY union retains the native and agent surfaces" {
    const Pty = @import("pty/pty.zig").Pty;
    std.testing.refAllDecls(Pty);
    var pty = Pty{ .agent = try create(&.{ "/bin/sh", "-c", "printf WRAPPER; exit 6" }) };
    defer pty.deinit();
    const deadline = clock() + 8 * std.time.ns_per_s;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(a);
    while (pty.isAlive()) {
        var bytes: [128]u8 = undefined;
        const count = try pty.read(&bytes);
        try output.appendSlice(a, bytes[0..count]);
        if (clock() > deadline) return error.Timeout;
        try pause();
    }
    try std.testing.expectEqualStrings("WRAPPER", output.items);
    try std.testing.expectEqual(@as(?u32, 6), pty.exitStatus());
    try std.testing.expect(!@import("pty/pty.zig").usesWslBypass(&pty));
}

test "pane spawn selects only explicit agent config and rejects implicit launch commands" {
    const module = @import("pty/pty.zig");
    var pty = try module.spawn(a, "/hollow-shell-must-not-run", 80, 24, "/hollow-native-cwd-must-not-be-inferred", null, null, .{});
    defer pty.deinit();
    try std.testing.expect(module.usesAgent(&pty));
    const deadline = clock() + 8 * std.time.ns_per_s;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(a);
    while (pty.isAlive()) {
        var bytes: [128]u8 = undefined;
        const count = try pty.read(&bytes);
        try output.appendSlice(a, bytes[0..count]);
        if (clock() > deadline) return error.Timeout;
        try pause();
    }
    try std.testing.expectEqualStrings("PANE_ENTRY", output.items);
    try std.testing.expectEqual(@as(?u32, 4), pty.exitStatus());
    try std.testing.expectError(error.InvalidArgument, module.spawn(a, "/bin/sh", 80, 24, null, null, .{ .command = "do not ignore me", .close_on_exit = true }, .{}));
}
