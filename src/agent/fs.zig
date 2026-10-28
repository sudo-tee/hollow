const std = @import("std");
const linux = std.os.linux;
const c = @import("posix_c");

pub const Stat = struct { kind: []const u8, mode: u32, size: i64, mtime: i64 };

const max_path_len = 4096;
const max_name_len = 4096;
const max_read_len = 16 * 1024;
const max_list_len = 256;
const max_scan_len = 1_000_000;

const FsError = error{
    NotFound,
    PermissionDenied,
    InvalidPath,
    Unsupported,
    ResourceExhausted,
    LimitExceeded,
    InvalidOffset,
    NotRegularFile,
    IoError,
};

fn validatePath(path: []const u8) FsError!void {
    if (path.len == 0 or path.len > max_path_len or std.mem.indexOfScalar(u8, path, 0) != null)
        return error.InvalidPath;
}

fn errnoError(errno: c_int) FsError {
    return switch (errno) {
        c.ENOENT, c.ENOTDIR => error.NotFound,
        c.EACCES, c.EPERM => error.PermissionDenied,
        c.EINVAL, c.ENAMETOOLONG => error.InvalidPath,
        c.ENOSYS, c.ENOTSUP => error.Unsupported,
        c.ENOMEM, c.EMFILE, c.ENFILE, c.ENOSPC => error.ResourceExhausted,
        else => error.IoError,
    };
}

fn lastErrno() c_int {
    return c.__errno_location().*;
}

fn pathZ(allocator: std.mem.Allocator, path: []const u8) FsError![:0]u8 {
    try validatePath(path);
    return allocator.dupeSentinel(u8, path, 0) catch |err| switch (err) {
        error.OutOfMemory => error.ResourceExhausted,
    };
}

pub fn stat(path: []const u8) FsError!Stat {
    const z = try pathZ(std.heap.page_allocator, path);
    defer std.heap.page_allocator.free(z);

    var st: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, z, linux.AT.SYMLINK_NOFOLLOW, .BASIC_STATS, &st);
    if (linux.errno(rc) != .SUCCESS) return errnoError(@backingInt(linux.errno(rc)));
    if (!st.mask.TYPE or !st.mask.MODE or !st.mask.SIZE or !st.mask.MTIME) return error.Unsupported;
    const file_type = st.mode & c.S_IFMT;
    const kind: []const u8 = if (file_type == c.S_IFDIR) "directory" else if (file_type == c.S_IFLNK) "symlink" else if (file_type == c.S_IFREG) "file" else "other";
    return .{
        .kind = kind,
        .mode = st.mode,
        .size = std.math.cast(i64, st.size) orelse return error.Unsupported,
        .mtime = st.mtime.sec,
    };
}

pub fn read(allocator: std.mem.Allocator, path: []const u8, offset: u64, limit: usize) FsError![]u8 {
    if (limit > max_read_len) return error.LimitExceeded;
    if (offset > std.math.maxInt(i64)) return error.InvalidOffset;
    const z = try pathZ(allocator, path);
    defer allocator.free(z);

    const fd = c.open(z, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK);
    if (fd < 0) return errnoError(lastErrno());
    defer _ = c.close(fd);

    var st: linux.Statx = undefined;
    const rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true }, &st);
    if (linux.errno(rc) != .SUCCESS) return errnoError(@backingInt(linux.errno(rc)));
    if (!st.mask.TYPE) return error.Unsupported;
    if ((st.mode & c.S_IFMT) != c.S_IFREG) return error.NotRegularFile;

    const out = allocator.alloc(u8, limit) catch return error.ResourceExhausted;
    errdefer allocator.free(out);
    var n: isize = 0;
    while (true) {
        n = c.pread(fd, out.ptr, limit, @intCast(offset));
        if (n >= 0) break;
        const err = lastErrno();
        if (err == c.EINTR) continue;
        return errnoError(err);
    }
    const actual: usize = @intCast(n);
    if (actual == out.len) return out;
    return allocator.realloc(out, actual) catch error.ResourceExhausted;
}

pub fn list(allocator: std.mem.Allocator, path: []const u8, offset: usize, limit: usize) FsError![][]u8 {
    if (limit > max_list_len) return error.LimitExceeded;
    if (offset > max_scan_len) return error.LimitExceeded;
    const z = try pathZ(allocator, path);
    defer allocator.free(z);
    const dir = c.opendir(z) orelse return errnoError(lastErrno());
    defer _ = c.closedir(dir);
    if (limit == 0) return allocator.alloc([]u8, 0) catch error.ResourceExhausted;

    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    var seen: usize = 0;
    while (true) {
        c.__errno_location().* = 0;
        const entry = c.readdir(dir) orelse {
            const err = lastErrno();
            if (err != 0) return errnoError(err);
            break;
        };
        const raw_name = entry.*.d_name;
        const name_bytes = std.mem.sliceTo(&raw_name, 0);
        if (std.mem.eql(u8, name_bytes, ".") or std.mem.eql(u8, name_bytes, "..")) continue;
        if (seen >= max_scan_len) return error.LimitExceeded;
        if (seen >= offset) {
            if (name_bytes.len > max_name_len) return error.InvalidPath;
            const name = allocator.dupe(u8, name_bytes) catch return error.ResourceExhausted;
            names.append(allocator, name) catch {
                allocator.free(name);
                return error.ResourceExhausted;
            };
            if (names.items.len == limit) break;
        }
        seen += 1;
    }
    return names.toOwnedSlice(allocator) catch error.ResourceExhausted;
}

test "stat uses lstat semantics and maps missing paths" {
    const info = try stat("src/agent/fs.zig");
    try std.testing.expectEqualStrings("file", info.kind);
    try std.testing.expectError(error.NotFound, stat("src/agent/no-such-file"));
    try std.testing.expectError(error.InvalidPath, stat("bad\x00path"));
}

test "read is bounded, offset-safe, and rejects non-regular files" {
    const allocator = std.testing.allocator;
    const bytes = try read(allocator, "src/agent/fs.zig", 0, 5);
    defer allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 5), bytes.len);
    try std.testing.expectError(error.InvalidOffset, read(allocator, "src/agent/fs.zig", std.math.maxInt(u64), 1));
    try std.testing.expectError(error.LimitExceeded, read(allocator, "src/agent/fs.zig", 0, max_read_len + 1));
    try std.testing.expectError(error.NotRegularFile, read(allocator, ".", 0, 1));
}

test "list returns owned names and validates bounds" {
    const allocator = std.testing.allocator;
    const names = try list(allocator, "src/agent", 0, 4);
    defer {
        for (names) |name| allocator.free(name);
        allocator.free(names);
    }
    try std.testing.expect(names.len <= 4);
    try std.testing.expectError(error.LimitExceeded, list(allocator, ".", 0, max_list_len + 1));
    try std.testing.expectError(error.LimitExceeded, list(allocator, ".", max_scan_len + 1, 1));
}
