//! Native host transport entry point.
pub const transport = @import("host/transport.zig");
pub const Connection = transport.Connection;
pub const Completion = transport.Completion;
const std = @import("std");

test {
    _ = @import("agent/protocol.zig");
    _ = transport;
}

fn connectAgent() !*Connection {
    const path = std.testing.environ.getAlloc(std.testing.allocator, "HOLLOW_TEST_AGENT") catch |err| switch (err) {
        error.EnvironmentVariableMissing => try std.testing.allocator.dupe(u8, "zig-out/bin/hollow-agent"),
        else => return err,
    };
    defer std.testing.allocator.free(path);
    const connection = try Connection.create(std.testing.allocator, std.testing.io, &.{ path, "stdio" });
    errdefer connection.destroy();
    const deadline = clock() + 6000 * std.time.ns_per_ms;
    while (connection.status() == .connecting) {
        if (clock() >= deadline) return error.Timeout;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    if (connection.status() != .ready) return connection.connectionFailure() orelse error.Disconnected;
    return connection;
}

fn clock() i128 {
    return std.Io.Clock.awake.now(std.testing.io).toNanoseconds();
}

fn awaitCompletion(connection: *Connection) !Completion {
    const deadline = clock() + 8000 * std.time.ns_per_ms;
    while (clock() < deadline) {
        if (connection.poll()) |completion| return completion;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    return error.Timeout;
}

fn execJson(connection: *Connection, command: []const u8) ![]u8 {
    const streams = try connection.allocateStreams();
    const encoder = std.base64.standard.Encoder;
    const encoded = try std.testing.allocator.alloc(u8, encoder.calcSize(command.len));
    defer std.testing.allocator.free(encoded);
    return std.fmt.allocPrint(std.testing.allocator, "{{\"op\":\"EXEC\",\"argv_b64\":[\"L2Jpbi9zaA==\",\"LWM=\",\"{s}\"],\"timeout_ms\":30000,\"stdout_stream_id\":{d},\"stderr_stream_id\":{d}}}", .{ encoder.encode(encoded, command), streams.stdout, streams.stderr });
}

test "persistent host transport routes concurrent fs and exec results" {
    const connection = try connectAgent();
    defer connection.destroy();
    const json = try execJson(connection, "sleep 0.2; printf 'hello'; printf 'problem' >&2; exit 7");
    defer std.testing.allocator.free(json);
    const exec_id = try connection.request(json, 3000);
    const info_id = try connection.request("{\"op\":\"HOST_INFO\"}", 3000);
    const first = try awaitCompletion(connection);
    defer connection.freeCompletion(first);
    try std.testing.expectEqual(info_id, first.id);
    try std.testing.expect(first.failure == null);
    try std.testing.expect(std.mem.indexOf(u8, first.metadata_json.?, "linux") != null);
    const second = try awaitCompletion(connection);
    defer connection.freeCompletion(second);
    try std.testing.expectEqual(exec_id, second.id);
    try std.testing.expect(second.failure == null);
    try std.testing.expectEqualStrings("hello", second.stdout);
    try std.testing.expectEqualStrings("problem", second.stderr);
    try std.testing.expect(std.mem.indexOf(u8, second.metadata_json.?, "\"exit_code\":7") != null);
    try std.testing.expectEqual(connection.generation, second.generation);
    try std.testing.expect(connection.poll() == null);
    for (0..4) |_| {
        const id = try connection.request("{\"op\":\"FS_READ\",\"path_b64\":\"L2V0Yy9vc y1yZWxlYXNl\",\"limit\":16384}", 3000);
        const result = try awaitCompletion(connection);
        defer connection.freeCompletion(result);
        try std.testing.expectEqual(id, result.id);
        // An invalid byte encoding is a per-request error, not a disconnect.
        try std.testing.expectEqual(error.RemoteError, result.failure.?);
    }
    const read_id = try connection.request("{\"op\":\"FS_READ\",\"path_b64\":\"L2V0Yy9vcy1yZWxlYXNl\",\"limit\":16384}", 3000);
    const read = try awaitCompletion(connection);
    defer connection.freeCompletion(read);
    try std.testing.expectEqual(read_id, read.id);
    try std.testing.expect(read.failure == null);
    try std.testing.expect(read.stdout.len > 0);
}

test "host transport cancellation and deadline complete once without replay" {
    const connection = try connectAgent();
    defer connection.destroy();
    const json = try execJson(connection, "trap '' TERM; sleep 30 & wait");
    defer std.testing.allocator.free(json);
    const timed_id = try connection.request(json, 50);
    const timed = try awaitCompletion(connection);
    defer connection.freeCompletion(timed);
    try std.testing.expectEqual(timed_id, timed.id);
    try std.testing.expectEqual(error.Timeout, timed.failure.?);
    const json2 = try execJson(connection, "sleep 30");
    defer std.testing.allocator.free(json2);
    const cancel_id = try connection.request(json2, 3000);
    try connection.cancel(cancel_id);
    const canceled = try awaitCompletion(connection);
    defer connection.freeCompletion(canceled);
    try std.testing.expectEqual(cancel_id, canceled.id);
    try std.testing.expectEqual(error.RemoteError, canceled.failure.?);
    try std.testing.expect(std.mem.indexOf(u8, canceled.metadata_json.?, "cancelled") != null);
    // Wait for the timed-out request's terminal acknowledgement; its slot is a
    // bounded tombstone and must not publish a second completion.
    try std.Io.sleep(std.testing.io, .fromMilliseconds(1800), .awake);
    try std.testing.expect(connection.poll() == null);
    try std.testing.expectEqual(transport.State.ready, connection.status());
}

test "host transport shutdown fails outstanding work and invalidates generation" {
    const connection = try connectAgent();
    defer connection.destroy();
    try std.testing.expectError(error.InvalidPayload, connection.request("[]", 1000));
    const json = try execJson(connection, "sleep 30");
    defer std.testing.allocator.free(json);
    const id = try connection.request(json, 3000);
    connection.close();
    const result = try awaitCompletion(connection);
    defer connection.freeCompletion(result);
    try std.testing.expectEqual(id, result.id);
    try std.testing.expect(result.failure != null);
    try std.testing.expect(connection.poll() == null);
    try std.testing.expectError(error.Disconnected, connection.request("{\"op\":\"HOST_INFO\"}", 1000));
    const next = try connectAgent();
    defer next.destroy();
    try std.testing.expect(next.generation != connection.generation);
    try std.testing.expect(!std.mem.eql(u8, next.nonce[0..next.nonce_len], connection.nonce[0..connection.nonce_len]));
}

test "host transport bounds slots and repeated binary captures" {
    const connection = try connectAgent();
    defer connection.destroy();
    const json = try execJson(connection, "head -c 1048576 /dev/zero");
    defer std.testing.allocator.free(json);
    const id = try connection.request(json, 3000);
    const output = try awaitCompletion(connection);
    defer connection.freeCompletion(output);
    try std.testing.expectEqual(id, output.id);
    try std.testing.expect(output.failure == null);
    try std.testing.expectEqual(@as(usize, 1048576), output.stdout.len);
    for (output.stdout) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    // Agent terminal responses do not free owner slots until consumed.
    for (0..connection.peer_requests) |_| _ = try connection.request("{\"op\":\"HOST_INFO\"}", 3000);
    try std.testing.expectError(error.ResourceExhausted, connection.request("{\"op\":\"HOST_INFO\"}", 3000));
    for (0..connection.peer_requests) |_| {
        const result = try awaitCompletion(connection);
        defer connection.freeCompletion(result);
        try std.testing.expect(result.failure == null);
    }
    try std.testing.expect(connection.poll() == null);
}

test "host transport agent crash fails each pending request exactly once" {
    const connection = try connectAgent();
    defer connection.destroy();
    _ = try connection.request("{\"op\":\"HOST_INFO\"}", 3000);
    const info = try awaitCompletion(connection);
    defer connection.freeCompletion(info);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, info.metadata_json.?, .{});
    defer parsed.deinit();
    const pid = parsed.value.object.get("agent_pid").?.integer;
    try std.testing.expect(pid > 1);
    const pending_json = try execJson(connection, "sleep 30");
    defer std.testing.allocator.free(pending_json);
    const pending = try connection.request(pending_json, 3000);
    // PID supplied by this owned connection, not by a fixture file or host scan.
    const command = try std.fmt.allocPrint(std.testing.allocator, "kill -KILL {d}", .{pid});
    defer std.testing.allocator.free(command);
    const crash_json = try execJson(connection, command);
    defer std.testing.allocator.free(crash_json);
    const crashing = try connection.request(crash_json, 3000);
    var seen_pending = false;
    var seen_crashing = false;
    for (0..2) |_| {
        const result = try awaitCompletion(connection);
        defer connection.freeCompletion(result);
        try std.testing.expectEqual(error.Disconnected, result.failure.?);
        if (result.id == pending) {
            try std.testing.expect(!seen_pending);
            seen_pending = true;
        } else {
            try std.testing.expectEqual(crashing, result.id);
            try std.testing.expect(!seen_crashing);
            seen_crashing = true;
        }
    }
    try std.testing.expect(seen_pending and seen_crashing);
    try std.testing.expect(connection.poll() == null);
}
