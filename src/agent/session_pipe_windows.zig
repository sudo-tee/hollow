//! Session-only, current-user Windows named pipes. Operations must stay at a
//! stable address from submission until result/cancel completes.
const std = @import("std");
const windows = std.os.windows;
const Allocator = std.mem.Allocator;
const protocol = @import("session_protocol.zig");

pub const max_clients = 16;
const HANDLE = windows.HANDLE;
const BOOL = i32;
const invalid_handle: HANDLE = @ptrFromInt(std.math.maxInt(usize));
const client_access = 0x0012019b; // Read/write data, attributes, EA, READ_CONTROL, SYNCHRONIZE; NOT append/create-instance.

const Overlapped = extern struct {
    internal: usize = 0,
    internal_high: usize = 0,
    offset: u32 = 0,
    offset_high: u32 = 0,
    event: ?HANDLE = null,
};
const Acl = extern struct { revision: u8, reserved: u8, size: u16, count: u16, reserved2: u16 };
const Ace = extern struct { kind: u8, flags: u8, size: u16, mask: u32, sid: u32 };

extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
extern "kernel32" fn CloseHandle(HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn LocalFree(?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn CreateNamedPipeW([*:0]const u16, u32, u32, u32, u32, u32, u32, *windows.SECURITY_ATTRIBUTES) callconv(.winapi) HANDLE;
extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*windows.SECURITY_ATTRIBUTES, u32, u32, ?HANDLE) callconv(.winapi) HANDLE;
extern "kernel32" fn CreateEventW(?*windows.SECURITY_ATTRIBUTES, BOOL, BOOL, ?[*:0]const u16) callconv(.winapi) ?HANDLE;
extern "kernel32" fn ResetEvent(HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn SetEvent(HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn ConnectNamedPipe(HANDLE, *Overlapped) callconv(.winapi) BOOL;
extern "kernel32" fn DisconnectNamedPipe(HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn ReadFile(HANDLE, [*]u8, u32, ?*u32, *Overlapped) callconv(.winapi) BOOL;
extern "kernel32" fn WriteFile(HANDLE, [*]const u8, u32, ?*u32, *Overlapped) callconv(.winapi) BOOL;
extern "kernel32" fn GetOverlappedResult(HANDLE, *Overlapped, *u32, BOOL) callconv(.winapi) BOOL;
extern "kernel32" fn CancelIoEx(HANDLE, *Overlapped) callconv(.winapi) BOOL;
extern "advapi32" fn OpenProcessToken(HANDLE, u32, *HANDLE) callconv(.winapi) BOOL;
extern "advapi32" fn GetTokenInformation(HANDLE, u32, *anyopaque, u32, *u32) callconv(.winapi) BOOL;
extern "advapi32" fn ConvertSidToStringSidW(*anyopaque, *?[*:0]u16) callconv(.winapi) BOOL;
extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW([*:0]const u16, u32, *?*anyopaque, ?*u32) callconv(.winapi) BOOL;
extern "advapi32" fn GetSecurityDescriptorOwner(*anyopaque, *?*anyopaque, *BOOL) callconv(.winapi) BOOL;
extern "advapi32" fn GetSecurityDescriptorDacl(*anyopaque, *BOOL, *?*Acl, *BOOL) callconv(.winapi) BOOL;
extern "advapi32" fn GetSecurityDescriptorControl(*anyopaque, *u16, *u32) callconv(.winapi) BOOL;
extern "advapi32" fn GetSecurityInfo(HANDLE, u32, u32, *?*anyopaque, ?*?*anyopaque, *?*Acl, ?*?*anyopaque, *?*anyopaque) callconv(.winapi) u32;
extern "advapi32" fn EqualSid(*anyopaque, *anyopaque) callconv(.winapi) BOOL;
extern "advapi32" fn GetAce(*Acl, u32, *?*anyopaque) callconv(.winapi) BOOL;

pub fn close(handle: HANDLE) void {
    _ = CloseHandle(handle);
}

pub fn disconnect(handle: HANDLE) void {
    _ = DisconnectNamedPipe(handle);
}

fn failure(code: u32) error{ AccessDenied, PipeBusy, BrokenPipe, OperationAborted, ResourceExhausted, WindowsFailure } {
    return switch (code) {
        5 => error.AccessDenied,
        231 => error.PipeBusy,
        109, 232, 233 => error.BrokenPipe,
        995 => error.OperationAborted,
        8, 14, 1450 => error.ResourceExhausted,
        else => error.WindowsFailure,
    };
}

fn validateNamespace(namespace: ?[]const u8) !void {
    if (namespace) |ns| {
        if (ns.len == 0 or ns.len > 64) return error.InvalidArgument;
        for (ns) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return error.InvalidArgument;
    }
}

pub const Endpoint = struct {
    name: [:0]u16,
    descriptor: *anyopaque,
    sid: *anyopaque, // Owned by descriptor, not by the temporary token buffer.

    pub fn init(a: Allocator, namespace: ?[]const u8) !Endpoint {
        try validateNamespace(namespace);
        var token: HANDLE = undefined;
        if (OpenProcessToken(GetCurrentProcess(), 0x0008, &token) == 0) return failure(GetLastError());
        defer close(token);
        var token_user: [512]u8 align(@alignOf(usize)) = undefined;
        var required: u32 = 0;
        if (GetTokenInformation(token, 1, &token_user, token_user.len, &required) == 0) return failure(GetLastError());
        const user_sid = @as(*const extern struct { sid: *anyopaque, attributes: u32 }, @ptrCast(&token_user)).sid;
        var sid_w: ?[*:0]u16 = null;
        if (ConvertSidToStringSidW(user_sid, &sid_w) == 0) return failure(GetLastError());
        defer _ = LocalFree(@ptrCast(sid_w.?));
        const sid_text = try std.unicode.utf16LeToUtf8Alloc(a, std.mem.span(sid_w.?));
        defer a.free(sid_text);
        const sddl = try std.fmt.allocPrint(a, "O:{s}D:P(A;;GA;;;{s})", .{ sid_text, sid_text });
        defer a.free(sddl);
        const sddl_w = try std.unicode.utf8ToUtf16LeAllocZ(a, sddl);
        defer a.free(sddl_w);
        var descriptor: ?*anyopaque = null;
        if (ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl_w, 1, &descriptor, null) == 0) return failure(GetLastError());
        errdefer _ = LocalFree(descriptor);
        var sid: ?*anyopaque = null;
        var defaulted: BOOL = 0;
        if (GetSecurityDescriptorOwner(descriptor.?, &sid, &defaulted) == 0 or sid == null) return error.InvalidSecurityDescriptor;
        const text = try std.fmt.allocPrint(a, "\\\\.\\pipe\\hollow-session-{s}-v{d}{s}{s}", .{
            sid_text, protocol.version, if (namespace != null) "-" else "", namespace orelse "",
        });
        defer a.free(text);
        return .{ .name = try std.unicode.utf8ToUtf16LeAllocZ(a, text), .descriptor = descriptor.?, .sid = sid.? };
    }

    pub fn deinit(self: *Endpoint, a: Allocator) void {
        a.free(self.name);
        _ = LocalFree(self.descriptor);
        self.* = undefined;
    }

    pub fn server(self: *const Endpoint, first: bool) !HANDLE {
        var security: windows.SECURITY_ATTRIBUTES = .{
            .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
            .lpSecurityDescriptor = self.descriptor,
            .bInheritHandle = .FALSE,
        };
        const pipe = CreateNamedPipeW(self.name, 0x40000003 | @as(u32, if (first) 0x00080000 else 0), 0x8, max_clients, 65536, 65536, 0, &security);
        if (pipe == invalid_handle) {
            const code = GetLastError();
            if (first and code == 5) return error.OwnerExists;
            return failure(code);
        }
        return pipe;
    }

    pub fn connect(self: *const Endpoint) !?HANDLE {
        // SECURITY_IDENTIFICATION prevents a malicious endpoint impersonating us.
        const pipe = CreateFileW(self.name, client_access, 0, null, 3, 0x40110000, null);
        if (pipe == invalid_handle) {
            const code = GetLastError();
            if (code == 2) return null;
            return failure(code);
        }
        errdefer close(pipe);
        try self.validateSecurity(pipe, 6);
        return pipe;
    }

    /// Validate the same protected current-user-only security on a pipe or an
    /// owner state file. `object_type` is SE_KERNEL_OBJECT or SE_FILE_OBJECT.
    pub fn validateSecurity(self: *const Endpoint, handle: HANDLE, object_type: u32) !void {
        var owner: ?*anyopaque = null;
        var dacl: ?*Acl = null;
        var descriptor: ?*anyopaque = null;
        const status = GetSecurityInfo(handle, object_type, 0x5, &owner, null, &dacl, null, &descriptor);
        if (status != 0) return failure(status);
        defer _ = LocalFree(descriptor);
        if (owner == null or EqualSid(owner.?, self.sid) == 0) return error.InvalidPipeOwner;
        try self.validateDacl(descriptor.?);
    }

    fn validateDacl(self: *const Endpoint, descriptor: *anyopaque) !void {
        var control: u16 = 0;
        var revision: u32 = 0;
        if (GetSecurityDescriptorControl(descriptor, &control, &revision) == 0) return error.InvalidSecurityDescriptor;
        if (control & 0x1000 == 0) return error.InsecurePipe;
        var present: BOOL = 0;
        var defaulted: BOOL = 0;
        var acl: ?*Acl = null;
        if (GetSecurityDescriptorDacl(descriptor, &present, &acl, &defaulted) == 0) return error.InvalidSecurityDescriptor;
        if (present == 0 or acl == null or acl.?.count != 1) return error.InsecurePipe;
        var raw: ?*anyopaque = null;
        if (GetAce(acl.?, 0, &raw) == 0) return error.InvalidSecurityDescriptor;
        const ace: *Ace = @ptrCast(@alignCast(raw.?));
        if (ace.kind != 0 or ace.flags != 0 or EqualSid(@ptrCast(&ace.sid), self.sid) == 0) return error.InsecurePipe;
    }
};

pub const Operation = struct {
    event: HANDLE,
    overlapped: Overlapped = .{},
    pending: bool = false,
    completed: ?usize = null,

    pub fn init() !Operation {
        return .{ .event = CreateEventW(null, 1, 0, null) orelse return failure(GetLastError()) };
    }

    /// Caller must cancel pending I/O before freeing this operation or its buffer.
    pub fn deinit(self: *Operation) void {
        std.debug.assert(!self.pending);
        close(self.event);
        self.* = undefined;
    }

    fn begin(self: *Operation) !void {
        if (self.pending) return error.OperationPending;
        if (ResetEvent(self.event) == 0) return failure(GetLastError());
        self.overlapped = .{ .event = self.event };
        self.completed = null;
    }

    fn submitted(self: *Operation, ok: BOOL) !void {
        if (ok != 0) {
            self.pending = true;
            // Windows signals successful overlapped completions; explicitly signal
            // too, so every immediate completion has the same wait contract.
            _ = SetEvent(self.event);
        } else {
            const code = GetLastError();
            if (code != 997) return failure(code);
            self.pending = true;
        }
    }

    pub fn accept(self: *Operation, pipe: HANDLE) !void {
        try self.begin();
        const ok = ConnectNamedPipe(pipe, &self.overlapped);
        if (ok == 0 and GetLastError() == 535) {
            self.completed = 0;
            if (SetEvent(self.event) == 0) return failure(GetLastError());
            return;
        }
        try self.submitted(ok);
    }

    pub fn read(self: *Operation, pipe: HANDLE, buf: []u8) !void {
        if (buf.len > std.math.maxInt(u32)) return error.InvalidArgument;
        try self.begin();
        try self.submitted(ReadFile(pipe, buf.ptr, @intCast(buf.len), null, &self.overlapped));
    }

    pub fn write(self: *Operation, pipe: HANDLE, buf: []const u8) !void {
        if (buf.len > std.math.maxInt(u32)) return error.InvalidArgument;
        try self.begin();
        try self.submitted(WriteFile(pipe, buf.ptr, @intCast(buf.len), null, &self.overlapped));
    }

    pub fn result(self: *Operation, pipe: HANDLE) !?usize {
        if (self.completed) |n| return n;
        if (!self.pending) return error.NoOperation;
        var count: u32 = 0;
        if (GetOverlappedResult(pipe, &self.overlapped, &count, 0) == 0) {
            const code = GetLastError();
            if (code == 996) return null;
            self.pending = false;
            return failure(code);
        }
        self.pending = false;
        self.completed = count;
        return count;
    }

    /// Drains cancellation before OVERLAPPED or caller's buffer can be reused.
    pub fn cancel(self: *Operation, pipe: HANDLE) void {
        if (!self.pending) return;
        _ = CancelIoEx(pipe, &self.overlapped);
        var count: u32 = 0;
        _ = GetOverlappedResult(pipe, &self.overlapped, &count, 1);
        self.pending = false;
        self.completed = null;
    }
};

const TestPipe = struct {
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
    extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
    extern "kernel32" fn GetHandleInformation(HANDLE, *u32) callconv(.winapi) BOOL;

    var counter: std.atomic.Value(u32) = .init(0);

    fn namespace(buf: *[64]u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "pipe-test-{d}-{d}-{d}", .{
            GetCurrentProcessId(), GetTickCount64(), counter.fetchAdd(1, .monotonic),
        });
    }

    fn expectNoninheritable(handle: HANDLE) !void {
        var flags: u32 = 0;
        try std.testing.expect(GetHandleInformation(handle, &flags) != 0);
        try std.testing.expectEqual(@as(u32, 0), flags & 1);
    }
};

test "namespace is bounded and cannot escape pipe name" {
    try validateNamespace(null);
    try validateNamespace("fixture-123_ABC");
    const valid: [64]u8 = @splat('x');
    const too_long: [65]u8 = @splat('x');
    try validateNamespace(&valid);
    for ([_][]const u8{ "", &too_long, "../other", "a\\b", "a.b", "a\x00b", "é" }) |ns| {
        try std.testing.expectError(error.InvalidArgument, validateNamespace(ns));
    }
}

test "endpoint security, singleton, connected race, I/O, and cancellation" {
    const a = std.testing.allocator;
    var namespace_buf: [64]u8 = undefined;
    const namespace = try TestPipe.namespace(&namespace_buf);
    var endpoint = try Endpoint.init(a, namespace);
    defer endpoint.deinit(a);
    var same = try Endpoint.init(a, namespace);
    defer same.deinit(a);
    try std.testing.expectEqualSlices(u16, endpoint.name, same.name);
    try std.testing.expectEqual(@as(?HANDLE, null), try endpoint.connect());
    try endpoint.validateDacl(endpoint.descriptor);
    const server = try endpoint.server(true);
    defer close(server);
    try std.testing.expectError(error.OwnerExists, endpoint.server(true));
    const client = (try endpoint.connect()).?;
    defer close(client);
    try TestPipe.expectNoninheritable(server);
    try TestPipe.expectNoninheritable(client);
    var accept_op = try Operation.init();
    defer accept_op.deinit();
    try TestPipe.expectNoninheritable(accept_op.event);
    try accept_op.accept(server); // Client already connected: ERROR_PIPE_CONNECTED.
    defer accept_op.cancel(server);
    try std.testing.expectEqual(@as(?usize, 0), try accept_op.result(server));
    var reader = try Operation.init();
    defer reader.deinit();
    defer reader.cancel(server);
    var writer = try Operation.init();
    defer writer.deinit();
    defer writer.cancel(client);
    var buf: [8]u8 = undefined;
    try reader.read(server, &buf);
    try std.testing.expectEqual(@as(?usize, null), try reader.result(server));
    try writer.write(client, "hello");
    var count: u32 = 0;
    try std.testing.expect(GetOverlappedResult(server, &reader.overlapped, &count, 1) != 0);
    try std.testing.expectEqual(@as(?usize, 5), try reader.result(server));
    try std.testing.expectEqualStrings("hello", buf[0..5]);
    try std.testing.expectEqual(@as(?usize, 5), try writer.result(client));
    try reader.read(server, &buf);
    reader.cancel(server);
    reader.cancel(server);
    try reader.read(server, &buf);
    reader.cancel(server);
}

test "pending accept cancellation and first-instance reuse retain ownership" {
    var namespace_buf: [64]u8 = undefined;
    var endpoint = try Endpoint.init(std.testing.allocator, try TestPipe.namespace(&namespace_buf));
    defer endpoint.deinit(std.testing.allocator);
    const server = try endpoint.server(true);
    defer close(server);
    var op = try Operation.init();
    defer op.deinit();
    defer op.cancel(server);
    try op.accept(server);
    try std.testing.expectEqual(@as(?usize, null), try op.result(server));
    op.cancel(server);
    disconnect(server);
    try std.testing.expectError(error.OwnerExists, endpoint.server(true));
    try op.accept(server);
    const client = (try endpoint.connect()).?;
    defer close(client);
    var count: u32 = 0;
    try std.testing.expect(GetOverlappedResult(server, &op.overlapped, &count, 1) != 0);
    try std.testing.expectEqual(@as(?usize, 0), try op.result(server));
}

test "security rejects null and other-user DACLs" {
    var namespace_buf: [64]u8 = undefined;
    var endpoint = try Endpoint.init(std.testing.allocator, try TestPipe.namespace(&namespace_buf));
    defer endpoint.deinit(std.testing.allocator);
    for ([_][:0]const u16{
        std.unicode.utf8ToUtf16LeStringLiteral("D:NO_ACCESS_CONTROL"),
        std.unicode.utf8ToUtf16LeStringLiteral("D:P(A;;GA;;;WD)"),
        std.unicode.utf8ToUtf16LeStringLiteral("D:(A;;GA;;;WD)"),
    }) |sddl| {
        var descriptor: ?*anyopaque = null;
        try std.testing.expect(ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, 1, &descriptor, null) != 0);
        defer _ = LocalFree(descriptor);
        try std.testing.expectError(error.InsecurePipe, endpoint.validateDacl(descriptor.?));
    }
}

test "connect rejects an actual pipe with a broad protected DACL" {
    var namespace_buf: [64]u8 = undefined;
    var endpoint = try Endpoint.init(std.testing.allocator, try TestPipe.namespace(&namespace_buf));
    defer endpoint.deinit(std.testing.allocator);
    const a = std.testing.allocator;
    var sid_w: ?[*:0]u16 = null;
    try std.testing.expect(ConvertSidToStringSidW(endpoint.sid, &sid_w) != 0);
    defer _ = LocalFree(@ptrCast(sid_w.?));
    const sid_text = try std.unicode.utf16LeToUtf8Alloc(a, std.mem.span(sid_w.?));
    defer a.free(sid_text);
    const sddl = try std.fmt.allocPrint(a, "O:{s}D:P(A;;GA;;;WD)", .{sid_text});
    defer a.free(sddl);
    const sddl_w = try std.unicode.utf8ToUtf16LeAllocZ(a, sddl);
    defer a.free(sddl_w);
    var descriptor: ?*anyopaque = null;
    try std.testing.expect(ConvertStringSecurityDescriptorToSecurityDescriptorW(
        sddl_w,
        1,
        &descriptor,
        null,
    ) != 0);
    defer _ = LocalFree(descriptor);
    // Keep the correct owner: rejection must be due to the actual pipe's DACL.
    var security: windows.SECURITY_ATTRIBUTES = .{
        .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = descriptor,
        .bInheritHandle = .FALSE,
    };
    const server = CreateNamedPipeW(endpoint.name, 0x40080003, 0x8, max_clients, 65536, 65536, 0, &security);
    try std.testing.expect(server != invalid_handle);
    defer close(server);
    try std.testing.expectError(error.InsecurePipe, endpoint.connect());
}
