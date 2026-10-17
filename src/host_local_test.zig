const std = @import("std");
const local = @import("host/local.zig");
const operations = @import("host/operations.zig");

fn awaitResult(job: *local.Job) !operations.Result {
    const deadline = std.Io.Clock.awake.now(std.testing.io).toNanoseconds() + 5000 * std.time.ns_per_ms;
    while (std.Io.Clock.awake.now(std.testing.io).toNanoseconds() < deadline) {
        if (job.takeResult()) |value| return value;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    return error.Timeout;
}

fn run(operation: operations.Operation) !operations.Result {
    const job = try local.Job.create(std.testing.allocator, std.testing.io, std.testing.environ, operation, 3000);
    defer job.destroy();
    return awaitResult(job);
}

test "local Job validates and copies operation input before worker starts" {
    const allocator = std.testing.allocator;
    const source = try allocator.dupe(u8, "/definitely/not-present");
    const job = try local.Job.create(allocator, std.testing.io, .empty, .{ .stat = source }, 1000);
    allocator.free(source);
    defer job.destroy();
    var result = try awaitResult(job);
    defer result.deinit();
    try std.testing.expectEqualStrings("not_found", result.value.failure.code);
    try std.testing.expect(job.takeResult() == null);
}

test "native filesystem preserves binary names, pagination, symlinks and positional reads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = std.testing.allocator;
    try tmp.dir.writeFile(io, .{ .sub_path = " a\xff\n", .data = "A\x00\xffBCD" });
    try tmp.dir.createDir(io, "folder", .default_dir);
    try tmp.dir.symLink(io, " a\xff\n", "link", .{});
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, " a\xff\n" });
    defer a.free(path);
    const link = try std.fs.path.join(a, &.{ root, "link" });
    defer a.free(link);
    var non_regular = try run(.{ .read = .{ .path = root } });
    defer non_regular.deinit();
    try std.testing.expectEqualStrings("unsupported", non_regular.value.failure.code);
    var stat = try run(.{ .stat = link });
    defer stat.deinit();
    try std.testing.expectEqualStrings("symlink", stat.value.stat.kind);
    var read = try run(.{ .read = .{ .path = link, .offset = 1, .limit = 3 } });
    defer read.deinit();
    try std.testing.expectEqualStrings("\x00\xffB", read.value.read.bytes);
    try std.testing.expect(!read.value.read.eof);
    var past_end = try run(.{ .read = .{ .path = path, .offset = 999, .limit = 3 } });
    defer past_end.deinit();
    try std.testing.expectEqual(@as(usize, 0), past_end.value.read.bytes.len);
    try std.testing.expect(past_end.value.read.eof);
    var offset: u64 = 0;
    var seen: usize = 0;
    var saw_binary = false;
    for (0..5) |_| {
        var page = try run(.{ .list = .{ .path = root, .offset = offset, .limit = 1 } });
        defer page.deinit();
        try std.testing.expect(page.value.list.entries.len <= 1);
        for (page.value.list.entries) |entry| {
            seen += 1;
            if (std.mem.eql(u8, entry.name, " a\xff\n")) saw_binary = true;
        }
        if (page.value.list.eof) break;
        const next = page.value.list.next_offset.?;
        try std.testing.expect(next > offset);
        offset = next;
    }
    try std.testing.expectEqual(@as(usize, 3), seen);
    try std.testing.expect(saw_binary);
}

test "native exec preserves argv, byte environment and separate streams" {
    const env = [_]operations.Env{.{ .key = "HOLLOW_BYTES", .value = "\xff value" }};
    var value = try run(.{ .exec = .{ .argv = &.{ "/bin/sh", "-c", "printf '%s|%s|%s' \"$1\" \"$2\" \"$HOLLOW_BYTES\"; printf err >&2; exit 7", "test", "", "\xff argument" }, .cwd = "/tmp", .env = &env } });
    defer value.deinit();
    try std.testing.expectEqual(@as(i32, 7), value.value.exec.exit_code);
    try std.testing.expectEqualStrings("|\xff argument|\xff value", value.value.exec.stdout);
    try std.testing.expectEqualStrings("err", value.value.exec.stderr);
}

test "native cancellation and both deadline layers terminate direct children" {
    const op: operations.Operation = .{ .exec = .{ .argv = &.{ "/bin/sh", "-c", "exec sleep 30" } } };
    const cancelled = try local.Job.create(std.testing.allocator, std.testing.io, std.testing.environ, op, 3000);
    defer cancelled.destroy();
    // Allow launch before cancel; owner must not wait for blocked process I/O.
    try std.Io.sleep(std.testing.io, .fromMilliseconds(30), .awake);
    cancelled.cancel();
    var canceled_value = try awaitResult(cancelled);
    defer canceled_value.deinit();
    try std.testing.expectEqualStrings("cancelled", canceled_value.value.failure.code);
    const timeout = try local.Job.create(std.testing.allocator, std.testing.io, std.testing.environ, op, 20);
    defer timeout.destroy();
    var timed_value = try awaitResult(timeout);
    defer timed_value.deinit();
    try std.testing.expectEqualStrings("timeout", timed_value.value.failure.code);
    var process_timeout = try run(.{ .exec = .{ .argv = &.{ "/bin/sh", "-c", "exec sleep 30" }, .timeout_ms = 20 } });
    defer process_timeout.deinit();
    try std.testing.expectEqualStrings("timeout", process_timeout.value.failure.code);
}

test "native exec rejects combined output beyond configured cap" {
    var value = try run(.{ .exec = .{ .argv = &.{ "/bin/sh", "-c", "printf 1234567890; printf 1234567890 >&2" }, .output_limit = 12 } });
    defer value.deinit();
    try std.testing.expectEqualStrings("output_limit", value.value.failure.code);
}

test "local Job rejects operation limits through shared validator" {
    const allocator = std.testing.allocator;
    const path = "x";
    try std.testing.expectError(error.InvalidArgument, local.Job.create(allocator, std.testing.io, .empty, .{ .list = .{ .path = path, .limit = 257 } }, 1000));
    try std.testing.expectError(error.InvalidArgument, local.Job.create(allocator, std.testing.io, .empty, .{ .list = .{ .path = path, .limit = 0 } }, 1000));
    try std.testing.expectError(error.InvalidArgument, local.Job.create(allocator, std.testing.io, .empty, .{ .read = .{ .path = path, .limit = 16385 } }, 1000));
    _ = operations.Kind.info;
}
