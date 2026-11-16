//! Suspended, handle-whitelisted keeper launch with overlapped parent pipes.
const std = @import("std");
const windows = std.os.windows;
const io = @import("../io.zig");
const pipe = @import("session_pipe_windows.zig");

const Startup = extern struct { info: windows.STARTUPINFOW, attributes: ?*anyopaque };
extern "kernel32" fn CreateFileW(windows.LPCWSTR, u32, u32, ?*windows.SECURITY_ATTRIBUTES, u32, u32, ?windows.HANDLE) callconv(.winapi) windows.HANDLE;
extern "kernel32" fn CreateProcessW(?windows.LPCWSTR, windows.LPWSTR, ?*windows.SECURITY_ATTRIBUTES, ?*windows.SECURITY_ATTRIBUTES, windows.BOOL, u32, ?*anyopaque, ?windows.LPCWSTR, *windows.STARTUPINFOW, *windows.PROCESS.INFORMATION) callconv(.winapi) windows.BOOL;
extern "kernel32" fn InitializeProcThreadAttributeList(?*anyopaque, u32, u32, *usize) callconv(.winapi) windows.BOOL;
extern "kernel32" fn UpdateProcThreadAttribute(?*anyopaque, u32, usize, ?*const anyopaque, usize, ?*anyopaque, ?*usize) callconv(.winapi) windows.BOOL;
extern "kernel32" fn DeleteProcThreadAttributeList(?*anyopaque) callconv(.winapi) void;

pub const Process = struct { child: std.process.Child, input: windows.HANDLE };

pub fn spawn(a: std.mem.Allocator, argv: []const []const u8) !Process {
    const input = try channel(a);
    errdefer pipe.close(input.server);
    defer pipe.close(input.child);
    const output = try channel(a);
    errdefer pipe.close(output.server);
    defer pipe.close(output.child);
    var security: windows.SECURITY_ATTRIBUTES = .{ .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES), .lpSecurityDescriptor = null, .bInheritHandle = .TRUE };
    const nul = CreateFileW(std.unicode.utf8ToUtf16LeStringLiteral("NUL"), 0x40000000, 3, &security, 3, 0, null);
    if (nul == windows.INVALID_HANDLE_VALUE) return error.InvalidStdio;
    defer pipe.close(nul);
    var attr_size: usize = 0;
    _ = InitializeProcThreadAttributeList(null, 1, 0, &attr_size);
    var attributes: [1024]u8 align(16) = undefined;
    if (attr_size > attributes.len) return error.ResourceExhausted;
    if (!InitializeProcThreadAttributeList(&attributes, 1, 0, &attr_size).toBool()) return error.AttributeListInitFailed;
    defer DeleteProcThreadAttributeList(&attributes);
    const handles = [_]windows.HANDLE{ input.child, output.child, nul };
    if (!UpdateProcThreadAttribute(&attributes, 0, 0x00020002, &handles, @sizeOf(@TypeOf(handles)), null, null).toBool()) return error.AttributeListUpdateFailed;
    var startup = std.mem.zeroes(Startup);
    startup.info.cb = @sizeOf(Startup);
    startup.info.dwFlags = windows.STARTF_USESTDHANDLES;
    startup.info.hStdInput = input.child;
    startup.info.hStdOutput = output.child;
    startup.info.hStdError = nul;
    startup.attributes = &attributes;
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(a);
    for (argv, 0..) |arg, index| {
        if (index > 0) try line.append(a, ' ');
        try appendArg(a, &line, arg);
    }
    const application = try std.unicode.utf8ToUtf16LeAllocZ(a, argv[0]);
    defer a.free(application);
    const command = try std.unicode.utf8ToUtf16LeAllocZ(a, line.items);
    defer a.free(command);
    if (command.len >= 32_767) return error.ResourceExhausted;
    var process = std.mem.zeroes(windows.PROCESS.INFORMATION);
    // Explicit handle list excludes owner pipes, jobs, and all sibling panes.
    if (!CreateProcessW(application, command, null, null, .TRUE, 0x08000000 | 0x00080000 | 0x00000400 | 0x00000004, null, null, &startup.info, &process).toBool()) {
        std.log.warn("WSL keeper CreateProcessW failed: {t}", .{windows.GetLastError()});
        return error.CreateProcessFailed;
    }
    return .{ .input = input.server, .child = .{
        .id = process.hProcess,
        .thread_handle = process.hThread,
        .stdin = null,
        .stdout = .{ .handle = output.server, .flags = .{ .nonblocking = false } },
        .stderr = null,
        .request_resource_usage_statistics = false,
    } };
}

const Channel = struct { server: windows.HANDLE, child: windows.HANDLE };

fn channel(a: std.mem.Allocator) !Channel {
    var random: [16]u8 = undefined;
    io.get().random(&random);
    const token = try std.fmt.allocPrint(a, "wsl-io-{s}", .{std.fmt.bytesToHex(random, .lower)});
    defer a.free(token);
    var endpoint = try pipe.Endpoint.init(a, token);
    defer endpoint.deinit(a);
    const server = try endpoint.server(true);
    errdefer pipe.close(server);
    var operation = try pipe.Operation.init();
    defer operation.deinit();
    try operation.accept(server);
    defer operation.cancel(server);
    var security: windows.SECURITY_ATTRIBUTES = .{ .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES), .lpSecurityDescriptor = null, .bInheritHandle = .TRUE };
    const child = CreateFileW(endpoint.name, 0xc0000000, 0, &security, 3, 0x00110000, null);
    if (child == windows.INVALID_HANDLE_VALUE) return error.PipeConnectFailed;
    errdefer pipe.close(child);
    try endpoint.validateSecurity(child, 6);
    _ = (try operation.result(server)) orelse return error.PipeConnectFailed;
    return .{ .server = server, .child = child };
}

fn appendArg(a: std.mem.Allocator, out: *std.ArrayList(u8), arg: []const u8) !void {
    // Match normal Windows argv construction. In particular wsl.exe reparses
    // its --exec tail and must not receive gratuitously quoted option words.
    if (arg.len > 0 and std.mem.indexOfAny(u8, arg, " \t\n\r\"") == null) {
        try out.appendSlice(a, arg);
        return;
    }
    try out.append(a, '"');
    var slashes: usize = 0;
    for (arg) |ch| switch (ch) {
        '\\' => slashes += 1,
        '"' => {
            try out.appendNTimes(a, '\\', slashes * 2 + 1);
            try out.append(a, '"');
            slashes = 0;
        },
        else => {
            try out.appendNTimes(a, '\\', slashes);
            try out.append(a, ch);
            slashes = 0;
        },
    };
    try out.appendNTimes(a, '\\', slashes * 2);
    try out.append(a, '"');
}

test "Windows keeper argv does not quote the WSL exec option tail gratuitously" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try appendArg(std.testing.allocator, &out, "--exec");
    try out.append(std.testing.allocator, ' ');
    try appendArg(std.testing.allocator, &out, "/usr/bin/env");
    try out.append(std.testing.allocator, ' ');
    try appendArg(std.testing.allocator, &out, "/path with space/agent");
    try std.testing.expectEqualStrings("--exec /usr/bin/env \"/path with space/agent\"", out.items);
}
