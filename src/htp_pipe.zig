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

        const payload = buf[0..read_count];
        if (self.handler_fn) |handler| {
            if (handler(self.app, payload, self.allocator)) |response| {
                var written: windows.DWORD = 0;
                _ = windows.kernel32.WriteFile(h_pipe, response.ptr, @intCast(response.len), &written, null);
                self.allocator.free(response);
            }
        }
    }
};
