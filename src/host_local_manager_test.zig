const std = @import("std");
const builtin = @import("builtin");
const host = @import("host.zig");

fn result(manager: *host.Manager, ticket: host.Ticket) !host.operations.Result {
    const end = std.Io.Clock.awake.now(std.testing.io).toNanoseconds() + 8000 * std.time.ns_per_ms;
    while (std.Io.Clock.awake.now(std.testing.io).toNanoseconds() < end) {
        if (try manager.poll(ticket)) |value| return value;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    return error.Timeout;
}

test "native-local manager dispatches the same typed fs and exec API" {
    var manager = host.Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    const handle = try manager.connectLocal("local");
    try std.testing.expectEqual(host.transport.State.ready, try manager.status(handle));
    const info = try manager.request(handle, .{ .info = {} }, 3000);
    const stat = try manager.request(handle, .{ .stat = "." }, 3000);
    const exec = try manager.request(handle, .{ .exec = .{ .argv = &.{ "/bin/sh", "-c", "printf hello; printf err >&2; exit 3" } } }, 3000);
    var info_value = try result(&manager, info);
    defer info_value.deinit();
    try std.testing.expectEqualStrings(@tagName(builtin.os.tag), info_value.value.info.os);
    var stat_value = try result(&manager, stat);
    defer stat_value.deinit();
    try std.testing.expectEqualStrings("directory", stat_value.value.stat.kind);
    var exec_value = try result(&manager, exec);
    defer exec_value.deinit();
    try std.testing.expectEqual(@as(i32, 3), exec_value.value.exec.exit_code);
    try std.testing.expectEqualStrings("hello", exec_value.value.exec.stdout);
    try std.testing.expectEqualStrings("err", exec_value.value.exec.stderr);
    try std.testing.expectError(error.StaleRequest, manager.poll(exec));
}

test "native-local close and reconnect isolate pending generations" {
    var manager = host.Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    const old = try manager.connectLocal("local");
    const ticket = try manager.request(old, .{ .exec = .{ .argv = &.{ "/bin/sh", "-c", "exec sleep 30" } } }, 3000);
    try manager.close(old);
    const fresh = try manager.connectLocal("local");
    try std.testing.expect(fresh.generation != old.generation);
    try std.testing.expectEqual(old.slot, fresh.slot);
    try std.testing.expectError(error.StaleHost, manager.request(old, .{ .info = {} }, 1000));
    var disconnected = try result(&manager, ticket);
    defer disconnected.deinit();
    try std.testing.expectEqualStrings("transport_disconnected", disconnected.value.failure.code);
    const next = try manager.request(fresh, .{ .info = {} }, 3000);
    var value = try result(&manager, next);
    defer value.deinit();
    try std.testing.expect(value.value == .info);
    try std.testing.expectError(error.StaleRequest, manager.cancel(ticket));
}

test "native-local retained requests enforce per-host bounds" {
    var manager = host.Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    const handle = try manager.connectLocal("local");
    var tickets: [16]host.Ticket = undefined;
    for (&tickets) |*ticket| ticket.* = try manager.request(handle, .{ .info = {} }, 3000);
    try std.testing.expectError(error.ResourceExhausted, manager.request(handle, .{ .info = {} }, 3000));
    for (tickets) |ticket| {
        var value = try result(&manager, ticket);
        defer value.deinit();
        try std.testing.expect(value.value == .info);
    }
    try std.testing.expectError(error.InvalidArgument, manager.request(handle, .{ .stat = "bad\x00path" }, 3000));
    try manager.close(handle);
    try manager.forget(handle);
    try std.testing.expectError(error.StaleHost, manager.status(handle));
}

test "closed drained hosts recycle capacity with stale handle isolation" {
    var manager = host.Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    const first = try manager.connectLocal("first");
    try manager.close(first);
    for (0..host.max_hosts * 3) |i| {
        var buffer: [32]u8 = undefined;
        const handle = try manager.connectLocal(try std.fmt.bufPrint(&buffer, "workspace-host-{d}", .{i}));
        try manager.close(handle);
    }
    try std.testing.expectError(error.StaleHost, manager.status(first));
    try std.testing.expectError(error.StaleHost, manager.request(first, .{ .info = {} }, 1000));
}

test "capacity recycling preserves retained old-generation requests" {
    var manager = host.Manager.init(std.testing.allocator, std.testing.io);
    defer manager.deinit();
    const first = try manager.connectLocal("retained");
    const ticket = try manager.request(first, .{ .info = {} }, 3000);
    try manager.close(first);
    for (0..host.max_hosts - 1) |i| {
        var buffer: [32]u8 = undefined;
        _ = try manager.connectLocal(try std.fmt.bufPrint(&buffer, "live-{d}", .{i}));
    }
    try std.testing.expectError(error.ResourceExhausted, manager.connectLocal("replacement"));
    var value = try result(&manager, ticket);
    value.deinit();
    const fresh = try manager.connectLocal("replacement");
    try std.testing.expectEqual(first.slot, fresh.slot);
    try std.testing.expect(first.generation != fresh.generation);
    try std.testing.expectError(error.StaleHost, manager.close(first));
    try std.testing.expectEqual(host.transport.State.ready, try manager.status(fresh));
}
