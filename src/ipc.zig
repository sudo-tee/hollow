const std = @import("std");
const builtin = @import("builtin");
const command = @import("command.zig");
const platform = @import("platform.zig");

pub const EnvVar = "HOLLOW_COMMAND_ADDR";
pub const TimingEnvVar = "HOLLOW_COMMAND_TIMING";
const max_frame_size: u32 = 16 * 1024 * 1024;
const server_timeout_ms: u64 = 5_000;

const windows = if (builtin.os.tag == .windows) std.os.windows else void;

pub const Server = struct {
    allocator: std.mem.Allocator,
    app: *anyopaque,
    handler: *const fn (app: *anyopaque, request: command.Request) command.Response,
    thread: ?std.Thread = null,
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    active_mutex: std.Thread.Mutex = .{},
    active_stream: ?std.net.Stream = null,
    wake_stream: ?std.net.Stream = null,
    listen_address: ?std.net.Address = null,
    listen_address_text: ?[]u8 = null,
    started: bool = false,

    pub fn init(allocator: std.mem.Allocator, app: *anyopaque, handler: *const fn (app: *anyopaque, request: command.Request) command.Response) Server {
        return .{
            .allocator = allocator,
            .app = app,
            .handler = handler,
        };
    }

    pub fn deinit(self: *Server) void {
        self.stop();
        if (self.listen_address_text) |value| self.allocator.free(value);
    }

    pub fn start(self: *Server) !void {
        if (self.started) return;

        const configured_addr = std.process.getEnvVarOwned(self.allocator, EnvVar) catch null;
        defer if (configured_addr) |value| self.allocator.free(value);

        const bind_address = if (configured_addr) |value|
            try std.net.Address.parseIpAndPort(value)
        else
            std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);

        var listener = try bind_address.listen(.{ .reuse_address = true });
        errdefer listener.deinit();

        self.listen_address = listener.listen_address;
        self.listen_address_text = try std.fmt.allocPrint(self.allocator, "{f}", .{listener.listen_address});
        errdefer {
            self.allocator.free(self.listen_address_text.?);
            self.listen_address_text = null;
        }

        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{ self, listener });
        self.started = true;
    }

    pub fn stop(self: *Server) void {
        if (!self.started) return;

        self.stop_flag.store(true, .release);
        self.active_mutex.lock();
        if (self.active_stream) |stream| std.posix.shutdown(stream.handle, .both) catch {};
        self.active_mutex.unlock();
        self.wakeAcceptLoop();
        if (self.wake_stream) |stream| {
            stream.close();
            self.wake_stream = null;
        }
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.listen_address = null;
        self.started = false;
    }

    pub fn address(self: *const Server) ?[]const u8 {
        return self.listen_address_text;
    }

    fn wakeAcceptLoop(self: *Server) void {
        const listen_addr = self.listen_address orelse return;
        const stream = std.net.tcpConnectToAddress(listen_addr) catch return;
        if (self.wake_stream) |old| old.close();
        self.wake_stream = stream;
    }

    fn acceptLoop(self: *Server, listener: std.net.Server) void {
        var server = listener;
        defer server.deinit();

        while (!self.stop_flag.load(.acquire)) {
            var conn = server.accept() catch |err| {
                if (self.stop_flag.load(.acquire)) break;
                std.log.warn("command-ipc: accept failed: {s}", .{@errorName(err)});
                continue;
            };
            self.active_mutex.lock();
            if (self.stop_flag.load(.acquire)) {
                self.active_mutex.unlock();
                conn.stream.close();
                break;
            }
            self.active_stream = conn.stream;
            self.active_mutex.unlock();
            std.log.info("command-ipc: accepted connection from {f}", .{conn.address});
            handleConnection(self, &conn) catch |err| {
                std.log.warn("command-ipc: request failed: {s}", .{@errorName(err)});
            };
            self.active_mutex.lock();
            conn.stream.close();
            self.active_stream = null;
            self.active_mutex.unlock();
        }
    }

    fn handleConnection(self: *Server, conn: *std.net.Server.Connection) !void {
        try setTimeouts(conn.stream, server_timeout_ms);

        const frame = try readFrame(self.allocator, conn.stream);
        defer self.allocator.free(frame);
        var parsed = try command.parseEnvelope(self.allocator, frame);
        defer parsed.deinit(self.allocator);

        var response = self.handler(self.app, parsed.request);
        defer response.deinit(self.allocator);

        const reply = try command.writeResultJson(self.allocator, response);
        defer self.allocator.free(reply);
        try writeFrame(conn.stream, reply);
    }
};

pub fn send(allocator: std.mem.Allocator, request: command.Request, timeout_ms: u64) !command.Response {
    const timing_enabled = commandTimingEnabled();
    const total_start_ns = if (timing_enabled) std.time.nanoTimestamp() else 0;
    const addr_text = std.process.getEnvVarOwned(allocator, EnvVar) catch return error.CommandAddrUnavailable;
    defer allocator.free(addr_text);

    const connect_start_ns = if (timing_enabled) std.time.nanoTimestamp() else 0;
    const remote_addr = try std.net.Address.parseIpAndPort(addr_text);
    var stream = try std.net.tcpConnectToAddress(remote_addr);
    defer stream.close();
    if (timing_enabled) clientTraceFmt("connect_ms={d:.3}", .{elapsedMs(connect_start_ns)});

    try setTimeouts(stream, timeout_ms);

    const encode_start_ns = if (timing_enabled) std.time.nanoTimestamp() else 0;
    const payload = try encodeRequest(allocator, request);
    defer allocator.free(payload);
    if (timing_enabled) clientTraceFmt("encode_ms={d:.3} bytes={d}", .{ elapsedMs(encode_start_ns), payload.len });

    const write_start_ns = if (timing_enabled) std.time.nanoTimestamp() else 0;
    try writeFrame(stream, payload);
    if (timing_enabled) clientTraceFmt("write_ms={d:.3}", .{elapsedMs(write_start_ns)});

    const read_start_ns = if (timing_enabled) std.time.nanoTimestamp() else 0;
    const reply = readFrame(allocator, stream) catch |err| switch (err) {
        error.WouldBlock => return error.Timeout,
        else => return err,
    };
    defer allocator.free(reply);
    if (timing_enabled) {
        clientTraceFmt("read_ms={d:.3} bytes={d}", .{ elapsedMs(read_start_ns), reply.len });
        clientTraceFmt("total_ms={d:.3}", .{elapsedMs(total_start_ns)});
    }
    return try decodeResponse(allocator, reply);
}

fn commandTimingEnabled() bool {
    const value = std.process.getEnvVarOwned(std.heap.page_allocator, TimingEnvVar) catch return false;
    defer std.heap.page_allocator.free(value);
    return value.len > 0 and !std.mem.eql(u8, value, "0") and !std.mem.eql(u8, value, "false");
}

fn elapsedMs(start_ns: i128) f64 {
    return @as(f64, @floatFromInt(std.time.nanoTimestamp() - start_ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
}

fn clientTrace(message: []const u8) void {
    if (!commandTimingEnabled()) return;
    const runtime_dir = platform.ensureHollowRuntimeDir(std.heap.page_allocator) catch return;
    defer std.heap.page_allocator.free(runtime_dir);

    const log_path = std.fs.path.join(std.heap.page_allocator, &.{ runtime_dir, "command-ipc-client.log" }) catch return;
    defer std.heap.page_allocator.free(log_path);

    const file = std.fs.createFileAbsolute(log_path, .{ .truncate = false }) catch return;
    defer file.close();
    file.seekFromEnd(0) catch {};
    file.writeAll(message) catch {};
    file.writeAll("\n") catch {};
}

fn clientTraceFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt, args) catch return;
    clientTrace(line);
}

fn encodeRequest(allocator: std.mem.Allocator, request: command.Request) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    try std.json.Stringify.value(.{
        .kind = @tagName(request.kind),
        .pane_id = request.pane_id,
        .id = request.id,
        .index = request.index,
        .name = request.name,
        .cmd = request.cmd,
        .cwd = request.cwd,
        .domain = request.domain,
        .direction = request.direction,
        .amount = request.amount,
        .ratio = request.ratio,
        .x = request.x,
        .y = request.y,
        .width = request.width,
        .height = request.height,
        .text = request.text,
        .tag = request.tag,
        .tags = request.tags,
        .channel = request.channel,
        .params = request.params,
        .payload = request.payload,
    }, .{}, &writer.writer);
    return try allocator.dupe(u8, writer.written());
}

fn decodeResponse(allocator: std.mem.Allocator, text: []const u8) !command.Response {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidCommandEnvelope,
    };
    const kind = jsonObjectString(root, "kind") orelse return error.InvalidCommandEnvelope;
    const status = jsonObjectString(root, "status") orelse "ok";

    if (std.mem.eql(u8, kind, "error")) {
        return .{
            .success = false,
            .status = try allocator.dupe(u8, status),
            .error_message = try allocator.dupe(u8, jsonObjectString(root, "error") orelse "command failed"),
            .owns_status = true,
            .owns_error_message = true,
        };
    }
    if (!std.mem.eql(u8, kind, "result")) return error.InvalidCommandEnvelope;

    return .{
        .success = true,
        .status = try allocator.dupe(u8, status),
        .payload = try jsonObjectValueClone(allocator, root, "payload"),
        .owns_status = true,
    };
}

fn writeFrame(stream: std.net.Stream, payload: []const u8) !void {
    if (payload.len > max_frame_size) return error.FrameTooLarge;
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(payload.len), .little);
    try writeAllSocket(stream, &header);
    try writeAllSocket(stream, payload);
}

fn readFrame(allocator: std.mem.Allocator, stream: std.net.Stream) ![]u8 {
    var header: [4]u8 = undefined;
    const header_len = readExactSocket(stream, &header) catch |err| {
        std.log.warn("command-ipc: header read failed total=0: {s}", .{@errorName(err)});
        return err;
    };
    if (header_len == 0) return error.ConnectionClosed;
    if (header_len != header.len) {
        std.log.warn("command-ipc: short header total={d}", .{header_len});
        return error.InvalidCommandEnvelope;
    }

    const payload_len = std.mem.readInt(u32, &header, .little);
    if (payload_len > max_frame_size) return error.FrameTooLarge;
    const payload = try allocator.alloc(u8, payload_len);
    errdefer allocator.free(payload);
    const got = readExactSocket(stream, payload) catch |err| {
        std.log.warn("command-ipc: payload read failed total=0/{d}: {s}", .{ payload_len, @errorName(err) });
        return err;
    };
    if (got != payload_len) {
        std.log.warn("command-ipc: short payload total={d}/{d}", .{ got, payload_len });
        return error.InvalidCommandEnvelope;
    }
    return payload;
}

fn readExactSocket(stream: std.net.Stream, buffer: []u8) !usize {
    var total: usize = 0;
    while (total < buffer.len) {
        const amt = try readSocket(stream, buffer[total..]);
        if (amt == 0) break;
        total += amt;
    }
    return total;
}

fn writeAllSocket(stream: std.net.Stream, buffer: []const u8) !void {
    var total: usize = 0;
    while (total < buffer.len) {
        const amt = try writeSocket(stream, buffer[total..]);
        if (amt == 0) return error.ConnectionClosed;
        total += amt;
    }
}

fn readSocket(stream: std.net.Stream, buffer: []u8) !usize {
    if (builtin.os.tag == .windows) return std.posix.recv(stream.handle, buffer, 0);
    return stream.read(buffer);
}

fn writeSocket(stream: std.net.Stream, buffer: []const u8) !usize {
    if (builtin.os.tag == .windows) return std.posix.send(stream.handle, buffer, 0);
    return stream.write(buffer);
}

fn setTimeouts(stream: std.net.Stream, timeout_ms: u64) !void {
    if (timeout_ms == 0) return;

    if (builtin.os.tag == .windows) {
        const value: windows.DWORD = @intCast(@min(timeout_ms, std.math.maxInt(windows.DWORD)));
        try std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.os.windows.ws2_32.SO.RCVTIMEO, std.mem.asBytes(&value));
        try std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.os.windows.ws2_32.SO.SNDTIMEO, std.mem.asBytes(&value));
        return;
    }

    var value = std.posix.timeval{
        .sec = @intCast(timeout_ms / std.time.ms_per_s),
        .usec = @intCast((timeout_ms % std.time.ms_per_s) * std.time.us_per_ms),
    };
    try std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.c.SO.RCVTIMEO, std.mem.asBytes(&value));
    try std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.c.SO.SNDTIMEO, std.mem.asBytes(&value));
}

fn jsonObjectString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn jsonObjectValueClone(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) !?std.json.Value {
    const value = object.get(key) orelse return null;
    return try command.cloneJsonValue(allocator, value);
}
