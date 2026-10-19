//! AgentPty client against a real `hollow-agent pty` (HOLLOW_TEST_AGENT).
const std = @import("std");
const io = @import("io.zig");
const agent = @import("pty/agent.zig");

fn agentPath() ![]u8 {
    return std.testing.environ.getAlloc(std.testing.allocator, "HOLLOW_TEST_AGENT") catch |err| switch (err) {
        error.EnvironmentVariableMissing => error.SkipZigTest,
        else => err,
    };
}

fn request(shell: [:0]const u8, host: agent.Host) agent.Request {
    return .{
        .shell = shell,
        .cols = 80,
        .rows = 24,
        .cwd = "/",
        .env_block = "HOLLOW_TEST_VALUE=from-client\x00\x00",
        .launch_command = null,
        .host = host,
    };
}

/// Runs the preinstalled test agent locally (no connector).
fn local(path: []const u8) agent.Host {
    return .{ .agent = .{ .path = path } };
}

/// Reads until `needle` appears or the session ends; returns everything read.
fn readUntil(pty: *agent.AgentPty, out: *std.ArrayList(u8), needle: []const u8) !void {
    const deadline = io.nanoTimestamp() + 10 * std.time.ns_per_s;
    var buf: [4096]u8 = undefined;
    while (std.mem.indexOf(u8, out.items, needle) == null) {
        if (io.nanoTimestamp() > deadline) {
            std.debug.print("timed out waiting for {s}; got: {s}\n", .{ needle, out.items });
            return error.Timeout;
        }
        const n = try pty.read(&buf);
        if (n > 0) {
            try out.appendSlice(std.testing.allocator, buf[0..n]);
            continue;
        }
        if (!pty.isAlive()) return error.EndOfStream;
        try std.Io.sleep(io.get(), .fromMilliseconds(5), .awake);
    }
}

fn waitExit(pty: *agent.AgentPty) !?u32 {
    const deadline = io.nanoTimestamp() + 10 * std.time.ns_per_s;
    var buf: [4096]u8 = undefined;
    while (pty.isAlive()) {
        if (io.nanoTimestamp() > deadline) return error.Timeout;
        if (try pty.read(&buf) == 0) try std.Io.sleep(io.get(), .fromMilliseconds(5), .awake);
    }
    return pty.exitStatus();
}

test "agent pty runs a shell with env, size, resize, input and exit status" {
    const path = try agentPath();
    defer std.testing.allocator.free(path);
    var pty = try agent.AgentPty.init(std.testing.allocator, request("/bin/sh", local(path)), .{});
    defer pty.closeAndJoin();
    // Input and resizes before the agent starts are buffered and replayed.
    try pty.writeAll("stty size; echo \"v=$HOLLOW_TEST_VALUE\"\n");
    pty.resize(100, 30);
    try pty.start();
    try std.testing.expect(pty.isAlive());

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try readUntil(&pty, &out, "30 100");
    try readUntil(&pty, &out, "v=from-client");

    pty.resize(120, 40);
    try pty.writeAll("stty size\n");
    try readUntil(&pty, &out, "40 120");

    try pty.writeAll("exit 7\n");
    try std.testing.expectEqual(@as(?u32, 7), try waitExit(&pty));
}

test "agent pty close hangs up a running shell" {
    const path = try agentPath();
    defer std.testing.allocator.free(path);
    var pty = try agent.AgentPty.init(std.testing.allocator, request("/bin/sh", local(path)), .{});
    try pty.start();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try pty.writeAll("echo ready\n");
    try readUntil(&pty, &out, "ready\r\n");
    const started = io.nanoTimestamp();
    pty.closeAndJoin();
    try std.testing.expect(io.nanoTimestamp() - started < 2 * std.time.ns_per_s);
}

fn sha256Hex(path: []const u8) ![64]u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io.get(), path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

test "agent pty bootstraps the agent into the host cache, then reuses it" {
    const path = try agentPath();
    defer std.testing.allocator.free(path);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io.get(), ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    const home_env = try std.fmt.allocPrint(std.testing.allocator, "HOME={s}", .{home});
    defer std.testing.allocator.free(home_env);
    const sum = try sha256Hex(path);
    var host: agent.Host = .{ .connector = .{ .argv = &.{ "env", home_env } } };
    host.agent.artifacts.set(.x86_64, .{ .path = path, .sha256 = &sum });
    host.agent.artifacts.set(.aarch64, .{ .path = path, .sha256 = &sum });

    for (0..2) |round| {
        var pty = try agent.AgentPty.init(std.testing.allocator, request("/bin/sh", host), .{});
        defer pty.closeAndJoin();
        try pty.start();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(std.testing.allocator);
        try pty.writeAll("echo \"home=$HOME\"; exit 3\n");
        try readUntil(&pty, &out, "home=");
        try std.testing.expectEqual(@as(?u32, 3), try waitExit(&pty));
        if (round == 0) {
            // Deleting the install makes the cached path stale; the next pane
            // must notice and bootstrap again.
            const arch = if (@import("builtin").cpu.arch == .aarch64) "aarch64" else "x86_64";
            const installed = try std.fmt.allocPrint(std.testing.allocator, ".cache/hollow/agents/linux-{s}/{s}/hollow-agent", .{ arch, &sum });
            defer std.testing.allocator.free(installed);
            try tmp.dir.deleteFile(io.get(), installed);
        }
    }
}

test "agent pty reports a checksum mismatch" {
    const path = try agentPath();
    defer std.testing.allocator.free(path);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io.get(), ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    const home_env = try std.fmt.allocPrint(std.testing.allocator, "HOME={s}", .{home});
    defer std.testing.allocator.free(home_env);
    var host: agent.Host = .{ .connector = .{ .argv = &.{ "env", home_env } } };
    const wrong = "0" ** 64;
    host.agent.artifacts.set(.x86_64, .{ .path = path, .sha256 = wrong });
    host.agent.artifacts.set(.aarch64, .{ .path = path, .sha256 = wrong });
    var pty = try agent.AgentPty.init(std.testing.allocator, request("/bin/sh", host), .{});
    defer pty.closeAndJoin();
    try pty.start();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try std.testing.expectError(error.EndOfStream, readUntil(&pty, &out, "never"));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "checksum mismatch") != null);
}

test "unreachable implicit host requests native fallback with queued input" {
    var host: agent.Host = .{ .connector = .{ .argv = &.{"/bin/false"} }, .fallback = true };
    host.agent.artifacts.set(.x86_64, .{ .path = "/nonexistent", .sha256 = "0" ** 64 });
    var pty = try agent.AgentPty.init(std.testing.allocator, request("/bin/sh", host), .{});
    defer pty.closeAndJoin();
    try pty.writeAll("typed early");
    try pty.start();
    const deadline = io.nanoTimestamp() + 5 * std.time.ns_per_s;
    while (!pty.wantsFallback()) {
        if (io.nanoTimestamp() > deadline) return error.Timeout;
        try std.Io.sleep(io.get(), .fromMilliseconds(1), .awake);
    }
    const queued = try pty.takeQueuedInput(std.testing.allocator);
    defer std.testing.allocator.free(queued);
    try std.testing.expectEqualStrings("typed early", queued);
    try std.testing.expectEqualStrings("/bin/sh", pty.fallback_spec.shell);
}

test "explicit host failure reports in the pane and exits" {
    var pty = try agent.AgentPty.init(std.testing.allocator, request("/bin/sh", .{ .connector = .{ .argv = &.{"/nonexistent/hollow-connector"} }, .agent = .{ .path = "/agent" } }), .{});
    defer pty.closeAndJoin();
    try pty.start();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try std.testing.expectError(error.EndOfStream, readUntil(&pty, &out, "never"));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "[hollow]") != null);
    try std.testing.expectEqual(@as(?u32, agent.failure_status), pty.exitStatus());
    try std.testing.expect(!pty.wantsFallback());
}

test "a Lua descriptor error is shown in the pane" {
    var pty = try agent.AgentPty.init(std.testing.allocator, request("/bin/sh", .{ .error_message = "destination must be an SSH alias" }), .{});
    defer pty.closeAndJoin();
    try pty.start();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try std.testing.expectError(error.EndOfStream, readUntil(&pty, &out, "never"));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "destination must be an SSH alias") != null);
}

test "a stalled bootstrap is bounded by the host timeout and by close" {
    var host: agent.Host = .{ .connector = .{ .argv = &.{ "/bin/sh", "-c", "exec sleep 30", "x" } }, .agent = .{ .timeout_ms = 200 } };
    host.agent.artifacts.set(.x86_64, .{ .path = "/nonexistent", .sha256 = "0" ** 64 });
    var pty = try agent.AgentPty.init(std.testing.allocator, request("/bin/sh", host), .{});
    defer pty.closeAndJoin();
    try pty.start();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try std.testing.expectError(error.EndOfStream, readUntil(&pty, &out, "never"));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "timed out") != null);

    host.agent.timeout_ms = 60_000;
    var stalled = try agent.AgentPty.init(std.testing.allocator, request("/bin/sh", host), .{});
    try stalled.start();
    try std.Io.sleep(io.get(), .fromMilliseconds(50), .awake);
    const started = io.nanoTimestamp();
    stalled.closeAndJoin();
    try std.testing.expect(io.nanoTimestamp() - started < 2 * std.time.ns_per_s);
}

test "agent pty close is bounded while output is backpressured" {
    const path = try agentPath();
    defer std.testing.allocator.free(path);
    var flood = request("/bin/sh", local(path));
    flood.launch_command = .{ .command = "yes hollow" };
    var pty = try agent.AgentPty.init(std.testing.allocator, flood, .{});
    try pty.start();
    const deadline = io.nanoTimestamp() + 10 * std.time.ns_per_s;
    while (pty.pendingOutputBytes() < 1024 * 1024) {
        if (io.nanoTimestamp() > deadline) return error.Timeout;
        try std.Io.sleep(io.get(), .fromMilliseconds(5), .awake);
    }
    const started = io.nanoTimestamp();
    pty.closeAndJoin();
    try std.testing.expect(io.nanoTimestamp() - started < 4 * std.time.ns_per_s);
}

test "a connector speaking garbage is killed instead of hanging the pane" {
    var pty = try agent.AgentPty.init(std.testing.allocator, request("/bin/sh", .{ .connector = .{ .argv = &.{ "/bin/sh", "-c", "echo 'Welcome to box!'; exec sleep 30", "x" } }, .agent = .{ .path = "/agent" } }), .{});
    defer pty.closeAndJoin();
    try pty.start();
    const started = io.nanoTimestamp();
    try std.testing.expectEqual(@as(?u32, agent.failure_status), try waitExit(&pty));
    try std.testing.expect(io.nanoTimestamp() - started < 5 * std.time.ns_per_s);
}

test "a silent connector is killed once the host timeout passes" {
    var pty = try agent.AgentPty.init(std.testing.allocator, request("/bin/sh", .{ .connector = .{ .argv = &.{ "/bin/sh", "-c", "exec sleep 30", "x" } }, .agent = .{ .path = "/agent", .timeout_ms = 200 } }), .{});
    defer pty.closeAndJoin();
    try pty.start();
    const started = io.nanoTimestamp();
    try std.testing.expectEqual(@as(?u32, agent.failure_status), try waitExit(&pty));
    try std.testing.expect(io.nanoTimestamp() - started < 5 * std.time.ns_per_s);
}
