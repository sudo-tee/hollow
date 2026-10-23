//! Bounded POSIX terminal transport. Queries restore terminal settings on every
//! exit path. Chunk framing and resource limits are shared with the host codec.
const std = @import("std");
const builtin = @import("builtin");
const command = @import("../command.zig");
const io = @import("../io.zig");
const codec = @import("../htp/codec.zig");
const transport = @import("transport.zig");
const c = if (builtin.os.tag == .windows) struct {} else @cImport({
    @cDefine("_GNU_SOURCE", "1");
    // translate-c cannot lower glibc's fortify error-attributed inline wrappers.
    // Buffer bounds are managed in Zig; import the underlying libc declarations.
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("termios.h");
    @cInclude("poll.h");
    @cInclude("errno.h");
});

pub fn send(a: std.mem.Allocator, request: command.Request, timeout_ms: u64) !command.Response {
    if (builtin.os.tag == .windows) return error.OscRequiresPosixTerminal;
    var id_buffer: [64]u8 = undefined;
    const id = transport.requestId(&id_buffer);
    const payload = try transport.bridgeEnvelope(a, request, id, null);
    defer a.free(payload);
    if (payload.len > codec.max_assembly_bytes) return error.FrameTooLarge;
    const fd = openTerminal() orelse return error.TerminalUnavailable;
    defer _ = c.close(fd);
    var previous: c.struct_termios = undefined;
    if (c.tcgetattr(fd, &previous) != 0) return error.TerminalUnavailable;
    var raw = previous;
    c.cfmakeraw(&raw);
    if (c.tcsetattr(fd, c.TCSANOW, &raw) != 0) return error.TerminalUnavailable;
    defer _ = c.tcsetattr(fd, c.TCSANOW, &previous);
    const deadline = io.nanoTimestamp() + @as(i128, timeout_ms) * std.time.ns_per_ms;
    const Sink = struct {
        fd: c_int,
        deadline: i128,
        failure: ?anyerror = null,
        fn write(context: *anyopaque, bytes: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.failure != null) return;
            writeAll(self.fd, bytes, self.deadline) catch |err| {
                self.failure = err;
            };
        }
    };
    var sink = Sink{ .fd = fd, .deadline = deadline };
    var framing = codec.Codec.init(a);
    defer framing.deinit();
    // Each short-lived client must use distinct assembly IDs on the same pane.
    framing.next_message_id = std.hash.Wyhash.hash(0, id);
    try framing.writeFramed(payload, &sink, Sink.write);
    if (sink.failure) |err| return err;
    var reader = ReplyReader.init(a, id);
    defer reader.deinit();
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(a);
    while (true) {
        try wait(fd, c.POLLIN, deadline);
        var buffer: [4096]u8 = undefined;
        const count = c.read(fd, &buffer, buffer.len);
        if (count == 0) return error.ConnectionClosed;
        if (count < 0) {
            if (std.posix.errno(count) == .AGAIN or std.posix.errno(count) == .INTR) continue;
            return error.TerminalReadFailed;
        }
        try pending.appendSlice(a, buffer[0..@intCast(count)]);
        while (true) {
            const start = std.mem.indexOf(u8, pending.items, codec.osc_prefix) orelse {
                // Preserve a possibly fragmented prefix, not unrelated input.
                const keep = @min(pending.items.len, codec.osc_prefix.len - 1);
                std.mem.copyForwards(u8, pending.items[0..keep], pending.items[pending.items.len - keep ..]);
                pending.shrinkRetainingCapacity(keep);
                break;
            };
            const content = start + codec.osc_prefix.len;
            const end = std.mem.indexOfPos(u8, pending.items, content, codec.string_terminator) orelse break;
            if (try reader.accept(pending.items[content..end])) |reply| return reply;
            const consumed = end + codec.string_terminator.len;
            const remaining = pending.items.len - consumed;
            std.mem.copyForwards(u8, pending.items[0..remaining], pending.items[consumed..]);
            pending.shrinkRetainingCapacity(remaining);
        }
        if (pending.items.len > codec.max_assembly_bytes) return error.FrameTooLarge;
    }
}

fn openTerminal() ?c_int {
    if (builtin.os.tag == .windows) return null;
    const flags = c.O_RDWR | c.O_NOCTTY | c.O_NONBLOCK | c.O_CLOEXEC;
    const fd = c.open("/dev/tty", flags);
    if (fd >= 0) return fd;
    const fallback = c.open("/dev/fd/2", flags);
    return if (fallback >= 0) fallback else null;
}

fn wait(fd: c_int, events: c_short, deadline: i128) !void {
    if (builtin.os.tag == .windows) return error.OscRequiresPosixTerminal;
    while (true) {
        const remaining = deadline - io.nanoTimestamp();
        if (remaining <= 0) return error.Timeout;
        var pollfd = c.struct_pollfd{ .fd = fd, .events = events, .revents = 0 };
        const milliseconds: c_int = @intCast(@min(std.math.maxInt(c_int), @divFloor(remaining + std.time.ns_per_ms - 1, std.time.ns_per_ms)));
        const result = c.poll(&pollfd, 1, milliseconds);
        if (result == 0) return error.Timeout;
        if (result < 0) {
            if (std.posix.errno(result) == .INTR) continue;
            return error.TerminalPollFailed;
        }
        if (pollfd.revents & events != 0) return;
        if (pollfd.revents & (c.POLLHUP | c.POLLERR | c.POLLNVAL) != 0) return error.ConnectionClosed;
    }
}

fn writeAll(fd: c_int, bytes: []const u8, deadline: i128) !void {
    if (builtin.os.tag == .windows) return error.OscRequiresPosixTerminal;
    var offset: usize = 0;
    while (offset < bytes.len) {
        try wait(fd, c.POLLOUT, deadline);
        const count = c.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (count <= 0) {
            if (count < 0 and (std.posix.errno(count) == .AGAIN or std.posix.errno(count) == .INTR)) continue;
            return error.TerminalWriteFailed;
        }
        offset += @intCast(count);
    }
}

const ReplyReader = struct {
    a: std.mem.Allocator,
    id: []const u8,
    chunks: codec.Codec,

    fn init(a: std.mem.Allocator, id: []const u8) ReplyReader {
        return .{ .a = a, .id = id, .chunks = codec.Codec.init(a) };
    }
    fn deinit(self: *ReplyReader) void {
        self.chunks.deinit();
    }

    fn accept(self: *ReplyReader, text: []const u8) !?command.Response {
        var parsed = std.json.parseFromSlice(std.json.Value, self.a, text, .{}) catch |err| {
            if (err == error.OutOfMemory) return err;
            return null;
        };
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const object = parsed.value.object;
        const kind = string(object, "kind") orelse return null;
        if (std.mem.eql(u8, kind, "chunk")) {
            const chunk_id = string(object, "request_id") orelse return null;
            const payload = object.get("payload") orelse return null;
            if (payload != .object) return null;
            const index = integer(payload.object, "index") orelse return null;
            const total = integer(payload.object, "total") orelse return null;
            const data = string(payload.object, "data") orelse return null;
            if (total == 0 or total > codec.max_chunks or index == 0 or index > total or data.len > codec.max_chunk_payload) return error.InvalidChunk;
            const assembly = try self.chunks.findOrCreateAssembly(0, chunk_id, total, io.nanoTimestamp());
            if (assembly.total != total or assembly.next_index != index) return error.InvalidChunk;
            if (assembly.buffer.items.len + data.len > codec.max_assembly_bytes) return error.FrameTooLarge;
            try assembly.buffer.appendSlice(self.a, data);
            assembly.next_index += 1;
            if (index != total) return null;
            // Do not recursively accept another chunk envelope from assembled data.
            const result = try self.acceptResult(assembly.buffer.items);
            self.chunks.removeAssembly(0, chunk_id);
            return result;
        }
        return self.acceptResult(text);
    }

    fn acceptResult(self: *ReplyReader, text: []const u8) !?command.Response {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.a, text, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const id = string(parsed.value.object, "request_id") orelse return null;
        if (!std.mem.eql(u8, id, self.id)) return null;
        return try transport.decodeBridgeReply(self.a, text);
    }
};

fn string(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}
fn integer(object: std.json.ObjectMap, name: []const u8) ?usize {
    const value = object.get(name) orelse return null;
    return if (value == .integer and value.integer >= 0) std.math.cast(usize, value.integer) else null;
}

test "OSC reader ignores unrelated replies and decodes chunked native results" {
    const a = std.testing.allocator;
    var reader = ReplyReader.init(a, "ours");
    defer reader.deinit();
    try std.testing.expect(try reader.accept("{\"kind\":\"result\",\"request_id\":\"other\",\"status\":\"ok\"}") == null);
    const text = "{\"kind\":\"result\",\"request_id\":\"ours\",\"status\":\"ok\",\"payload\":{\"kind\":\"result\",\"status\":\"ok\",\"payload\":42}}";
    const frame = try std.json.Stringify.valueAlloc(a, .{ .kind = "chunk", .request_id = "chunks", .payload = .{ .index = 1, .total = 1, .data = text } }, .{});
    defer a.free(frame);
    var result = (try reader.accept(frame)).?;
    defer result.deinit(a);
    try std.testing.expectEqual(@as(i64, 42), result.payload.?.integer);
    try std.testing.expectEqual(@as(usize, 0), reader.chunks.assemblies.items.len);
}
