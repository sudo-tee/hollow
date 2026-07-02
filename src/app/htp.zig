const std = @import("std");
const Pane = @import("../pane.zig").Pane;
const ghostty = @import("../term/ghostty.zig");
const lua_mod = @import("../lua_bridge.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const HtpQueryResult = lua_mod.HtpQueryResult;

pub const HTP_OSC_PREFIX = "\x1b]1337;Hollow;";
pub const HTP_ST = "\x1b\\";
pub const HTP_MAX_CHUNK_PAYLOAD = 3072;

pub const HtpQueuedMessage = struct {
    pane_id: usize,
    payload: []u8,
};

pub const HtpChunkAssembly = struct {
    pane_id: usize,
    request_id: []u8,
    total: usize,
    next_index: usize,
    buffer: std.ArrayListUnmanaged(u8) = .empty,
};

pub const HtpEnvelope = struct {
    v: u8 = 1,
    id: u64,
    kind: []const u8,
    channel: ?[]const u8 = null,
    request_id: ?std.json.Value = null,
    status: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
    payload: ?std.json.Value = null,
    params: ?std.json.Value = null,
};

pub var htp_bridge: ?*App = null;

pub fn htpMessageCallback(pane: *Pane, payload: []const u8) void {
    const app = htp_bridge orelse return;
    std.log.info("htp: received payload pane={x} bytes={d}", .{ @intFromPtr(pane), payload.len });
    queueHtpMessage(app, pane, payload);
}

pub fn queueHtpMessage(self: *App, pane: *Pane, payload: []const u8) void {
    const owned = self.allocator.dupe(u8, payload) catch return;
    std.log.info("htp: queue pane={x} bytes={d}", .{ @intFromPtr(pane), payload.len });
    self.htp_pending_messages.append(self.allocator, .{
        .pane_id = @intFromPtr(pane),
        .payload = owned,
    }) catch {
        self.allocator.free(owned);
        return;
    };
    self.signalWake();
}

pub fn bindHtpHandlers(self: *App) void {
    std.log.info("htp: bind handlers mux_present={} panes_pending={}", .{ self.mux != null, if (self.mux) |_| true else false });
    if (self.mux) |*mux| {
        var panes = mux.paneIterator();
        while (panes.next()) |pane| {
            std.log.info("htp: binding pane={x}", .{@intFromPtr(pane)});
            pane.setHtpMessageHandler(htpMessageCallback);
        }
    }
}

pub fn processHtpMessages(self: *App) void {
    while (self.htp_pending_messages.items.len > 0) {
        const message = self.htp_pending_messages.orderedRemove(0);
        defer self.allocator.free(message.payload);
        const pane = self.findPaneById(message.pane_id) orelse {
            removeChunkAssembliesForPane(self, message.pane_id);
            continue;
        };
        handleHtpMessage(self, pane, message.payload);
    }
}

fn handleHtpMessage(self: *App, pane: *Pane, payload: []const u8) void {
    std.log.info("htp: handle pane={x} payload={s}", .{ @intFromPtr(pane), payload });
    var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{ .ignore_unknown_fields = true }) catch |err| {
        sendHtpProtocolError(self, pane, null, "invalid_json", @errorName(err));
        return;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => {
            sendHtpProtocolError(self, pane, null, "invalid_message", "root JSON value must be an object");
            return;
        },
    };

    const kind = app_mod.jsonObjectString(root, "kind") orelse app_mod.jsonObjectString(root, "type") orelse {
        sendHtpProtocolError(self, pane, null, "invalid_message", "missing kind");
        return;
    };
    const message_id = app_mod.jsonObjectString(root, "id");

    if (std.mem.eql(u8, kind, "chunk")) {
        handleHtpChunk(self, pane, message_id, root);
        return;
    }

    if (std.mem.eql(u8, kind, "event")) {
        const channel = app_mod.jsonObjectString(root, "name") orelse app_mod.jsonObjectString(root, "channel") orelse {
            sendHtpProtocolError(self, pane, message_id, "invalid_message", "event message missing name");
            return;
        };
        const payload_value = app_mod.jsonObjectValueClone(self.allocator, root, "payload") catch |err| {
            sendHtpProtocolError(self, pane, message_id, "internal", @errorName(err));
            return;
        };
        defer if (payload_value) |value| app_mod.deinitJsonValue(self.allocator, value);
        dispatchHtpEvent(self, pane, message_id, channel, payload_value);
        return;
    }

    if (std.mem.eql(u8, kind, "query")) {
        const channel = app_mod.jsonObjectString(root, "name") orelse app_mod.jsonObjectString(root, "channel") orelse {
            sendHtpProtocolError(self, pane, message_id, "invalid_message", "query message missing name");
            return;
        };
        const request_id = app_mod.jsonObjectString(root, "request_id") orelse message_id;
        const params_value = app_mod.jsonObjectValueClone(self.allocator, root, "params") catch |err| {
            sendHtpQueryError(self, pane, message_id, request_id, "internal", @errorName(err));
            return;
        };
        defer if (params_value) |value| app_mod.deinitJsonValue(self.allocator, value);
        dispatchHtpQuery(self, pane, message_id, request_id, channel, params_value);
        return;
    }

    sendHtpProtocolError(self, pane, message_id, "invalid_message", "unknown kind");
}

fn handleHtpChunk(self: *App, pane: *Pane, message_id: ?[]const u8, root: std.json.ObjectMap) void {
    const request_id = app_mod.jsonObjectString(root, "request_id") orelse {
        sendHtpProtocolError(self, pane, message_id, "invalid_message", "chunk missing request_id");
        return;
    };
    const payload_value = app_mod.jsonObjectValue(root, "payload") orelse {
        sendHtpProtocolError(self, pane, message_id, "invalid_message", "chunk missing payload");
        return;
    };
    const payload_object = switch (payload_value) {
        .object => |obj| obj,
        else => {
            sendHtpProtocolError(self, pane, message_id, "invalid_message", "chunk payload must be an object");
            return;
        },
    };
    const index = app_mod.jsonObjectIndex(payload_object, "index") orelse {
        sendHtpProtocolError(self, pane, message_id, "invalid_message", "chunk missing index");
        return;
    };
    const total = app_mod.jsonObjectIndex(payload_object, "total") orelse {
        sendHtpProtocolError(self, pane, message_id, "invalid_message", "chunk missing total");
        return;
    };
    const data = app_mod.jsonObjectString(payload_object, "data") orelse {
        sendHtpProtocolError(self, pane, message_id, "invalid_message", "chunk missing data");
        return;
    };
    if (index == 0 or total == 0 or index > total) {
        sendHtpProtocolError(self, pane, message_id, "invalid_message", "chunk index out of range");
        return;
    }

    var assembly = findOrCreateChunkAssembly(self, pane, request_id, total) catch |err| {
        sendHtpProtocolError(self, pane, message_id, "internal", @errorName(err));
        return;
    };
    if (assembly.total != total or assembly.next_index != index) {
        resetChunkAssembly(assembly);
        sendHtpProtocolError(self, pane, message_id, "invalid_message", "unexpected chunk order");
        return;
    }
    assembly.buffer.appendSlice(self.allocator, data) catch |err| {
        resetChunkAssembly(assembly);
        sendHtpProtocolError(self, pane, message_id, "internal", @errorName(err));
        return;
    };
    assembly.next_index += 1;
    if (index < total) return;

    const joined = self.allocator.dupe(u8, assembly.buffer.items) catch |err| {
        resetChunkAssembly(assembly);
        sendHtpProtocolError(self, pane, message_id, "internal", @errorName(err));
        return;
    };
    defer self.allocator.free(joined);
    removeChunkAssembly(self, pane, request_id);
    handleHtpMessage(self, pane, joined);
}

fn findOrCreateChunkAssembly(self: *App, pane: *Pane, request_id: []const u8, total: usize) !*HtpChunkAssembly {
    for (self.htp_chunk_assemblies.items) |*assembly| {
        if (assembly.pane_id == @intFromPtr(pane) and std.mem.eql(u8, assembly.request_id, request_id)) return assembly;
    }
    const request_id_owned = try self.allocator.dupe(u8, request_id);
    errdefer self.allocator.free(request_id_owned);
    try self.htp_chunk_assemblies.append(self.allocator, .{
        .pane_id = @intFromPtr(pane),
        .request_id = request_id_owned,
        .total = total,
        .next_index = 1,
    });
    return &self.htp_chunk_assemblies.items[self.htp_chunk_assemblies.items.len - 1];
}

fn resetChunkAssembly(assembly: *HtpChunkAssembly) void {
    assembly.buffer.clearRetainingCapacity();
    assembly.next_index = 1;
}

fn removeChunkAssembly(self: *App, pane: *Pane, request_id: []const u8) void {
    var index: usize = 0;
    while (index < self.htp_chunk_assemblies.items.len) : (index += 1) {
        const assembly = &self.htp_chunk_assemblies.items[index];
        if (assembly.pane_id != @intFromPtr(pane) or !std.mem.eql(u8, assembly.request_id, request_id)) continue;
        self.allocator.free(assembly.request_id);
        assembly.buffer.deinit(self.allocator);
        _ = self.htp_chunk_assemblies.swapRemove(index);
        return;
    }
}

fn removeChunkAssembliesForPane(self: *App, pane_id: usize) void {
    var index: usize = 0;
    while (index < self.htp_chunk_assemblies.items.len) {
        const assembly = &self.htp_chunk_assemblies.items[index];
        if (assembly.pane_id != pane_id) {
            index += 1;
            continue;
        }
        self.allocator.free(assembly.request_id);
        assembly.buffer.deinit(self.allocator);
        _ = self.htp_chunk_assemblies.swapRemove(index);
    }
}

fn dispatchHtpEvent(self: *App, pane: *Pane, message_id: ?[]const u8, channel: []const u8, payload: ?std.json.Value) void {
    std.log.info("htp: dispatch event pane={x} channel={s}", .{ @intFromPtr(pane), channel });
    const lua = if (self.lua) |*value| value else {
        sendHtpProtocolError(self, pane, message_id, "unavailable", "lua runtime unavailable");
        return;
    };

    const ok = lua.dispatchHtpEvent(@intFromPtr(pane), channel, payload) catch |err| {
        sendHtpProtocolError(self, pane, message_id, "internal", @errorName(err));
        return;
    };

    if (!ok.success) {
        sendHtpProtocolError(self, pane, message_id, "handler_error", ok.error_message orelse "event handler failed");
        return;
    }
}

fn dispatchHtpQuery(self: *App, pane: *Pane, message_id: ?[]const u8, request_id: ?[]const u8, channel: []const u8, params: ?std.json.Value) void {
    std.log.info("htp: dispatch query pane={x} channel={s}", .{ @intFromPtr(pane), channel });
    const result = dispatchHtpQuerySync(self, @intFromPtr(pane), channel, params) catch |err| {
        sendHtpQueryError(self, pane, message_id, request_id, "internal", @errorName(err));
        return;
    };
    defer result.deinit(self.allocator);

    if (!result.success) {
        sendHtpQueryError(self, pane, message_id, request_id, "handler_error", result.error_message orelse "query handler failed");
        return;
    }

    const payload_value = if (result.value) |value| app_mod.cloneJsonValue(self.allocator, value) catch |err| {
        sendHtpQueryError(self, pane, message_id, request_id, "internal", @errorName(err));
        return;
    } else null;
    defer if (payload_value) |value| app_mod.deinitJsonValue(self.allocator, value);

    const envelope = HtpEnvelope{
        .id = nextHtpMessageId(self),
        .kind = "result",
        .status = "ok",
        .channel = channel,
        .request_id = if (request_id) |value| .{ .string = value } else null,
        .payload = payload_value,
    };
    sendHtpEnvelope(self, pane, envelope);
}

pub fn dispatchHtpQuerySync(self: *App, pane_id: usize, channel: []const u8, params: ?std.json.Value) anyerror!HtpQueryResult {
    const lua = if (self.lua) |*runtime| runtime else return .{ .success = false, .error_message = try self.allocator.dupe(u8, "lua runtime unavailable") };
    return try lua.dispatchHtpQuery(pane_id, channel, params);
}

pub fn dispatchHtpEventSync(self: *App, pane_id: usize, channel: []const u8, payload: ?std.json.Value) anyerror!lua_mod.HtpDispatchResult {
    const lua = if (self.lua) |*runtime| runtime else return .{ .success = false, .error_message = try self.allocator.dupe(u8, "lua runtime unavailable") };
    return try lua.dispatchHtpEvent(pane_id, channel, payload);
}

fn sendHtpProtocolError(self: *App, pane: *Pane, request_id: ?[]const u8, code: []const u8, message: []const u8) void {
    const envelope = HtpEnvelope{
        .id = nextHtpMessageId(self),
        .kind = "error",
        .status = code,
        .request_id = if (request_id) |value| .{ .string = value } else null,
        .@"error" = message,
    };
    sendHtpEnvelope(self, pane, envelope);
}

fn sendHtpQueryError(self: *App, pane: *Pane, message_id: ?[]const u8, request_id: ?[]const u8, code: []const u8, message: []const u8) void {
    const envelope = HtpEnvelope{
        .id = nextHtpMessageId(self),
        .kind = "result",
        .status = code,
        .request_id = if (request_id orelse message_id) |value| .{ .string = value } else null,
        .@"error" = message,
    };
    sendHtpEnvelope(self, pane, envelope);
}

fn sendHtpEnvelope(self: *App, pane: *Pane, envelope: HtpEnvelope) void {
    var buf: std.Io.Writer.Allocating = .init(self.allocator);
    defer buf.deinit();

    std.json.Stringify.value(envelope, .{}, &buf.writer) catch return;
    std.log.info("htp: send pane={x} payload={s}", .{ @intFromPtr(pane), buf.written() });
    sendHtpChunkedJson(self, pane, buf.written());
}

fn sendHtpChunkedJson(self: *App, pane: *Pane, json_text: []const u8) void {
    if (json_text.len <= HTP_MAX_CHUNK_PAYLOAD) {
        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer writer.deinit();
        writer.writer.writeAll(HTP_OSC_PREFIX) catch return;
        writer.writer.writeAll(json_text) catch return;
        writer.writer.writeAll(HTP_ST) catch return;
        pane.writeEscapeSequence(writer.written());
        return;
    }

    const total = std.math.divCeil(usize, json_text.len, HTP_MAX_CHUNK_PAYLOAD) catch return;
    const request_id = nextHtpMessageId(self);
    var index: usize = 0;
    while (index < total) : (index += 1) {
        const start = index * HTP_MAX_CHUNK_PAYLOAD;
        const end = @min(start + HTP_MAX_CHUNK_PAYLOAD, json_text.len);
        var buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer buf.deinit();
        std.json.Stringify.value(HtpEnvelope{
            .id = nextHtpMessageId(self),
            .kind = "chunk",
            .request_id = .{ .integer = @intCast(request_id) },
            .status = "partial",
            .payload = std.json.Value{ .object = chunkPayloadObject(self.allocator, json_text[start..end], index + 1, total) catch return },
        }, .{}, &buf.writer) catch return;
        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer writer.deinit();
        writer.writer.writeAll(HTP_OSC_PREFIX) catch return;
        writer.writer.writeAll(buf.written()) catch return;
        writer.writer.writeAll(HTP_ST) catch return;
        pane.writeEscapeSequence(writer.written());
    }
}

fn nextHtpMessageId(self: *App) u64 {
    const value = self.htp_next_message_id;
    self.htp_next_message_id +%= 1;
    return value;
}

fn chunkPayloadObject(allocator: std.mem.Allocator, chunk: []const u8, index: usize, total: usize) !std.json.ObjectMap {
    var object = std.json.ObjectMap.init(allocator);
    errdefer {
        var it = object.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            app_mod.deinitJsonValue(allocator, entry.value_ptr.*);
        }
        object.deinit();
    }
    try object.put(try allocator.dupe(u8, "index"), .{ .integer = @intCast(index) });
    try object.put(try allocator.dupe(u8, "total"), .{ .integer = @intCast(total) });
    try object.put(try allocator.dupe(u8, "data"), .{ .string = try allocator.dupe(u8, chunk) });
    return object;
}

test "chunkPayloadObject stores chunk metadata and owned payload" {
    const object = try chunkPayloadObject(std.testing.allocator, "payload", 2, 5);
    defer {
        const value = std.json.Value{ .object = object };
        app_mod.deinitJsonValue(std.testing.allocator, value);
    }

    try std.testing.expectEqual(@as(?usize, 2), app_mod.jsonObjectIndex(object, "index"));
    try std.testing.expectEqual(@as(?usize, 5), app_mod.jsonObjectIndex(object, "total"));
    try std.testing.expectEqualStrings("payload", app_mod.jsonObjectString(object, "data").?);
}
