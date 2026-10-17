const std = @import("std");
const manager_mod = @import("host/manager.zig");
const Manager = manager_mod.Manager;
const Handle = manager_mod.Handle;
const Ticket = manager_mod.Ticket;
const Operation = manager_mod.operations.Operation;
const Result = manager_mod.operations.Result;

fn agentPath(allocator: std.mem.Allocator) ![]u8 {
    if (std.testing.environ.getAlloc(allocator, "HOLLOW_TEST_AGENT")) |path| return path else |_| {}
    return try allocator.dupe(u8, "zig-out/bin/hollow-agent");
}

fn waitReady(manager: *Manager, handle: Handle) !void {
    const deadline = std.Io.Clock.awake.now(std.testing.io).toNanoseconds() + 8000 * std.time.ns_per_ms;
    while (std.Io.Clock.awake.now(std.testing.io).toNanoseconds() < deadline) {
        if (try manager.status(handle) == .ready) return;
        if (try manager.status(handle) == .disconnected) return error.AgentDisconnected;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(2), .awake);
    }
    return error.AgentTimeout;
}

fn waitResult(manager: *Manager, ticket: Ticket) !Result {
    const deadline = std.Io.Clock.awake.now(std.testing.io).toNanoseconds() + 10000 * std.time.ns_per_ms;
    while (std.Io.Clock.awake.now(std.testing.io).toNanoseconds() < deadline) {
        if (try manager.poll(ticket)) |result| return result;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(2), .awake);
    }
    return error.RequestTimeout;
}

fn connect(manager: *Manager, id: []const u8, path: []const u8) !Handle {
    const argv = [_][]const u8{path};
    const handle = try manager.connectAgent(id, &argv);
    try waitReady(manager, handle);
    return handle;
}

fn expectFailure(result: *Result, code: []const u8) !void {
    try std.testing.expect(result.value == .failure);
    try std.testing.expectEqualStrings(code, result.value.failure.code);
}

test "manager typed exec preserves raw argv, cwd, env, streams, and nonzero exit" {
    const allocator = std.testing.allocator;
    const path = try agentPath(allocator);
    defer allocator.free(path);
    var manager = Manager.init(allocator, std.testing.io);
    defer manager.deinit();
    const host = try connect(&manager, "typed-exec", path);

    const script = "printf '%s|%s|%s|%s' \"$0\" \"$1\" \"$2\" \"$HOLLOW_TEST_VALUE\"; printf 'stderr:%s' \"$PWD\" >&2; exit 7";
    const weird: []const u8 = &.{ 'x', 0xff, 'y' };
    const argv = [_][]const u8{ "/bin/sh", "-c", script, "argv-zero", "", weird };
    const env = [_]manager_mod.operations.Env{.{ .key = "HOLLOW_TEST_VALUE", .value = "env-value" }};
    const ticket = try manager.request(host, .{ .exec = .{
        .argv = &argv,
        .cwd = "/tmp",
        .env = &env,
    } }, 10000);
    var result = try waitResult(&manager, ticket);
    defer result.deinit();
    try std.testing.expect(result.value == .exec);
    const exec = result.value.exec;
    try std.testing.expectEqual(@as(i32, 7), exec.exit_code);
    try std.testing.expectEqualSlices(u8, &.{ 'a', 'r', 'g', 'v', '-', 'z', 'e', 'r', 'o', '|', '|', 'x', 0xff, 'y', '|', 'e', 'n', 'v', '-', 'v', 'a', 'l', 'u', 'e' }, exec.stdout);
    try std.testing.expectEqualStrings("stderr:/tmp", exec.stderr);
}

test "manager multiplexes concurrent typed operation responses" {
    const allocator = std.testing.allocator;
    const path = try agentPath(allocator);
    defer allocator.free(path);
    var manager = Manager.init(allocator, std.testing.io);
    defer manager.deinit();
    const host = try connect(&manager, "multiplex", path);
    const info = try manager.request(host, .{ .info = {} }, 10000);
    const stat = try manager.request(host, .{ .stat = "/tmp" }, 10000);
    const argv = [_][]const u8{ "/bin/sh", "-c", "printf out; printf err >&2" };
    const exec = try manager.request(host, .{ .exec = .{ .argv = &argv } }, 10000);

    var info_result = try waitResult(&manager, info);
    defer info_result.deinit();
    var stat_result = try waitResult(&manager, stat);
    defer stat_result.deinit();
    var exec_result = try waitResult(&manager, exec);
    defer exec_result.deinit();
    try std.testing.expect(info_result.value == .info);
    try std.testing.expectEqualStrings("linux", info_result.value.info.os);
    try std.testing.expect(stat_result.value == .stat);
    try std.testing.expectEqualStrings("directory", stat_result.value.stat.kind);
    try std.testing.expect(exec_result.value == .exec);
    try std.testing.expectEqualStrings("out", exec_result.value.exec.stdout);
    try std.testing.expectEqualStrings("err", exec_result.value.exec.stderr);
}

test "manager disconnect retains old ticket across explicit stable-id reconnect" {
    const allocator = std.testing.allocator;
    const path = try agentPath(allocator);
    defer allocator.free(path);
    var manager = Manager.init(allocator, std.testing.io);
    defer manager.deinit();
    const old_host = try connect(&manager, "stable-host", path);
    const argv = [_][]const u8{ "/bin/sh", "-c", "sleep 2" };
    const old_ticket = try manager.request(old_host, .{ .exec = .{ .argv = &argv } }, 10000);
    try manager.close(old_host);
    const deadline = std.Io.Clock.awake.now(std.testing.io).toNanoseconds() + 5000 * std.time.ns_per_ms;
    while (try manager.status(old_host) != .disconnected and std.Io.Clock.awake.now(std.testing.io).toNanoseconds() < deadline)
        try std.Io.sleep(std.testing.io, .fromMilliseconds(2), .awake);
    try std.testing.expectEqual(.disconnected, try manager.status(old_host));

    const new_host = try connect(&manager, "stable-host", path);
    try std.testing.expectEqual(old_host.slot, new_host.slot);
    try std.testing.expect(old_host.generation != new_host.generation);
    try std.testing.expectEqualStrings("stable-host", try manager.hostId(new_host));
    var old_result = try waitResult(&manager, old_ticket);
    defer old_result.deinit();
    try expectFailure(&old_result, "transport_disconnected");

    try std.testing.expectError(error.StaleHost, manager.request(old_host, .{ .info = {} }, 1000));
    try std.testing.expectError(error.StaleRequest, manager.poll(old_ticket));
    try std.testing.expectError(error.StaleRequest, manager.cancel(old_ticket));
    const live = try manager.request(new_host, .{ .info = {} }, 10000);
    const stale_handle_ticket: Ticket = .{ .host = old_host, .id = live.id };
    try std.testing.expectError(error.StaleRequest, manager.cancel(stale_handle_ticket));
    var live_result = try waitResult(&manager, live);
    defer live_result.deinit();
    try std.testing.expect(live_result.value == .info);
}

test "manager bounds hosts and pending work and deinit frees unconsumed completions" {
    const allocator = std.testing.allocator;
    const path = try agentPath(allocator);
    defer allocator.free(path);
    var manager = Manager.init(allocator, std.testing.io);
    defer manager.deinit();
    var hosts: [manager_mod.max_hosts]Handle = undefined;
    for (&hosts, 0..) |*handle, i| {
        const id = try std.fmt.allocPrint(allocator, "bound-{d}", .{i});
        defer allocator.free(id);
        handle.* = try connect(&manager, id, path);
    }
    try manager.close(hosts[0]);
    const close_deadline = std.Io.Clock.awake.now(std.testing.io).toNanoseconds() + 5000 * std.time.ns_per_ms;
    while (try manager.status(hosts[0]) != .disconnected and std.Io.Clock.awake.now(std.testing.io).toNanoseconds() < close_deadline)
        try std.Io.sleep(std.testing.io, .fromMilliseconds(2), .awake);
    try manager.forget(hosts[0]);
    hosts[0] = try connect(&manager, "bound-replacement", path);
    try std.testing.expectError(error.ResourceExhausted, manager.connectAgent("ninth", &.{path}));
    var tickets: [manager_mod.max_pending]Ticket = undefined;
    for (&tickets, 0..) |*ticket, i| ticket.* = try manager.request(hosts[i % hosts.len], .{ .info = {} }, 10000);
    try std.testing.expectError(error.ResourceExhausted, manager.request(hosts[0], .{ .info = {} }, 10000));
    // Teardown owns pending requests and any completions already received.
}
