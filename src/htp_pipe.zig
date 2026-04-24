const std = @import("std");
const windows = std.os.windows;

const PIPE_ACCESS_DUPLEX: windows.DWORD = 0x00000002;
const PIPE_TYPE_MESSAGE: windows.DWORD = 0x00000004;
const PIPE_READMODE_MESSAGE: windows.DWORD = 0x00000002;
const PIPE_WAIT: windows.DWORD = 0;
const PIPE_UNLIMITED_INSTANCES: windows.DWORD = 255;

extern "kernel32" fn CreateNamedPipeA(
    lpName: [*:0]const u8,
    dwOpenMode: windows.DWORD,
    dwPipeMode: windows.DWORD,
    nMaxInstances: windows.DWORD,
    nOutBufferSize: windows.DWORD,
    nInBufferSize: windows.DWORD,
    dwDefaultTimeout: windows.DWORD,
    lpSecurityAttributes: ?*windows.SECURITY_ATTRIBUTES,
) callconv(.winapi) windows.HANDLE;

extern "kernel32" fn ConnectNamedPipe(
    hNamedPipe: windows.HANDLE,
    lpOverlapped: ?*windows.OVERLAPPED,
) callconv(.winapi) windows.BOOL;

pub const Server = struct {
    allocator: std.mem.Allocator,
    app: *anyopaque,
    // Handler should return the response JSON as a slice, allocated by the provided allocator.
    handler_fn: ?*const fn (ctx: *anyopaque, payload: []const u8, allocator: std.mem.Allocator) ?[]const u8,

    thread: ?std.Thread = null,
    running: bool = true,

    pub fn init(allocator: std.mem.Allocator, app: *anyopaque, handler_fn: ?*const fn (ctx: *anyopaque, payload: []const u8, allocator: std.mem.Allocator) ?[]const u8) Server {
        return .{
            .allocator = allocator,
            .app = app,
            .handler_fn = handler_fn,
        };
    }

    pub fn start(self: *Server) !void {
        self.thread = try std.Thread.spawn(.{}, listenLoop, .{self});
    }

    pub fn stop(self: *Server) void {
        self.running = false;
        if (self.thread) |t| t.join();
    }

    pub fn deinit(self: *Server) void {
        self.stop();
    }

    fn listenLoop(self: *Server) void {
        const pipe_name = "\\\\.\\pipe\\hollow-htp";

        while (self.running) {
            const h_pipe = CreateNamedPipeA(
                pipe_name,
                PIPE_ACCESS_DUPLEX,
                PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT,
                PIPE_UNLIMITED_INSTANCES,
                4096,
                4096,
                0,
                null,
            );

            if (h_pipe == windows.INVALID_HANDLE_VALUE) {
                std.log.err("htp-pipe: CreateNamedPipe failed err={d}", .{windows.kernel32.GetLastError()});
                std.Thread.sleep(1 * std.time.ns_per_s);
                continue;
            }

            if (ConnectNamedPipe(h_pipe, null) == windows.FALSE) {
                const err = windows.kernel32.GetLastError();
                if (@intFromEnum(err) != 997) { // ERROR_IO_PENDING
                    std.log.err("htp-pipe: ConnectNamedPipe failed err={d}", .{@intFromEnum(err)});
                }
                windows.CloseHandle(h_pipe);
                continue;
            }

            self.handleClient(h_pipe);
            windows.CloseHandle(h_pipe);
        }
    }

    fn handleClient(self: *Server, h_pipe: windows.HANDLE) void {
        var buf: [4096]u8 = undefined;
        var read_count: windows.DWORD = 0;

        const ok = windows.kernel32.ReadFile(h_pipe, &buf, buf.len, &read_count, null);
        if (ok == windows.FALSE or read_count == 0) return;

        if (self.handlePayload(buf[0..read_count])) |response| {
            defer self.allocator.free(response);
            var written: windows.DWORD = 0;
            _ = windows.kernel32.WriteFile(h_pipe, response.ptr, @intCast(response.len), &written, null);
        }
    }

    fn handlePayload(self: *Server, payload: []const u8) ?[]const u8 {
        const handler = self.handler_fn orelse return null;
        return handler(self.app, payload, self.allocator);
    }
};

const TestHandlerContext = struct {
    last_payload: ?[]u8 = null,
    respond: bool,
};

fn testHandler(ctx_ptr: *anyopaque, payload: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    const ctx: *TestHandlerContext = @ptrCast(@alignCast(ctx_ptr));
    if (ctx.last_payload) |previous| allocator.free(previous);
    ctx.last_payload = allocator.dupe(u8, payload) catch @panic("oom");
    if (!ctx.respond) return null;
    return allocator.dupe(u8, "{\"ok\":true}") catch @panic("oom");
}

test "handlePayload returns null when no handler is configured" {
    var app_value: u8 = 0;
    var server = Server.init(std.testing.allocator, &app_value, null);

    try std.testing.expectEqual(@as(?[]const u8, null), server.handlePayload("ping"));
}

test "handlePayload forwards payload to handler and returns response" {
    var ctx = TestHandlerContext{ .respond = true };
    defer if (ctx.last_payload) |payload| std.testing.allocator.free(payload);
    var server = Server.init(std.testing.allocator, &ctx, testHandler);

    const response = server.handlePayload("{\"name\":\"ping\"}").?;
    defer std.testing.allocator.free(response);

    try std.testing.expectEqualStrings("{\"name\":\"ping\"}", ctx.last_payload.?);
    try std.testing.expectEqualStrings("{\"ok\":true}", response);
}

test "handlePayload preserves handler no-response behavior" {
    var ctx = TestHandlerContext{ .respond = false };
    defer if (ctx.last_payload) |payload| std.testing.allocator.free(payload);
    var server = Server.init(std.testing.allocator, &ctx, testHandler);

    try std.testing.expectEqual(@as(?[]const u8, null), server.handlePayload("noop"));
    try std.testing.expectEqualStrings("noop", ctx.last_payload.?);
}
