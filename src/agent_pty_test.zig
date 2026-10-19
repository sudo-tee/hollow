const std = @import("std");
const AgentPty = @import("pty/agent.zig").AgentPty;
const SharedConnection = @import("pty/agent.zig").SharedConnection;
const bulk_module = @import("agent_pty_bench_bulk.zig");
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

fn sharedConnection() !*SharedConnection {
    const path = try std.testing.environ.getAlloc(a, "HOLLOW_TEST_AGENT");
    defer a.free(path);
    const configured = std.testing.environ.getAlloc(a, "HOLLOW_TEST_CONNECTOR_ARGV") catch null;
    defer if (configured) |bytes| a.free(bytes);
    if (configured) |json| {
        const args = try std.json.parseFromSlice([]const []const u8, a, json, .{});
        defer args.deinit();
        return SharedConnection.create(a, args.value, .{});
    }
    return SharedConnection.create(a, &.{ path, "stdio" }, .{});
}

fn sharedOperation(connection: *@import("host/transport.zig").Connection, operation: @import("host/operations.zig").Operation) !@import("host/operations.zig").Result {
    const operations = @import("host/operations.zig");
    const deadline = clock() + 10 * std.time.ns_per_s;
    while (connection.status() != .ready) {
        if (connection.status() == .disconnected or clock() > deadline) return error.Timeout;
        try pause();
    }
    const json = try operations.encode(a, operation, if (operation == .exec) try connection.allocateStreams() else null);
    defer a.free(json);
    const id = try connection.request(json, 5000);
    defer connection.abandon(id);
    while (clock() < deadline) {
        if (connection.pollFor(id)) |completion| {
            defer connection.freeCompletion(completion);
            return operations.decode(a, std.meta.activeTag(operation), completion);
        }
        try pause();
    }
    return error.Timeout;
}

fn sharedExec(connection: *@import("host/transport.zig").Connection, argv: []const []const u8) ![]u8 {
    var result = try sharedOperation(connection, .{ .exec = .{ .argv = argv } });
    defer result.deinit();
    if (result.value != .exec or result.value.exec.exit_code != 0 or result.value.exec.stderr.len != 0) return error.BadExit;
    return a.dupe(u8, result.value.exec.stdout);
}

fn focusResult(owner: *SharedConnection, sequence: u64, group: u64, stream: u64, applied: bool) !void {
    const id = try owner.updateFocus(sequence, group, stream);
    defer owner.connection.abandon(id);
    const deadline = clock() + 5 * std.time.ns_per_s;
    while (clock() < deadline) {
        if (owner.connection.pollFor(id)) |completion| {
            defer owner.connection.freeCompletion(completion);
            try std.testing.expect(completion.failure == null);
            const parsed = try std.json.parseFromSlice(std.json.Value, a, completion.metadata_json.?, .{});
            defer parsed.deinit();
            try std.testing.expectEqual(applied, parsed.value.object.get("applied").?.bool);
            return;
        }
        try pause();
    }
    return error.Timeout;
}

test "explicit focus stays control-admitted at sixteen PTYs without stealing pane completions" {
    try fullFocus(false);
    try fullFocus(true);
}

fn fullFocus(deficit: bool) !void {
    // Local target-side flags, not inferred from the client environment or GUI.
    const path = try std.testing.environ.getAlloc(a, "HOLLOW_TEST_AGENT");
    defer a.free(path);
    const owner = try SharedConnection.createWithOptions(a, &.{ "/usr/bin/env", "HOLLOW_AGENT_BOUNDED_BULK=1", "HOLLOW_AGENT_FOCUS_SCHEDULER=1", "HOLLOW_AGENT_DEFICIT_SCHEDULER=1", path, "stdio" }, .{}, .{ .experimental_focus = true, .experimental_deficit = deficit });
    defer owner.destroy();
    try std.testing.expectError(error.InvalidArgument, AgentPty.spawnShared(a, owner, .{ .argv = &.{"/bin/sh"} }, 80, 24));
    var panes: [16]AgentPty = undefined;
    var count: usize = 0;
    defer for (panes[0..count]) |*pane| pane.deinit();
    for (&panes, 0..) |*pane, index| {
        pane.* = try AgentPty.spawnShared(a, owner, .{ .logical_session_id = 1 + index / 4, .argv = &.{ "/bin/sh", "-c", "printf FOCUS_READY; read line; printf '<%s>' \"$line\"" } }, 80, 24);
        count += 1;
        try until(pane, "FOCUS_READY");
    }
    try focusResult(owner, 10, 1, panes[0].output_stream.?, true);
    try focusResult(owner, 9, 4, panes[15].output_stream.?, false);
    try focusResult(owner, 11, 4, panes[15].output_stream.?, true);
    try focusResult(owner, 12, 0, 0, true);
    for (&panes) |*pane| {
        try pane.writeAll("focus-ok\n");
        try until(pane, "<focus-ok>");
        try finished(pane);
        try std.testing.expectEqual(@as(?u32, 0), pane.exitStatus());
    }
}

test "requested focus fails closed when peer omits focus capability" {
    const path = try std.testing.environ.getAlloc(a, "HOLLOW_TEST_AGENT");
    defer a.free(path);
    const owner = try SharedConnection.createWithOptions(a, &.{ "/usr/bin/env", "-u", "HOLLOW_AGENT_FOCUS_SCHEDULER", path, "stdio" }, .{}, .{ .experimental_focus = true });
    defer owner.destroy();
    const deadline = clock() + 5 * std.time.ns_per_s;
    while (owner.connection.status() == .connecting) {
        if (clock() > deadline) return error.Timeout;
        try pause();
    }
    try std.testing.expectEqual(@import("host/transport.zig").State.disconnected, owner.connection.status());
    try std.testing.expectError(error.Disconnected, owner.updateFocus(1, 0, 0));
}

test "requested deficit fails closed when peer only negotiates weighted focus" {
    const path = try std.testing.environ.getAlloc(a, "HOLLOW_TEST_AGENT");
    defer a.free(path);
    const owner = try SharedConnection.createWithOptions(a, &.{ "/usr/bin/env", "-u", "HOLLOW_AGENT_DEFICIT_SCHEDULER", "HOLLOW_AGENT_BOUNDED_BULK=1", "HOLLOW_AGENT_FOCUS_SCHEDULER=1", path, "stdio" }, .{}, .{ .experimental_focus = true, .experimental_deficit = true });
    defer owner.destroy();
    const deadline = clock() + 5 * std.time.ns_per_s;
    while (owner.connection.status() == .connecting) {
        if (clock() > deadline) return error.Timeout;
        try pause();
    }
    try std.testing.expectEqual(@import("host/transport.zig").State.disconnected, owner.connection.status());
    try std.testing.expectError(error.Disconnected, owner.updateFocus(1, 0, 0));
}

test "shared completed exec captures and oversized filesystem metadata remain exact" {
    const owner = try sharedConnection();
    defer owner.destroy();
    const directory = try sharedExec(owner.connection, &.{ "/bin/sh", "-c", "umask 077; p=$(mktemp -d /tmp/hollow-bulk-list-test.XXXXXX) || exit; trap 'rm -f -- \"$p\"/*; rmdir -- \"$p\"' EXIT; pad=$(printf '%0197d' 0); i=0; while [ \"$i\" -lt 256 ]; do name=$(printf '%03d-%s' \"$i\" \"$pad\"); : > \"$p/$name\" || exit; i=$((i+1)); done; trap - EXIT; printf '%s' \"$p\"" });
    defer a.free(directory);
    try std.testing.expect(std.mem.startsWith(u8, directory, "/tmp/hollow-bulk-list-test."));
    defer {
        if (sharedExec(owner.connection, &.{ "/bin/sh", "-c", "for f in \"$1\"/*; do rm -- \"$f\" || exit; done; rmdir -- \"$1\"", "hollow-owned-cleanup", directory })) |output| a.free(output) else |_| {}
    }
    var list = try sharedOperation(owner.connection, .{ .list = .{ .path = directory, .limit = 256 } });
    defer list.deinit();
    try std.testing.expect(list.value == .list);
    try std.testing.expectEqual(@as(usize, 256), list.value.list.entries.len);
    var seen: [256]bool = @splat(false);
    for (list.value.list.entries) |entry| {
        try std.testing.expectEqual(@as(usize, 201), entry.name.len);
        const index = try std.fmt.parseInt(u16, entry.name[0..3], 10);
        try std.testing.expect(index < 256 and !seen[index]);
        seen[index] = true;
        try std.testing.expectEqual(@as(u8, '-'), entry.name[3]);
        for (entry.name[4..]) |byte| try std.testing.expectEqual(@as(u8, '0'), byte);
    }
    var capture = try sharedOperation(owner.connection, .{ .exec = .{ .argv = &.{ "/bin/sh", "-c", "head -c 524288 /dev/zero; head -c 393216 /dev/zero >&2; exit 7" } } });
    defer capture.deinit();
    try std.testing.expect(capture.value == .exec);
    try std.testing.expectEqual(@as(i32, 7), capture.value.exec.exit_code);
    try std.testing.expectEqual(@as(usize, 524288), capture.value.exec.stdout.len);
    try std.testing.expectEqual(@as(usize, 393216), capture.value.exec.stderr.len);
    for (capture.value.exec.stdout) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    for (capture.value.exec.stderr) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    const missing_path = try std.fmt.allocPrint(a, "{s}/missing", .{directory});
    defer a.free(missing_path);
    var missing = try sharedOperation(owner.connection, .{ .stat = missing_path });
    defer missing.deinit();
    try std.testing.expect(missing.value == .failure);
    try std.testing.expectEqualStrings("not_found", missing.value.failure.code);
}

test "shared stalled PTY permits checked filesystem, exec, input and resize progress" {
    const owner = try sharedConnection();
    defer owner.destroy();
    const path = try sharedExec(owner.connection, &.{ "/bin/sh", "-c", "umask 077; p=$(mktemp /tmp/hollow-pty-bulk-test.XXXXXX) || exit; head -c 16384 /dev/zero > \"$p\" || exit; printf '%s' \"$p\"" });
    defer a.free(path);
    try std.testing.expect(std.mem.startsWith(u8, path, "/tmp/hollow-pty-bulk-test."));
    defer {
        // Remove only the unique file created by this test, on the same host.
        if (sharedExec(owner.connection, &.{ "/bin/rm", "--", path })) |output| a.free(output) else |_| {}
    }
    var stalled = try AgentPty.spawnShared(a, owner, .{ .argv = &.{ "/bin/sh", "-c", "stty raw -echo; head -c 4194304 /dev/zero; sleep 30" } }, 80, 24);
    defer stalled.deinit();
    const deadline = clock() + 15 * std.time.ns_per_s;
    while (stalled.pendingOutputBytes() < 65536) {
        if (clock() > deadline) return error.Timeout;
        try pause();
    }
    var sibling = try AgentPty.spawnShared(a, owner, .{ .argv = &.{ "/bin/sh", "-c", "stty -echo; printf READY; while read v; do printf '<%s>' \"$v\"; done" } }, 80, 24);
    defer sibling.deinit();
    try until(&sibling, "READY");
    var bulk = try bulk_module.Bulk.init(a, std.testing.io, .mixed, path, 524288, &.{}, .{}, owner.connection);
    defer bulk.deinit();
    var probes: usize = 0;
    while (probes < 20 or bulk.stats.fs.count < 2 or bulk.stats.exec.count < 2) : (probes += 1) {
        _ = try bulk.service();
        if (probes % 4 == 0) sibling.resize(@intCast(80 + (probes / 4) % 2), 24);
        try sibling.writeAll("rpc-probe\n");
        try until(&sibling, "<rpc-probe>");
        try std.testing.expectEqual(@as(usize, 65536), stalled.pendingOutputBytes());
        if (clock() > deadline) return error.Timeout;
    }
    try bulk.requireProgress();
    try std.testing.expectEqual(bulk.stats.fs.count * 16384, bulk.stats.fs_bytes);
    try std.testing.expectEqual(bulk.stats.exec.count * 524288, bulk.stats.exec_bytes);
    bulk.deinit();
    stalled.close();
    try sibling.writeAll("after-rpc-close\n");
    try until(&sibling, "<after-rpc-close>");
}

test "shared PTYs 1/4/8/16 route exits and controls without stealing completions" {
    for ([_]usize{ 1, 4, 8, 16 }) |count| {
        const owner = try sharedConnection();
        defer owner.destroy();
        var sessions: [16]AgentPty = undefined;
        var created: usize = 0;
        defer for (sessions[0..created]) |*pty| pty.deinit();
        for (sessions[0..count], 0..) |*pty, index| {
            const command = try std.fmt.allocPrint(a, "stty -echo; printf READY; read v; printf '<{d}:%s>' \"$v\"; exit {d}", .{ index, index });
            defer a.free(command);
            pty.* = try AgentPty.spawnShared(a, owner, .{ .argv = &.{ "/bin/sh", "-c", command } }, 80, 24);
            created += 1;
        }
        if (count == 16) try std.testing.expectError(error.ResourceExhausted, AgentPty.spawnShared(a, owner, .{ .argv = &.{"/bin/sh"} }, 80, 24));
        // Submit in reverse handle order: stream IDs must follow actual requests.
        var index = count;
        while (index > 0) {
            index -= 1;
            try until(&sessions[index], "READY");
        }
        // Sixteen long-lived spawn slots must leave room for input/resize RPCs.
        for (sessions[0..count]) |*pty| {
            pty.resize(100, 30);
            try pty.writeAll("payload\n");
        }
        index = count;
        while (index > 0) {
            index -= 1;
            const expected = try std.fmt.allocPrint(a, "<{d}:payload>", .{index});
            defer a.free(expected);
            try until(&sessions[index], expected);
            try finished(&sessions[index]);
            try std.testing.expectEqual(@as(?u32, @intCast(index)), sessions[index].exitStatus());
        }
        try std.testing.expectEqual(@import("host/transport.zig").State.ready, owner.connection.status());
    }
}

test "shared stalled consumer, close and failed launch do not stop sibling" {
    const owner = try sharedConnection();
    defer owner.destroy();
    var stalled = try AgentPty.spawnShared(a, owner, .{ .argv = &.{ "/bin/sh", "-c", "stty raw -echo; head -c 4194304 /dev/zero; sleep 30" } }, 80, 24);
    defer stalled.deinit();
    _ = stalled.isAlive();
    const deadline = clock() + 8 * std.time.ns_per_s;
    while (stalled.pendingOutputBytes() < 65536) {
        if (clock() > deadline) return error.Timeout;
        try pause();
    }
    var sibling = try AgentPty.spawnShared(a, owner, .{ .argv = &.{ "/bin/sh", "-c", "stty -echo; printf READY; while read v; do printf '<%s>' \"$v\"; done" } }, 80, 24);
    defer sibling.deinit();
    try until(&sibling, "READY");
    for (0..20) |_| {
        try sibling.writeAll("probe\n");
        try until(&sibling, "<probe>");
        try std.testing.expectEqual(@as(usize, 65536), stalled.pendingOutputBytes());
    }
    var failed = try AgentPty.spawnShared(a, owner, .{ .argv = &.{"/missing-shared-pty"} }, 80, 24);
    defer failed.deinit();
    try finished(&failed);
    try std.testing.expectEqual(@as(?u32, 125), failed.exitStatus());
    stalled.close();
    stalled.close();
    try sibling.writeAll("after-close\n");
    try until(&sibling, "<after-close>");
    // Repeated close/replacement also exercises asynchronous tombstone retirement.
    for (0..20) |_| {
        var replacement = try AgentPty.spawnShared(a, owner, .{ .argv = &.{ "/bin/sh", "-c", "printf REPLACED" } }, 80, 24);
        defer replacement.deinit();
        try until(&replacement, "REPLACED");
        try finished(&replacement);
    }
    try sibling.writeAll("still-alive\n");
    try until(&sibling, "<still-alive>");
}

test "shared owner shutdown retains live session storage until teardown" {
    const owner = try sharedConnection();
    var owner_live = true;
    defer if (owner_live) owner.destroy();
    var first = try AgentPty.spawnShared(a, owner, .{ .argv = &.{ "/bin/sh", "-c", "printf READY; sleep 30" } }, 80, 24);
    defer first.deinit();
    var second = try AgentPty.spawnShared(a, owner, .{ .argv = &.{ "/bin/sh", "-c", "sleep 30" } }, 80, 24);
    defer second.deinit();
    try until(&first, "READY");
    _ = second.isAlive();
    owner.destroy();
    owner_live = false;
    try finished(&first);
    try finished(&second);
    try std.testing.expectEqual(@as(?u32, 125), first.exitStatus());
    try std.testing.expectEqual(@as(?u32, 125), second.exitStatus());
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
    try std.testing.expectEqual(@as(usize, 65536), try pty.writeAllUntil(huge, clock() + std.time.ns_per_s));
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
