//! Transport adapters share the native command wire contract. Never replay a
//! request after it may have reached a host, including after response timeouts.
const std = @import("std");
const command = @import("../command.zig");
const ipc = @import("../ipc.zig");
const io = @import("../io.zig");
const osc = @import("osc.zig");

pub const Mode = enum { auto, socket, file, osc };
pub const bridge_channel = "command_api";
pub const max_reply_bytes = 16 * 1024 * 1024;

pub fn send(a: std.mem.Allocator, request_value: command.Request, mode: Mode, timeout_ms: u64) !command.Response {
    var request = request_value;
    if (request.ctx.pane_id == 0) {
        const caller = io.getEnvVarOwned(a, "HOLLOW_PANE_ID") catch null;
        defer if (caller) |value| a.free(value);
        if (caller) |value| request.ctx.pane_id = std.fmt.parseInt(usize, value, 10) catch return error.InvalidCallerPane;
    }
    if (mode == .auto or mode == .socket) {
        const connected = ipc.connect(a);
        if (connected) |stream| {
            defer stream.close(io.get());
            return ipc.sendConnected(a, stream, request, timeout_ms);
        } else |err| {
            if (mode == .socket or err == error.OutOfMemory) return err;
        }
    }
    const root = if (mode != .osc) io.getEnvVarOwned(a, "HOLLOW_REQUEST_DIR") catch null else null;
    defer if (root) |value| a.free(value);
    if (root) |path| return sendFile(a, request, path, timeout_ms);
    if (mode == .file) return error.RequestDirectoryUnavailable;
    return osc.send(a, request, timeout_ms);
}

pub fn requestId(buffer: *[64]u8) []const u8 {
    var random: [16]u8 = undefined;
    std.Io.random(io.get(), &random);
    return std.fmt.bufPrint(buffer, "hollow-{s}", .{std.fmt.bytesToHex(random, .lower)}) catch unreachable;
}

/// HTP carries one native envelope, not a second command-specific translation.
pub fn bridgeEnvelope(a: std.mem.Allocator, request: command.Request, id: []const u8, reply_path: ?[]const u8) ![]u8 {
    const encoded = try command.encodeRequest(a, request);
    defer a.free(encoded);
    var params = try std.json.parseFromSlice(std.json.Value, a, encoded, .{});
    defer params.deinit();
    return std.json.Stringify.valueAlloc(a, .{
        .kind = "query",
        .id = id,
        .request_id = id,
        .name = bridge_channel,
        .pane_id = request.ctx.pane_id,
        .reply_file = reply_path,
        .params = params.value,
    }, .{ .emit_null_optional_fields = false });
}

pub fn decodeBridgeReply(a: std.mem.Allocator, text: []const u8) !command.Response {
    var outer = try ipc.decodeResponse(a, text);
    if (!outer.success) return outer;
    defer outer.deinit(a);
    const payload = outer.payload orelse return error.InvalidCommandEnvelope;
    const nested = try std.json.Stringify.valueAlloc(a, payload, .{});
    defer a.free(nested);
    return ipc.decodeResponse(a, nested);
}

fn sendFile(a: std.mem.Allocator, request: command.Request, root: []const u8, timeout_ms: u64) !command.Response {
    var id_buffer: [64]u8 = undefined;
    const id = requestId(&id_buffer);
    const request_path = try std.fmt.allocPrint(a, "{s}/{s}.request.json", .{ root, id });
    defer a.free(request_path);
    const temporary_path = try std.fmt.allocPrint(a, "{s}.tmp", .{request_path});
    defer a.free(temporary_path);
    const reply_path = try std.fmt.allocPrint(a, "{s}/{s}.reply.json", .{ root, id });
    defer a.free(reply_path);
    const cwd = std.Io.Dir.cwd();
    defer cwd.deleteFile(io.get(), temporary_path) catch {};
    defer cwd.deleteFile(io.get(), request_path) catch {};
    defer cwd.deleteFile(io.get(), reply_path) catch {};
    const payload = try bridgeEnvelope(a, request, id, reply_path);
    defer a.free(payload);
    if (payload.len > max_reply_bytes) return error.FrameTooLarge;
    {
        const file = try cwd.createFile(io.get(), temporary_path, .{
            .exclusive = true,
            .permissions = if (@import("builtin").os.tag == .windows) .default_file else .fromMode(0o600),
        });
        defer file.close(io.get());
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(io.get(), &buffer);
        try writer.interface.writeAll(payload);
        try writer.interface.flush();
    }
    try cwd.rename(temporary_path, cwd, request_path, io.get());
    const deadline = io.nanoTimestamp() + @as(i128, timeout_ms) * std.time.ns_per_ms;
    while (io.nanoTimestamp() < deadline) {
        const reply = cwd.readFileAlloc(io.get(), reply_path, a, .limited(max_reply_bytes)) catch |err| switch (err) {
            error.FileNotFound => {
                try std.Io.sleep(io.get(), .fromMilliseconds(10), .awake);
                continue;
            },
            else => return err,
        };
        defer a.free(reply);
        return decodeBridgeReply(a, reply);
    }
    return error.Timeout;
}

test "bridge preserves typed command and context without translating arguments" {
    const a = std.testing.allocator;
    const text = try bridgeEnvelope(a, .{ .ctx = .{ .pane_id = 7, .origin = .cli }, .data = .{ .pane_split = .{ .direction = "vertical", .ratio = 0.3 } } }, "request", null);
    defer a.free(text);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, text, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings(bridge_channel, root.get("name").?.string);
    const params = try std.json.Stringify.valueAlloc(a, root.get("params").?, .{});
    defer a.free(params);
    var request = try command.parseEnvelope(a, params);
    defer request.deinit(a);
    try std.testing.expectEqual(@as(usize, 7), request.request.ctx.pane_id);
    try std.testing.expectEqual(@as(?f64, 0.3), request.request.data.pane_split.ratio);
}

test "bridge reply preserves native errors and payloads" {
    const a = std.testing.allocator;
    var result = try decodeBridgeReply(a, "{\"kind\":\"result\",\"status\":\"ok\",\"payload\":{\"kind\":\"result\",\"status\":\"ok\",\"payload\":{\"revision\":3}}}");
    defer result.deinit(a);
    try std.testing.expectEqual(@as(i64, 3), result.payload.?.object.get("revision").?.integer);
    var failure = try decodeBridgeReply(a, "{\"kind\":\"result\",\"status\":\"ok\",\"payload\":{\"kind\":\"error\",\"status\":\"invalid_args\",\"error\":\"bad args\"}}");
    defer failure.deinit(a);
    try std.testing.expect(!failure.success);
    try std.testing.expectEqualStrings("invalid_args", failure.status);
}
