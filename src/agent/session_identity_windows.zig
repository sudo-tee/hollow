//! Stable Windows session host identity. Publish only after durable, atomic
//! creation, never rotate a malformed/insecure existing identity silently.
const std = @import("std");
const windows = std.os.windows;
const pipe = @import("session_pipe_windows.zig");
const p = @import("session_protocol.zig");

const Handle = windows.HANDLE;
const Info = extern struct {
    attributes: u32,
    creation: windows.FILETIME,
    accessed: windows.FILETIME,
    written: windows.FILETIME,
    volume: u32,
    size_high: u32,
    size_low: u32,
    links: u32,
    index_high: u32,
    index_low: u32,
};

extern "kernel32" fn CreateFileW(windows.LPCWSTR, u32, u32, ?*windows.SECURITY_ATTRIBUTES, u32, u32, ?Handle) callconv(.winapi) Handle;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn GetFileInformationByHandle(Handle, *Info) callconv(.winapi) windows.BOOL;
extern "kernel32" fn ReadFile(Handle, [*]u8, u32, *u32, ?*anyopaque) callconv(.winapi) windows.BOOL;
extern "kernel32" fn WriteFile(Handle, [*]const u8, u32, *u32, ?*anyopaque) callconv(.winapi) windows.BOOL;
extern "kernel32" fn FlushFileBuffers(Handle) callconv(.winapi) windows.BOOL;
extern "kernel32" fn MoveFileExW(windows.LPCWSTR, windows.LPCWSTR, u32) callconv(.winapi) windows.BOOL;
extern "kernel32" fn DeleteFileW(windows.LPCWSTR) callconv(.winapi) windows.BOOL;

pub fn random(io: std.Io) [32]u8 {
    var entropy: [16]u8 = undefined;
    std.Io.random(io, &entropy);
    return std.fmt.bytesToHex(entropy, .lower);
}

pub fn loadDefault(a: std.mem.Allocator, io: std.Io, environ: std.process.Environ, security: *const pipe.Endpoint) ![32]u8 {
    const root = try environ.getAlloc(a, "LOCALAPPDATA");
    defer a.free(root);
    if (!std.fs.path.isAbsolute(root) or std.mem.indexOfScalar(u8, root, 0) != null) return error.InvalidHostIdentityPath;
    const directory = try std.fs.path.join(a, &.{ root, "hollow", "sessions" });
    defer a.free(directory);
    return loadAt(a, io, security, directory);
}

/// Explicit directory injection is for isolated tests, not a CLI override.
/// Production calls this only after securing singleton endpoint ownership.
pub fn loadAt(a: std.mem.Allocator, io: std.Io, security: *const pipe.Endpoint, directory: []const u8) ![32]u8 {
    if (directory.len == 0 or directory.len > 32 * 1024 or std.mem.indexOfScalar(u8, directory, 0) != null) return error.InvalidHostIdentityPath;
    try std.Io.Dir.cwd().createDirPath(io, directory);
    const path = try std.fs.path.join(a, &.{ directory, "host-id" });
    defer a.free(path);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
    defer a.free(wide);
    if (try read(security, wide)) |id| return id;

    const id = random(io);
    const temporary = try std.fmt.allocPrint(a, "{s}.{s}.tmp", .{ path, &id });
    defer a.free(temporary);
    const temporary_w = try std.unicode.utf8ToUtf16LeAllocZ(a, temporary);
    defer a.free(temporary_w);
    var attributes: windows.SECURITY_ATTRIBUTES = .{
        .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = security.descriptor,
        .bInheritHandle = .FALSE,
    };
    // CREATE_NEW never truncates another writer's file or follows an existing
    // temporary reparse point. Only this invocation's admitted temp is removed.
    const handle = CreateFileW(temporary_w, 0x40000000, 0, &attributes, 1, 0x00200080, null);
    if (handle == windows.INVALID_HANDLE_VALUE) return failure(GetLastError());
    defer _ = DeleteFileW(temporary_w);
    {
        defer pipe.close(handle);
        var offset: usize = 0;
        while (offset < id.len) {
            var n: u32 = 0;
            if (WriteFile(handle, id[offset..].ptr, @intCast(id.len - offset), &n, null) == .FALSE) return failure(GetLastError());
            if (n == 0) return error.HostIdentityWriteFailed;
            offset += n;
        }
        if (FlushFileBuffers(handle) == .FALSE) return failure(GetLastError());
    }
    // No REPLACE_EXISTING: concurrent creators converge on the persisted winner.
    // WRITE_THROUGH completes the move before this identity can be advertised.
    if (MoveFileExW(temporary_w, wide, 0x8) == .FALSE) {
        const code = GetLastError();
        // Windows may report EXISTS, ACCESS_DENIED, or SHARING_VIOLATION for
        // a concurrently published destination opened by a reader. Accept only
        // that validated persisted winner, never this uncommitted candidate.
        return (try read(security, wide)) orelse failure(code);
    }
    return id;
}

fn read(security: *const pipe.Endpoint, path: [:0]const u16) !?[32]u8 {
    // OPEN_REPARSE_POINT plus handle-based attributes prevents following a
    // final-component symlink; no write/delete sharing while reading identity.
    const handle = CreateFileW(path, 0x80020000, 1, null, 3, 0x00200080, null);
    if (handle == windows.INVALID_HANDLE_VALUE) {
        const code = GetLastError();
        if (code == 2) return null;
        return failure(code);
    }
    defer pipe.close(handle);
    var info: Info = undefined;
    if (GetFileInformationByHandle(handle, &info) == .FALSE) return failure(GetLastError());
    if (info.attributes & (0x400 | 0x10) != 0 or info.size_high != 0 or info.size_low != 32) return error.InvalidHostIdentity;
    try security.validateSecurity(handle, 1);
    var bytes: [33]u8 = undefined;
    var count: u32 = 0;
    if (ReadFile(handle, &bytes, bytes.len, &count, null) == .FALSE) return failure(GetLastError());
    if (count != 32 or !p.validCreateId(bytes[0..32])) return error.InvalidHostIdentity;
    return bytes[0..32].*;
}

fn failure(code: u32) error{ AccessDenied, ResourceExhausted, HostIdentityBusy, HostIdentityIoFailed } {
    return switch (code) {
        5 => error.AccessDenied,
        8, 14, 1450 => error.ResourceExhausted,
        32, 33 => error.HostIdentityBusy,
        else => error.HostIdentityIoFailed,
    };
}

const TestDirectory = struct {
    path: []u8,
    dir: std.Io.Dir,

    fn init() !TestDirectory {
        const a = std.testing.allocator;
        const io = std.testing.io;
        // WSL's shared repository filesystem does not implement Windows file
        // security. Exercise real local file ACLs, never production state.
        const root = try std.testing.environ.getAlloc(a, "TEMP");
        defer a.free(root);
        if (!std.fs.path.isAbsolute(root)) return error.InvalidHostIdentityPath;
        const path = try std.fmt.allocPrint(a, "{s}\\hollow-identity-test-{s}", .{ root, &random(io) });
        errdefer a.free(path);
        try std.Io.Dir.createDirAbsolute(io, path, .default_dir);
        errdefer std.Io.Dir.cwd().deleteTree(io, path) catch {};
        return .{ .path = path, .dir = try std.Io.Dir.openDirAbsolute(io, path, .{}) };
    }

    fn deinit(self: *TestDirectory) void {
        self.dir.close(std.testing.io);
        std.Io.Dir.cwd().deleteTree(std.testing.io, self.path) catch @panic("identity fixture cleanup failed");
        std.testing.allocator.free(self.path);
    }
};

test "Windows session host identity survives reload and rejects corruption without replacement" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = try TestDirectory.init();
    defer tmp.deinit();
    const directory = tmp.path;
    var security = try pipe.Endpoint.init(a, "identity-file-fixture");
    defer security.deinit(a);
    const first = try loadAt(a, io, &security, directory);
    try std.testing.expect(p.validHost(&first));
    try std.testing.expectEqualSlices(u8, &first, &(try loadAt(a, io, &security, directory)));
    try tmp.dir.writeFile(io, .{ .sub_path = "host-id", .data = "bad-host-id" });
    try std.testing.expectError(error.InvalidHostIdentity, loadAt(a, io, &security, directory));
    const stored = try tmp.dir.readFileAlloc(io, "host-id", a, .limited(64));
    defer a.free(stored);
    try std.testing.expectEqualStrings("bad-host-id", stored);
}

test "Windows session host identity rejects inherited unprotected file security" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = try TestDirectory.init();
    defer tmp.deinit();
    const directory = tmp.path;
    try tmp.dir.writeFile(io, .{ .sub_path = "host-id", .data = "0123456789abcdef0123456789abcdef" });
    var security = try pipe.Endpoint.init(a, "identity-insecure-fixture");
    defer security.deinit(a);
    try std.testing.expectError(error.InsecurePipe, loadAt(a, io, &security, directory));
}

test "Windows concurrent host identity creators converge without replacement" {
    var tmp = try TestDirectory.init();
    defer tmp.deinit();
    var security = try pipe.Endpoint.init(std.testing.allocator, "identity-race-fixture");
    defer security.deinit(std.testing.allocator);
    const Writer = struct {
        start: *std.atomic.Value(u32),
        directory: []const u8,
        security: *const pipe.Endpoint,
        result: ?[32]u8 = null,
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            _ = self.start.fetchAdd(1, .acq_rel);
            while (self.start.load(.acquire) != 2) std.atomic.spinLoopHint();
            self.result = loadAt(std.heap.page_allocator, std.testing.io, self.security, self.directory) catch |err| {
                self.failure = err;
                return;
            };
        }
    };
    var start: std.atomic.Value(u32) = .init(0);
    var first: Writer = .{ .start = &start, .directory = tmp.path, .security = &security };
    var second = first;
    const thread = try std.Thread.spawn(.{}, Writer.run, .{&first});
    Writer.run(&second);
    thread.join();
    if (first.failure) |err| return err;
    if (second.failure) |err| return err;
    try std.testing.expectEqualSlices(u8, &first.result.?, &second.result.?);
    try std.testing.expectEqualSlices(u8, &first.result.?, &(try loadAt(std.testing.allocator, std.testing.io, &security, tmp.path)));
}
