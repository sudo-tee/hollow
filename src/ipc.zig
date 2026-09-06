const std = @import("std");
const builtin = @import("builtin");
const command = @import("command.zig");
const platform = @import("platform.zig");
const io = @import("io.zig");

pub const EnvVar = "HOLLOW_COMMAND_ADDR";
pub const TimingEnvVar = "HOLLOW_COMMAND_TIMING";
const max_frame_size: u32 = 16 * 1024 * 1024;
const server_timeout_ms: u64 = 5_000;

const windows = if (builtin.os.tag == .windows) std.os.windows else void;

extern "kernel32" fn MoveFileExW(lpExistingFileName: [*:0]const u16, lpNewFileName: [*:0]const u16, dwFlags: windows.DWORD) callconv(.winapi) windows.BOOL;

pub const Server = struct {
    const Connection = struct {
        stream: ?std.Io.net.Stream = null,
        thread: ?std.Thread = null,
    };

    allocator: std.mem.Allocator,
    app: *anyopaque,
    handler: *const fn (app: *anyopaque, request: command.Request) command.Response,
    thread: ?std.Thread = null,
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    active_mutex: io.Mutex = .{},
    connections: [8]Connection = [_]Connection{.{}} ** 8,
    wake_stream: ?std.Io.net.Stream = null,
    listen_address: ?std.Io.net.IpAddress = null,
    listen_address_text: ?[]u8 = null,
    address_file_path: ?[]u8 = null,
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
        if (self.address_file_path) |value| self.allocator.free(value);
        if (self.listen_address_text) |value| self.allocator.free(value);
    }

    pub fn start(self: *Server) !void {
        if (self.started) return;
        self.stop_flag.store(false, .release);

        const configured_addr = io.getEnvVarOwned(self.allocator, EnvVar) catch null;
        defer if (configured_addr) |value| self.allocator.free(value);

        const bind_address = if (configured_addr) |value|
            try std.Io.net.IpAddress.parseLiteral(value)
        else
            std.Io.net.IpAddress{ .ip4 = .loopback(0) };

        if (!isLoopback(bind_address)) return error.NonLoopbackCommandAddress;

        var listener = try bind_address.listen(io.get(), .{ .reuse_address = true });
        errdefer listener.deinit(io.get());

        self.listen_address = listener.socket.address;
        self.listen_address_text = try std.fmt.allocPrint(self.allocator, "{f}", .{listener.socket.address});
        errdefer {
            self.allocator.free(self.listen_address_text.?);
            self.listen_address_text = null;
        }

        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{ self, listener });
        self.started = true;
        self.publishAddress() catch |err| {
            std.log.warn("command-ipc: failed to publish address: {s}", .{@errorName(err)});
        };
    }

    pub fn stop(self: *Server) void {
        if (!self.started) return;

        self.stop_flag.store(true, .release);
        self.active_mutex.lock();
        for (&self.connections) |*connection| {
            if (connection.stream) |stream| stream.shutdown(io.get(), .both) catch {};
        }
        self.active_mutex.unlock();
        self.wakeAcceptLoop();
        if (self.wake_stream) |stream| {
            stream.close(io.get());
            self.wake_stream = null;
        }
        if (self.thread) |thread| thread.join();
        for (&self.connections) |*connection| {
            if (connection.thread) |thread| thread.join();
            connection.thread = null;
        }
        self.unpublishAddress();
        self.thread = null;
        self.listen_address = null;
        self.started = false;
    }

    pub fn address(self: *const Server) ?[]const u8 {
        return self.listen_address_text;
    }

    fn publishAddress(self: *Server) !void {
        const address_text = self.listen_address_text orelse return;
        if (self.address_file_path) |old_path| {
            self.allocator.free(old_path);
            self.address_file_path = null;
        }
        const path = try addressFilePath(self.allocator);
        errdefer self.allocator.free(path);
        const temp_path = try std.fmt.allocPrint(self.allocator, "{s}.{d}.tmp", .{ path, io.nanoTimestamp() });
        defer self.allocator.free(temp_path);
        errdefer std.Io.Dir.deleteFileAbsolute(io.get(), temp_path) catch {};

        {
            const file = try std.Io.Dir.createFileAbsolute(io.get(), temp_path, .{});
            defer file.close(io.get());
            var buffer: [512]u8 = undefined;
            var writer = file.writer(io.get(), &buffer);
            try writer.interface.writeAll(address_text);
            try writer.interface.writeByte('\n');
            try writer.interface.flush();
            try file.sync(io.get());
        }
        try replaceFileAtomic(self.allocator, temp_path, path);
        self.address_file_path = path;
    }

    fn unpublishAddress(self: *Server) void {
        const path = self.address_file_path orelse return;
        const address_text = self.listen_address_text orelse return;
        const current = readAddressFileAtPath(self.allocator, path) catch return;
        defer self.allocator.free(current);
        if (!std.mem.eql(u8, current, address_text)) return;
        std.Io.Dir.deleteFileAbsolute(io.get(), path) catch {};
    }

    fn wakeAcceptLoop(self: *Server) void {
        const listen_addr = self.listen_address orelse return;
        const stream = listen_addr.connect(io.get(), .{ .mode = .stream, .protocol = .tcp }) catch return;
        if (self.wake_stream) |old| old.close(io.get());
        self.wake_stream = stream;
    }

    fn acceptLoop(self: *Server, listener: std.Io.net.Server) void {
        var server = listener;
        defer server.deinit(io.get());

        while (!self.stop_flag.load(.acquire)) {
            const stream = server.accept(io.get()) catch |err| {
                if (self.stop_flag.load(.acquire)) break;
                std.log.warn("command-ipc: accept failed: {s}", .{@errorName(err)});
                continue;
            };
            self.active_mutex.lock();
            if (self.stop_flag.load(.acquire)) {
                self.active_mutex.unlock();
                stream.close(io.get());
                break;
            }
            var available: ?usize = null;
            for (&self.connections, 0..) |*connection, index| {
                if (connection.stream == null) {
                    available = index;
                    break;
                }
            }
            if (available) |index| {
                const connection = &self.connections[index];
                // A cleared stream means the worker has released the mutex and
                // will not touch its slot again. Reap before reusing the slot.
                const previous = connection.thread;
                connection.stream = stream;
                self.active_mutex.unlock();
                if (previous) |thread| thread.join();
                connection.thread = std.Thread.spawn(.{}, connectionLoop, .{ self, index, stream }) catch {
                    self.active_mutex.lock();
                    stream.close(io.get());
                    connection.stream = null;
                    connection.thread = null;
                    self.active_mutex.unlock();
                    continue;
                };
            } else {
                self.active_mutex.unlock();
                stream.close(io.get());
            }
        }
    }

    fn connectionLoop(self: *Server, index: usize, stream: std.Io.net.Stream) void {
        handleConnection(self, stream) catch |err| {
            std.log.warn("command-ipc: request failed: {s}", .{@errorName(err)});
        };
        self.active_mutex.lock();
        stream.close(io.get());
        self.connections[index].stream = null;
        self.active_mutex.unlock();
    }

    fn handleConnection(self: *Server, stream: std.Io.net.Stream) !void {
        var deadline = SocketDeadline{ .stream = stream, .timeout_ms = server_timeout_ms };
        try deadline.start();
        defer deadline.finish();

        const frame = try readFrame(self.allocator, stream);
        defer self.allocator.free(frame);
        var parsed = try command.parseEnvelope(self.allocator, frame);
        defer parsed.deinit(self.allocator);

        var response = self.handler(self.app, parsed.request);
        defer response.deinit(self.allocator);

        const reply = try command.writeResultJson(self.allocator, response);
        defer self.allocator.free(reply);
        try writeFrame(stream, reply);
    }
};

fn addressFilePath(allocator: std.mem.Allocator) ![]u8 {
    const runtime_dir = try platform.ensureHollowRuntimeDir(allocator);
    defer allocator.free(runtime_dir);
    return std.fs.path.join(allocator, &.{ runtime_dir, "command-ipc-address" });
}

fn replaceFileAtomic(allocator: std.mem.Allocator, source: []const u8, destination: []const u8) !void {
    if (builtin.os.tag == .windows) {
        const source_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, source);
        defer allocator.free(source_w);
        const destination_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, destination);
        defer allocator.free(destination_w);
        const MOVEFILE_REPLACE_EXISTING: windows.DWORD = 0x1;
        const MOVEFILE_WRITE_THROUGH: windows.DWORD = 0x8;
        if (MoveFileExW(source_w.ptr, destination_w.ptr, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) == .FALSE) {
            return error.AtomicReplaceFailed;
        }
        return;
    }
    try std.Io.Dir.renameAbsolute(source, destination, io.get());
}

fn readAddressFileAtPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.openFileAbsolute(io.get(), path, .{});
    defer file.close(io.get());
    var read_buffer: [1024]u8 = undefined;
    var reader = file.reader(io.get(), &read_buffer);
    const contents = try reader.interface.allocRemaining(allocator, .limited(1024));
    defer allocator.free(contents);
    const address = std.mem.trim(u8, contents, " \t\r\n");
    if (address.len == 0) return error.CommandAddrUnavailable;
    return allocator.dupe(u8, address);
}

fn resolveAddress(allocator: std.mem.Allocator) ![]u8 {
    return io.getEnvVarOwned(allocator, EnvVar) catch {
        const path = addressFilePath(allocator) catch return error.CommandAddrUnavailable;
        defer allocator.free(path);
        return readAddressFileAtPath(allocator, path) catch return error.CommandAddrUnavailable;
    };
}

pub fn send(allocator: std.mem.Allocator, request: command.Request, timeout_ms: u64) !command.Response {
    const timing_enabled = commandTimingEnabled();
    const total_start_ns = if (timing_enabled) io.nanoTimestamp() else 0;
    const addr_text = try resolveAddress(allocator);
    defer allocator.free(addr_text);

    const connect_start_ns = if (timing_enabled) io.nanoTimestamp() else 0;
    const remote_addr = try std.Io.net.IpAddress.parseLiteral(addr_text);
    const stream = try remote_addr.connect(io.get(), .{
        .mode = .stream,
        .protocol = .tcp,
        .timeout = if (timeout_ms == 0) .none else .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(@intCast(@min(timeout_ms, std.math.maxInt(i64)))) } },
    });
    defer stream.close(io.get());
    if (timing_enabled) clientTraceFmt("connect_ms={d:.3}", .{elapsedMs(connect_start_ns)});

    var deadline = SocketDeadline{ .stream = stream, .timeout_ms = timeout_ms };
    try deadline.start();
    defer deadline.finish();

    const encode_start_ns = if (timing_enabled) io.nanoTimestamp() else 0;
    const payload = try encodeRequest(allocator, request);
    defer allocator.free(payload);
    if (timing_enabled) clientTraceFmt("encode_ms={d:.3} bytes={d}", .{ elapsedMs(encode_start_ns), payload.len });

    const write_start_ns = if (timing_enabled) io.nanoTimestamp() else 0;
    try writeFrame(stream, payload);
    if (timing_enabled) clientTraceFmt("write_ms={d:.3}", .{elapsedMs(write_start_ns)});

    const read_start_ns = if (timing_enabled) io.nanoTimestamp() else 0;
    const reply = try readFrame(allocator, stream);
    defer allocator.free(reply);
    if (timing_enabled) {
        clientTraceFmt("read_ms={d:.3} bytes={d}", .{ elapsedMs(read_start_ns), reply.len });
        clientTraceFmt("total_ms={d:.3}", .{elapsedMs(total_start_ns)});
    }
    return try decodeResponse(allocator, reply);
}

fn commandTimingEnabled() bool {
    const value = io.getEnvVarOwned(std.heap.page_allocator, TimingEnvVar) catch return false;
    defer std.heap.page_allocator.free(value);
    return value.len > 0 and !std.mem.eql(u8, value, "0") and !std.mem.eql(u8, value, "false");
}

fn elapsedMs(start_ns: i128) f64 {
    return @as(f64, @floatFromInt(io.nanoTimestamp() - start_ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
}

fn clientTrace(message: []const u8) void {
    if (!commandTimingEnabled()) return;
    const runtime_dir = platform.ensureHollowRuntimeDir(std.heap.page_allocator) catch return;
    defer std.heap.page_allocator.free(runtime_dir);

    const log_path = std.fs.path.join(std.heap.page_allocator, &.{ runtime_dir, "command-ipc-client.log" }) catch return;
    defer std.heap.page_allocator.free(log_path);

    const file = std.Io.Dir.createFileAbsolute(io.get(), log_path, .{ .truncate = false }) catch return;
    defer file.close(io.get());
    var buffer: [512]u8 = undefined;
    var writer = file.writer(io.get(), &buffer);
    const stat = file.stat(io.get()) catch return;
    writer.seekTo(stat.size) catch return;
    writer.interface.writeAll(message) catch {};
    writer.interface.writeByte('\n') catch {};
    writer.interface.flush() catch {};
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
        .surface = request.surface,
        .node_id = request.node_id,
        .generation = request.generation,
        .revision = request.revision,
        .timeout_ms = request.timeout_ms,
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

fn writeFrame(stream: std.Io.net.Stream, payload: []const u8) !void {
    if (payload.len > max_frame_size) return error.FrameTooLarge;
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(payload.len), .little);
    try writeAllSocket(stream, &header);
    try writeAllSocket(stream, payload);
}

fn readFrame(allocator: std.mem.Allocator, stream: std.Io.net.Stream) ![]u8 {
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

fn readExactSocket(stream: std.Io.net.Stream, buffer: []u8) !usize {
    var total: usize = 0;
    while (total < buffer.len) {
        const amt = try readSocket(stream, buffer[total..]);
        if (amt == 0) break;
        total += amt;
    }
    return total;
}

fn writeAllSocket(stream: std.Io.net.Stream, buffer: []const u8) !void {
    var scratch: [0]u8 = .{};
    var writer = stream.writer(io.get(), &scratch);
    writer.interface.writeAll(buffer) catch return writer.err orelse error.ConnectionClosed;
    writer.interface.flush() catch return writer.err orelse error.ConnectionClosed;
}

fn readSocket(stream: std.Io.net.Stream, buffer: []u8) !usize {
    var scratch: [0]u8 = .{};
    var reader = stream.reader(io.get(), &scratch);
    return reader.interface.readSliceShort(buffer) catch return reader.err orelse error.ConnectionClosed;
}

/// A total operation deadline, including slow trickle reads. AFD handles on
/// Windows do not support Winsock timeouts, but stream shutdown wakes readers.
const SocketDeadline = struct {
    stream: std.Io.net.Stream,
    timeout_ms: u64,
    mutex: std.Io.Mutex = .init,
    done_condition: std.Io.Condition = .init,
    done: bool = false,
    thread: ?std.Thread = null,

    fn start(self: *SocketDeadline) !void {
        if (self.timeout_ms != 0) self.thread = try std.Thread.spawn(.{}, watch, .{self});
    }

    fn finish(self: *SocketDeadline) void {
        self.mutex.lockUncancelable(io.get());
        self.done = true;
        self.done_condition.signal(io.get());
        self.mutex.unlock(io.get());
        if (self.thread) |thread| thread.join();
    }

    fn watch(self: *SocketDeadline) void {
        self.mutex.lockUncancelable(io.get());
        defer self.mutex.unlock(io.get());
        if (self.done) return;
        io.waitTimeout(&self.done_condition, &self.mutex, self.timeout_ms *| std.time.ns_per_ms) catch {
            if (!self.done) self.stream.shutdown(io.get(), .both) catch {};
        };
    }
};

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

test "encoded request round trips absent automation fields" {
    const payload = try encodeRequest(std.testing.allocator, .{ .kind = .get_revision });
    defer std.testing.allocator.free(payload);
    var parsed = try command.parseEnvelope(std.testing.allocator, payload);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(command.Kind.get_revision, parsed.request.kind);
    try std.testing.expect(parsed.request.revision == null);
    try std.testing.expect(parsed.request.generation == null);
}

fn isLoopback(address: std.Io.net.IpAddress) bool {
    return switch (address) {
        .ip4 => |value| value.bytes[0] == 127,
        .ip6 => |value| value.isLoopBack(),
    };
}

test "command transport accepts only loopback bindings" {
    try std.testing.expect(isLoopback(try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0")));
    try std.testing.expect(isLoopback(try std.Io.net.IpAddress.parseLiteral("[::1]:0")));
    try std.testing.expect(!isLoopback(try std.Io.net.IpAddress.parseLiteral("0.0.0.0:0")));
    try std.testing.expect(!isLoopback(try std.Io.net.IpAddress.parseLiteral("192.168.1.2:0")));
}

fn testHandler(_: *anyopaque, _: command.Request) command.Response {
    return .{};
}

test "idle IPC client does not block another request" {
    var context: u8 = 0;
    var server = Server.init(std.testing.allocator, &context, testHandler);
    // Do not publish a test address over a running user's discovery file.
    const listener = try (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io.get(), .{});
    server.listen_address = listener.socket.address;
    server.thread = try std.Thread.spawn(.{}, Server.acceptLoop, .{ &server, listener });
    server.started = true;
    defer server.deinit();
    const idle = try server.listen_address.?.connect(io.get(), .{ .mode = .stream });
    defer idle.close(io.get());
    const active = try server.listen_address.?.connect(io.get(), .{ .mode = .stream });
    defer active.close(io.get());
    var deadline = SocketDeadline{ .stream = active, .timeout_ms = 1000 };
    try deadline.start();
    defer deadline.finish();
    try writeFrame(active, "{\"kind\":\"get_revision\"}");
    const reply = try readFrame(std.testing.allocator, active);
    defer std.testing.allocator.free(reply);
    var result = try decodeResponse(std.testing.allocator, reply);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.success);
}

test "socket deadline interrupts an incomplete frame" {
    var listener = try (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io.get(), .{});
    defer listener.deinit(io.get());
    const client = try listener.socket.address.connect(io.get(), .{ .mode = .stream });
    defer client.close(io.get());
    const accepted = try listener.accept(io.get());
    defer accepted.close(io.get());
    var deadline = SocketDeadline{ .stream = accepted, .timeout_ms = 20 };
    try deadline.start();
    defer deadline.finish();
    // A partial header must not keep the worker alive indefinitely.
    try writeAllSocket(client, &.{1});
    if (readFrame(std.testing.allocator, accepted)) |frame| {
        std.testing.allocator.free(frame);
        return error.ExpectedDeadline;
    } else |_| {}
}
