const std = @import("std");
const luajit = @import("lua/luajit.zig");
const platform = @import("platform.zig");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;

// On Windows, open files with full share flags to avoid WSL oplock conflicts.
const windows = if (is_windows) std.os.windows else void;
extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: u32,
    dwShareMode: u32,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: u32,
    dwFlagsAndAttributes: u32,
    hTemplateFile: ?*anyopaque,
) callconv(if (is_windows) .winapi else .C) if (is_windows) windows.HANDLE else noreturn;
extern "kernel32" fn DeleteFileW(lpFileName: [*:0]const u16) callconv(if (is_windows) .winapi else .C) if (is_windows) windows.BOOL else noreturn;

const GENERIC_READ: u32 = 0x80000000;
const GENERIC_WRITE: u32 = 0x40000000;
const FILE_SHARE_READ: u32 = 0x00000001;
const FILE_SHARE_WRITE: u32 = 0x00000002;
const FILE_SHARE_DELETE: u32 = 0x00000004;
const OPEN_EXISTING: u32 = 3;
const CREATE_ALWAYS: u32 = 2;
const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;

/// Convert a WSL path (/mnt/c/foo/bar) to a Windows path (C:\foo\bar).
/// Returns the input unchanged if it is not a WSL /mnt/<drive>/... path.
/// Caller must free the result.
fn wslToWindowsPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    // /mnt/X/... -> X:\...
    if (path.len >= 6 and
        std.mem.startsWith(u8, path, "/mnt/") and
        path[5] != '/')
    {
        const drive = std.ascii.toUpper(path[5]);
        const rest = if (path.len > 6) path[6..] else "";
        var buf = try allocator.alloc(u8, 3 + rest.len);
        buf[0] = drive;
        buf[1] = ':';
        buf[2] = '\\';
        for (rest, 3..) |c, i| buf[i] = if (c == '/') '\\' else c;
        return buf;
    }
    return allocator.dupe(u8, path);
}

/// Open a file for reading with full share flags (bypasses WSL oplocks on Windows).
fn openFileShared(allocator: std.mem.Allocator, path: []const u8) !std.fs.File {
    if (is_windows) {
        const win_path = try wslToWindowsPath(allocator, path);
        defer allocator.free(win_path);
        const path_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, win_path);
        defer allocator.free(path_w);
        const handle = CreateFileW(path_w.ptr, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
        if (handle == windows.INVALID_HANDLE_VALUE) return error.FileNotFound;
        return std.fs.File{ .handle = handle };
    } else {
        return std.fs.openFileAbsolute(path, .{});
    }
}

/// Create/truncate a file for writing with full share flags (bypasses WSL oplocks on Windows).
fn createFileShared(allocator: std.mem.Allocator, path: []const u8) !std.fs.File {
    if (is_windows) {
        const win_path = try wslToWindowsPath(allocator, path);
        defer allocator.free(win_path);
        const path_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, win_path);
        defer allocator.free(path_w);
        const handle = CreateFileW(path_w.ptr, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, null, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
        if (handle == windows.INVALID_HANDLE_VALUE) return error.AccessDenied;
        return std.fs.File{ .handle = handle };
    } else {
        return std.fs.createFileAbsolute(path, .{ .truncate = true });
    }
}

/// Delete a file by path, converting WSL paths to Windows paths if needed.
fn deleteFile(allocator: std.mem.Allocator, path: []const u8) void {
    if (is_windows) {
        const win_path = wslToWindowsPath(allocator, path) catch return;
        defer allocator.free(win_path);
        const path_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, win_path) catch return;
        defer allocator.free(path_w);
        _ = DeleteFileW(path_w.ptr);
    } else {
        std.fs.deleteFileAbsolute(path) catch {};
    }
}

pub const QueryHandler = *const fn (ctx: *anyopaque, pane_id: usize, channel: []const u8, params: ?std.json.Value) anyerror!luajit.HtpQueryResult;

pub const Server = struct {
    allocator: std.mem.Allocator,
    handler_ctx: *anyopaque,
    query_handler: QueryHandler,
    thread: ?std.Thread = null,
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    started: bool = false,
    request_dir_host: ?[]u8 = null,
    request_dir_shell: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, handler_ctx: *anyopaque, query_handler: QueryHandler) Server {
        return .{ .allocator = allocator, .handler_ctx = handler_ctx, .query_handler = query_handler };
    }

    pub fn deinit(self: *Server) void {
        self.stop();
        if (self.request_dir_host) |path| self.allocator.free(path);
        if (self.request_dir_shell) |path| self.allocator.free(path);
    }

    pub fn start(self: *Server) !void {
        if (self.started) return;
        const base = try platform.ensureHollowRuntimeDir(self.allocator);
        defer self.allocator.free(base);
        const host_dir = try std.fs.path.join(self.allocator, &.{ base, "htp-requests" });
        errdefer self.allocator.free(host_dir);
        std.fs.makeDirAbsolute(host_dir) catch |err| {
            if (err != error.PathAlreadyExists) {
                std.log.err("htp-fs: failed to create request dir: {s}", .{@errorName(err)});
                return err;
            }
        };
        self.request_dir_host = host_dir;
        self.request_dir_shell = try platform.runtimeDirForShell(self.allocator, host_dir);
        self.thread = try std.Thread.spawn(.{}, watchLoop, .{self});
        self.started = true;
    }

    pub fn stop(self: *Server) void {
        if (!self.started) return;
        self.stop_flag.store(true, .release);
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.started = false;
    }

    pub fn requestDirForShell(self: *const Server) ?[]const u8 {
        return self.request_dir_shell;
    }

    fn watchLoop(self: *Server) void {
        while (!self.stop_flag.load(.acquire)) {
            self.scanRequests();
            std.Thread.sleep(20 * std.time.ns_per_ms);
        }
    }

    fn scanRequests(self: *Server) void {
        const dir_path = self.request_dir_host orelse return;
        var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch |err| {
            std.log.warn("htp-fs: openDir err={s} path={s}", .{ @errorName(err), dir_path });
            return;
        };
        defer dir.close();
        var it = dir.iterate();
        while (true) {
            const entry = it.next() catch |err| {
                std.log.warn("htp-fs: iterate err={s}", .{@errorName(err)});
                break;
            };
            const e = entry orelse break;
            if (e.kind != .file) continue;
            if (!std.mem.endsWith(u8, e.name, ".request.json")) continue;
            self.handleRequestFile(dir_path, e.name) catch |err| switch (err) {
                // File disappeared between iterate() and open — already handled or shell cleaned up.
                error.FileNotFound => {},
                else => std.log.warn("htp-fs: handleRequestFile err={s} file={s}", .{ @errorName(err), e.name }),
            };
        }
    }

    fn handleRequestFile(self: *Server, dir_path: []const u8, file_name: []const u8) !void {
        const request_path = try std.fs.path.join(self.allocator, &.{ dir_path, file_name });
        defer self.allocator.free(request_path);

        const file = try openFileShared(self.allocator, request_path);
        defer file.close();
        const data = try file.readToEndAlloc(self.allocator, 65536);
        defer self.allocator.free(data);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, data, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |obj| obj,
            else => return,
        };
        const reply_file = switch (root.get("reply_file") orelse return) {
            .string => |v| v,
            else => return,
        };
        const pane_id = switch (root.get("pane_id") orelse return) {
            .integer => |v| if (v >= 0) @as(usize, @intCast(v)) else return,
            else => return,
        };
        const name = switch (root.get("name") orelse return) {
            .string => |v| v,
            else => return,
        };
        const params = root.get("params");

        const result = self.query_handler(self.handler_ctx, pane_id, name, params) catch |err| {
            try writeErrorFile(reply_file, self.allocator, @errorName(err));
            deleteFile(self.allocator, request_path);
            return;
        };
        defer result.deinit(self.allocator);

        if (!result.success) {
            try writeErrorFile(reply_file, self.allocator, result.error_message orelse "query failed");
            deleteFile(self.allocator, request_path);
            return;
        }

        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        try std.json.Stringify.value(.{
            .kind = "result",
            .status = "ok",
            .payload = result.value,
        }, .{}, &out.writer);
        const reply_out = try createFileShared(self.allocator, reply_file);
        defer reply_out.close();
        try reply_out.writeAll(out.written());
        deleteFile(self.allocator, request_path);
    }

    fn writeErrorFile(reply_file: []const u8, allocator: std.mem.Allocator, message: []const u8) !void {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try std.json.Stringify.value(.{
            .kind = "error",
            .status = "error",
            .@"error" = message,
        }, .{}, &out.writer);
        const reply_out = try createFileShared(allocator, reply_file);
        defer reply_out.close();
        try reply_out.writeAll(out.written());
    }
};

const TestQueryMode = enum {
    ok,
    fail,
};

const TestQueryContext = struct {
    mode: TestQueryMode,
    saw_pane_id: usize = 0,
    saw_expected_channel: bool = false,
    saw_expected_param: bool = false,
};

fn testQueryHandler(ctx_ptr: *anyopaque, pane_id: usize, channel: []const u8, params: ?std.json.Value) !luajit.HtpQueryResult {
    const ctx: *TestQueryContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.saw_pane_id = pane_id;
    ctx.saw_expected_channel = std.mem.eql(u8, channel, "ping");
    ctx.saw_expected_param = false;

    if (params) |value| {
        if (value == .object) {
            if (value.object.get("answer")) |answer| {
                ctx.saw_expected_param = answer == .integer and answer.integer == 42;
            }
        }
    }

    if (ctx.mode == .fail) return error.TestQueryFailure;

    return .{
        .success = true,
        .value = .{ .integer = 99 },
    };
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const file = try openFileShared(allocator, path);
    defer file.close();
    return try file.readToEndAlloc(allocator, max_bytes);
}

test "wslToWindowsPath converts mounted drive paths only" {
    const converted = try wslToWindowsPath(std.testing.allocator, "/mnt/c/Users/test/file.txt");
    defer std.testing.allocator.free(converted);
    try std.testing.expectEqualStrings("C:\\Users\\test\\file.txt", converted);

    const unchanged = try wslToWindowsPath(std.testing.allocator, "/tmp/hollow/request.json");
    defer std.testing.allocator.free(unchanged);
    try std.testing.expectEqualStrings("/tmp/hollow/request.json", unchanged);
}

test "handleRequestFile writes success reply and removes request" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    const request_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "query.request.json" });
    defer std.testing.allocator.free(request_path);
    const reply_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "query.reply.json" });
    defer std.testing.allocator.free(reply_path);

    const request_file = try createFileShared(std.testing.allocator, request_path);
    defer request_file.close();

    var request_out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer request_out.deinit();
    try std.json.Stringify.value(.{
        .reply_file = reply_path,
        .pane_id = 7,
        .name = "ping",
        .params = .{ .answer = 42 },
    }, .{}, &request_out.writer);
    try request_file.writeAll(request_out.written());

    var ctx = TestQueryContext{ .mode = .ok };
    var server = Server.init(std.testing.allocator, &ctx, testQueryHandler);

    try server.handleRequestFile(dir_path, "query.request.json");

    try std.testing.expectEqual(@as(usize, 7), ctx.saw_pane_id);
    try std.testing.expect(ctx.saw_expected_channel);
    try std.testing.expect(ctx.saw_expected_param);

    const reply_data = try readFileAlloc(std.testing.allocator, reply_path, 4096);
    defer std.testing.allocator.free(reply_data);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, reply_data, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("result", root.get("kind").?.string);
    try std.testing.expectEqualStrings("ok", root.get("status").?.string);
    try std.testing.expectEqual(@as(i64, 99), root.get("payload").?.integer);

    try std.testing.expectError(error.FileNotFound, openFileShared(std.testing.allocator, request_path));
}

test "handleRequestFile writes error reply when handler fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    const request_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "query.request.json" });
    defer std.testing.allocator.free(request_path);
    const reply_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "query.reply.json" });
    defer std.testing.allocator.free(reply_path);

    const request_file = try createFileShared(std.testing.allocator, request_path);
    defer request_file.close();

    var request_out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer request_out.deinit();
    try std.json.Stringify.value(.{
        .reply_file = reply_path,
        .pane_id = 3,
        .name = "ping",
    }, .{}, &request_out.writer);
    try request_file.writeAll(request_out.written());

    var ctx = TestQueryContext{ .mode = .fail };
    var server = Server.init(std.testing.allocator, &ctx, testQueryHandler);

    try server.handleRequestFile(dir_path, "query.request.json");

    const reply_data = try readFileAlloc(std.testing.allocator, reply_path, 4096);
    defer std.testing.allocator.free(reply_data);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, reply_data, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("error", root.get("kind").?.string);
    try std.testing.expectEqualStrings("error", root.get("status").?.string);
    try std.testing.expectEqualStrings("TestQueryFailure", root.get("error").?.string);

    try std.testing.expectError(error.FileNotFound, openFileShared(std.testing.allocator, request_path));
}
