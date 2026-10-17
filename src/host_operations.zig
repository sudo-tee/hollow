const std = @import("std");
const operations = @import("host/operations.zig");
const transport = @import("host/transport.zig");

fn completion(metadata: ?[]const u8, failure: ?anyerror, stdout: []const u8, stderr: []const u8) transport.Completion {
    return .{ .id = 1, .generation = 1, .failure = failure, .metadata_json = metadata, .stdout_stream_id = 2, .stderr_stream_id = 4, .stdout = stdout, .stderr = stderr, .stdout_storage = .empty, .stderr_storage = .empty };
}

test "encoder base64 encodes arbitrary bytes and rejects nul" {
    const allocator = std.testing.allocator;
    const encoded = try operations.encode(allocator, .{ .stat = "p\xff" }, null);
    defer allocator.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "cP8=") != null);
    try std.testing.expectError(error.InvalidArgument, operations.encode(allocator, .{ .stat = "a\x00b" }, null));
    const argv = [_][]const u8{"x\x00y"};
    try std.testing.expectError(error.InvalidArgument, operations.encode(allocator, .{ .exec = .{ .argv = &argv } }, .{ .stdout = 2, .stderr = 4 }));
}

test "decoder owns non-UTF8 response bytes after completion lifetime" {
    const allocator = std.testing.allocator;
    const meta = try allocator.dupe(u8, "{\"bytes\":2,\"eof\":true}");
    const data = try allocator.dupe(u8, &[_]u8{ 0xff, 0x00 });
    const c = completion(meta, null, data, "");
    var result = try operations.decode(allocator, .read, c);
    allocator.free(meta);
    allocator.free(data);
    defer result.deinit();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xff, 0x00 }, result.value.read.bytes);
}

test "decoder checks malformed metadata and stream counts" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.ProtocolMismatch, operations.decode(allocator, .stat, completion("{}", null, "", "")));
    try std.testing.expectError(error.ProtocolMismatch, operations.decode(allocator, .read, completion("{\"bytes\":3,\"eof\":true}", null, "ab", "")));
}

test "exec nonzero exit remains successful typed result" {
    const allocator = std.testing.allocator;
    var result = try operations.decode(allocator, .exec, completion("{\"exit_code\":7,\"stdout_bytes\":1,\"stderr_bytes\":1,\"truncated\":false}", null, "o", "e"));
    defer result.deinit();
    try std.testing.expectEqual(@as(i32, 7), result.value.exec.exit_code);
}

test "remote errors and transport errors map to stable failure values" {
    const allocator = std.testing.allocator;
    var remote = try operations.decode(allocator, .info, completion("{\"code\":\"not_found\",\"message\":\"missing\",\"truncated\":true}", error.RemoteError, "", ""));
    defer remote.deinit();
    try std.testing.expectEqualStrings("not_found", remote.value.failure.code);
    var timeout = try operations.decode(allocator, .info, completion(null, error.Timeout, "", ""));
    defer timeout.deinit();
    try std.testing.expectEqualStrings("timeout", timeout.value.failure.code);
}

test "decoder cleans arena when allocation fails" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, operations.decode(failing.allocator(), .info, completion("{\"os\":\"linux\",\"arch\":\"x86_64\",\"protocol_major\":1,\"protocol_minor\":0,\"build\":\"agent\",\"cwd_b64\":\"Lw==\",\"home_b64\":\"Lw==\"}", null, "", "")));
}

test "list decoder preserves byte names and rejects path-shaped names" {
    var result = try operations.decode(std.testing.allocator, .list, completion("{\"entries\":[{\"name_b64\":\"eP8=\"}],\"next_offset\":1,\"done\":true}", null, "", ""));
    defer result.deinit();
    try std.testing.expectEqualStrings("x\xff", result.value.list.entries[0].name);
    try std.testing.expectEqualStrings("unknown", result.value.list.entries[0].kind);
    try std.testing.expectEqual(@as(?u64, 1), result.value.list.next_offset);
    try std.testing.expectError(error.ProtocolMismatch, operations.decode(std.testing.allocator, .list, completion("{\"entries\":[{\"name_b64\":\"Li4=\"}],\"next_offset\":1,\"done\":true}", null, "", "")));
}

fn decodeWithAllocationFailures(allocator: std.mem.Allocator) !void {
    var result = try operations.decode(allocator, .exec, completion("{\"exit_code\":0,\"stdout_bytes\":3,\"stderr_bytes\":2,\"truncated\":false}", null, "\x00\xffx", "er"));
    defer result.deinit();
}

test "all decoder allocation failure points release owned storage" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, decodeWithAllocationFailures, .{});
}
