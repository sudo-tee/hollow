//! Immutable execution paths for managed native Windows owner bundles.
//! Callers bypass this cache for explicit agent paths and private namespaces.
//! Old versions are deliberately never replaced or collected: owners may be live.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const max_artifact = 64 * 1024 * 1024;
const executable = "hollow-agent.exe";

/// Returns a caller-owned root/<sha256>/hollow-agent.exe path, or fails closed.
/// Root is a caller-selected private LocalAppData directory (native TEMP in tests).
pub fn install(io: std.Io, a: Allocator, source: []const u8, root: []const u8) ![]const u8 {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    try validatePath(source);
    try validatePath(root);
    const bytes = try readArtifact(io, source);
    defer std.heap.page_allocator.free(bytes);
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const directory = try std.fs.path.join(a, &.{ root, &hex });
    defer a.free(directory);
    const path = try std.fs.path.join(a, &.{ directory, executable });
    errdefer a.free(path);
    try validatePath(path);
    if (try cached(io, path, digest)) return path;

    try std.Io.Dir.cwd().createDirPath(io, directory);
    // Exclusive creation admits exactly our own temporary file for cleanup.
    var attempts: usize = 0;
    while (attempts < 8) : (attempts += 1) {
        var random: [16]u8 = undefined;
        std.Io.random(io, &random);
        const temporary = try std.fmt.allocPrint(a, "{s}{s}.{s}.tmp", .{
            directory, std.fs.path.sep_str, std.fmt.bytesToHex(random, .lower),
        });
        defer a.free(temporary);
        const file = std.Io.Dir.createFileAbsolute(io, temporary, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        defer std.Io.Dir.cwd().deleteFile(io, temporary) catch {};
        {
            defer file.close(io);
            try file.writeStreamingAll(io, bytes);
            try file.sync(io);
        }
        // Zig's Windows implementation uses NtSetInformationFile with
        // REPLACE_IF_EXISTS=false, including its legacy Rename fallback.
        std.Io.Dir.renamePreserve(.cwd(), temporary, .cwd(), path, io) catch |err| switch (err) {
            error.PathAlreadyExists, error.AccessDenied, error.IsDir => {
                // Windows may report AccessDenied for an existing destination.
                // Only a completely validated winner permits convergence.
                if (try cached(io, path, digest)) return path;
                return err;
            },
            else => return err,
        };
        if (!try cached(io, path, digest)) return error.CachedOwnerMismatch;
        return path;
    }
    return error.ResourceExhausted;
}

fn validatePath(path: []const u8) !void {
    if (path.len == 0 or path.len > 32 * 1024 or
        std.mem.indexOfScalar(u8, path, 0) != null or !std.fs.path.isAbsolute(path))
        return error.InvalidArgument;
}

/// Stat and read the same handle; binary allocations never escape into a
/// connection's allocator. Bound reads even if the file grows after stat.
fn readArtifact(io: std.Io, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{ .allow_directory = false });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size == 0) return error.InvalidOwnerArtifact;
    if (stat.size > max_artifact) return error.StreamTooLong;
    var reader = file.reader(io, &.{});
    const bytes = reader.interface.allocRemaining(std.heap.page_allocator, .limited(max_artifact)) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        else => return err,
    };
    errdefer std.heap.page_allocator.free(bytes);
    if (bytes.len == 0 or bytes.len != stat.size) return error.InvalidOwnerArtifact;
    return bytes;
}

fn cached(io: std.Io, path: []const u8, expected: [Sha256.digest_length]u8) !bool {
    const bytes = readArtifact(io, path) catch |err| switch (err) {
        error.FileNotFound => return false,
        error.InvalidOwnerArtifact, error.StreamTooLong, error.IsDir, error.NotDir => return error.CachedOwnerMismatch,
        else => return err,
    };
    defer std.heap.page_allocator.free(bytes);
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    if (!std.mem.eql(u8, &digest, &expected)) return error.CachedOwnerMismatch;
    return true;
}

const Fixture = struct {
    root: []u8,
    source: []u8,
    cache: []u8,

    fn init() !Fixture {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        const a = std.testing.allocator;
        const temp = try std.testing.environ.getAlloc(a, "TEMP");
        defer a.free(temp);
        try validatePath(temp);
        var random: [16]u8 = undefined;
        std.Io.random(std.testing.io, &random);
        const name = try std.fmt.allocPrint(a, "hollow-owner-cache-{s}", .{std.fmt.bytesToHex(random, .lower)});
        defer a.free(name);
        const root = try std.fs.path.join(a, &.{ temp, name });
        errdefer a.free(root);
        // Never adopt or delete a preexisting directory, even on collision.
        try std.Io.Dir.createDirAbsolute(std.testing.io, root, .default_dir);
        errdefer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
        const source = try std.fs.path.join(a, &.{ root, "bundled owner.exe" });
        errdefer a.free(source);
        const cache = try std.fs.path.join(a, &.{ root, "private cache" });
        return .{ .root = root, .source = source, .cache = cache };
    }

    fn deinit(self: Fixture) void {
        std.Io.Dir.cwd().deleteTree(std.testing.io, self.root) catch {};
        std.testing.allocator.free(self.root);
        std.testing.allocator.free(self.source);
        std.testing.allocator.free(self.cache);
    }

    fn write(path: []const u8, bytes: []const u8) !void {
        const file = try std.Io.Dir.createFileAbsolute(std.testing.io, path, .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, bytes);
    }

    fn expectBytes(path: []const u8, expected: []const u8) !void {
        const bytes = try readArtifact(std.testing.io, path);
        defer std.heap.page_allocator.free(bytes);
        try std.testing.expectEqualStrings(expected, bytes);
    }
};

test "native owner cache reuses digest and preserves older bundles" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const a = std.testing.allocator;
    try Fixture.write(fixture.source, "fake owner version one");
    const first = try install(std.testing.io, a, fixture.source, fixture.cache);
    defer a.free(first);
    const again = try install(std.testing.io, a, fixture.source, fixture.cache);
    defer a.free(again);
    try std.testing.expectEqualStrings(first, again);
    try Fixture.write(fixture.source, "fake owner version two");
    const second = try install(std.testing.io, a, fixture.source, fixture.cache);
    defer a.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    try Fixture.expectBytes(first, "fake owner version one");
    try Fixture.expectBytes(second, "fake owner version two");
}

test "native owner cache rejects corruption without overwriting it" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try Fixture.write(fixture.source, "fake owner");
    const path = try install(std.testing.io, std.testing.allocator, fixture.source, fixture.cache);
    defer std.testing.allocator.free(path);
    try Fixture.write(path, "corruption");
    try std.testing.expectError(error.CachedOwnerMismatch, install(std.testing.io, std.testing.allocator, fixture.source, fixture.cache));
    try Fixture.expectBytes(path, "corruption");
    try Fixture.write(path, "");
    try std.testing.expectError(error.CachedOwnerMismatch, install(std.testing.io, std.testing.allocator, fixture.source, fixture.cache));
}

test "native owner cache concurrent installers converge" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try Fixture.write(fixture.source, "fake concurrent owner");
    const Worker = struct {
        fixture: Fixture,
        result: ?[]const u8 = null,
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            self.result = install(std.testing.io, std.heap.page_allocator, self.fixture.source, self.fixture.cache) catch |err| {
                self.failure = err;
                return;
            };
        }
    };
    var workers: [4]Worker = undefined;
    for (&workers) |*worker| worker.* = .{ .fixture = fixture };
    var threads: [workers.len]std.Thread = undefined;
    var started: usize = 0;
    defer {
        for (threads[0..started]) |thread| thread.join();
        for (workers) |worker| if (worker.result) |path| std.heap.page_allocator.free(path);
    }
    for (&workers, &threads) |*worker, *thread| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{worker});
        started += 1;
    }
    for (threads) |thread| thread.join();
    started = 0;
    for (workers) |worker| {
        if (worker.failure) |err| return err;
        try std.testing.expectEqualStrings(workers[0].result.?, worker.result.?);
    }
}

test "native owner cache rejects invalid paths and empty source" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try Fixture.write(fixture.source, "");
    try std.testing.expectError(error.InvalidOwnerArtifact, install(std.testing.io, std.testing.allocator, fixture.source, fixture.cache));
    try std.testing.expectError(error.InvalidArgument, install(std.testing.io, std.testing.allocator, fixture.source, "C:\\bad\x00root"));
    try std.testing.expectError(error.InvalidArgument, install(std.testing.io, std.testing.allocator, fixture.source, "relative"));
}

test "native owner cache rejects nonregular and oversized artifacts" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try Fixture.write(fixture.source, "fake owner");
    const path = try install(std.testing.io, std.testing.allocator, fixture.source, fixture.cache);
    defer std.testing.allocator.free(path);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, path);
    try std.Io.Dir.createDirAbsolute(std.testing.io, path, .default_dir);
    try std.testing.expectError(error.CachedOwnerMismatch, install(std.testing.io, std.testing.allocator, fixture.source, fixture.cache));
    // The size preflight rejects this without allocating 64 MiB.
    const file = try std.Io.Dir.createFileAbsolute(std.testing.io, fixture.source, .{});
    {
        defer file.close(std.testing.io);
        try file.setLength(std.testing.io, max_artifact + 1);
    }
    try std.testing.expectError(error.StreamTooLong, install(std.testing.io, std.testing.allocator, fixture.source, fixture.cache));
}

test "native owner cache leaves a Windows write-delete-locked version untouched" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const a = std.testing.allocator;
    try Fixture.write(fixture.source, "locked fake owner");
    const first = try install(std.testing.io, a, fixture.source, fixture.cache);
    defer a.free(first);
    const Win32 = struct {
        extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?std.os.windows.HANDLE) callconv(.winapi) std.os.windows.HANDLE;
    };
    const wide = try std.unicode.wtf8ToWtf16LeAllocZ(a, first);
    defer a.free(wide);
    // GENERIC_READ, FILE_SHARE_READ, OPEN_EXISTING: mimic a resident image's
    // prohibition on modifying or deleting its executable, without executing it.
    const handle = Win32.CreateFileW(wide, 0x80000000, 1, null, 3, 0, null);
    if (handle == std.os.windows.INVALID_HANDLE_VALUE) return error.FixtureLockFailed;
    defer std.os.windows.CloseHandle(handle);
    const again = try install(std.testing.io, a, fixture.source, fixture.cache);
    defer a.free(again);
    try std.testing.expectEqualStrings(first, again);
    try Fixture.write(fixture.source, "new fake owner");
    const second = try install(std.testing.io, a, fixture.source, fixture.cache);
    defer a.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    try Fixture.expectBytes(first, "locked fake owner");
}
