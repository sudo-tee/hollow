const std = @import("std");
const Pane = @import("../pane.zig").Pane;
const ghostty = @import("../term/ghostty.zig");
const lua_mod = @import("../lua_bridge.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const HtpQueryResult = lua_mod.HtpQueryResult;
const codec_mod = @import("../htp/codec.zig");

pub const HTP_OSC_PREFIX = codec_mod.osc_prefix;
pub const HTP_ST = codec_mod.string_terminator;
pub const HTP_MAX_CHUNK_PAYLOAD = codec_mod.max_chunk_payload;
pub const HTP_MAX_QUEUED_MESSAGES = 256;
pub const HTP_MAX_QUEUED_BYTES = 1024 * 1024;
pub const HTP_MAX_MESSAGES_PER_FRAME = 32;
pub const HTP_MAX_BYTES_PER_FRAME = 256 * 1024;
pub const HTP_MAX_CHUNKS = codec_mod.max_chunks;
pub const HTP_MAX_ASSEMBLY_BYTES = codec_mod.max_assembly_bytes;

pub const HtpQueuedMessage = struct {
    pane_id: usize,
    payload: []u8,
};

pub const HtpEnvelope = codec_mod.Envelope;

pub fn htpMessageCallback(pane: *Pane, payload: []const u8) void {
    const app: *App = @ptrCast(@alignCast(pane.host_context orelse return));
    queueHtpMessage(app, pane, payload);
}

pub fn queueHtpMessage(self: *App, pane: *Pane, payload: []const u8) void {
    const pending_count = self.htp_pending_messages.items.len - self.htp_pending_message_head;
    if (pending_count >= HTP_MAX_QUEUED_MESSAGES or
        payload.len > HTP_MAX_QUEUED_BYTES - self.htp_pending_message_bytes)
    {
        std.log.warn("htp: dropping message because queue is full", .{});
        return;
    }
    const owned = self.allocator.dupe(u8, payload) catch return;
    self.htp_pending_messages.append(self.allocator, .{
        .pane_id = @intFromPtr(pane),
        .payload = owned,
    }) catch {
        self.allocator.free(owned);
        return;
    };
    self.htp_pending_message_bytes += payload.len;
    self.signalWake();
}

pub fn bindHtpHandlers(self: *App) void {
    if (self.mux) |*mux| {
        var panes = mux.paneIterator();
        while (panes.next()) |pane| {
            pane.setHtpMessageHandler(htpMessageCallback);
        }
    }
}

pub fn processHtpMessages(self: *App) void {
    self.htp_codec.prune(std.time.nanoTimestamp());

    var processed_count: usize = 0;
    var processed_bytes: usize = 0;
    while (self.htp_pending_message_head < self.htp_pending_messages.items.len and
        processed_count < HTP_MAX_MESSAGES_PER_FRAME)
    {
        const message = self.htp_pending_messages.items[self.htp_pending_message_head];
        if (processed_count > 0 and processed_bytes + message.payload.len > HTP_MAX_BYTES_PER_FRAME) break;
        self.htp_pending_message_head += 1;
        self.htp_pending_message_bytes -= message.payload.len;
        processed_count += 1;
        processed_bytes += message.payload.len;
        defer self.allocator.free(message.payload);
        const pane = self.findPaneById(message.pane_id) orelse {
            self.htp_codec.removeSource(message.pane_id);
            continue;
        };
        handleHtpMessage(self, pane, message.payload);
    }

    compactHtpMessageQueue(self);
}

fn compactHtpMessageQueue(self: *App) void {
    const head = self.htp_pending_message_head;
    if (head == self.htp_pending_messages.items.len) {
        self.htp_pending_messages.clearRetainingCapacity();
        self.htp_pending_message_head = 0;
    } else if (head >= HTP_MAX_QUEUED_MESSAGES) {
        const remaining = self.htp_pending_messages.items[head..];
        std.mem.copyForwards(HtpQueuedMessage, self.htp_pending_messages.items, remaining);
        self.htp_pending_messages.shrinkRetainingCapacity(remaining.len);
        self.htp_pending_message_head = 0;
    }
}

fn handleHtpMessage(self: *App, pane: *Pane, payload: []const u8) void {
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
    if (index == 0 or total == 0 or index > total or total > HTP_MAX_CHUNKS or data.len > HTP_MAX_CHUNK_PAYLOAD) {
        sendHtpProtocolError(self, pane, message_id, "invalid_message", "chunk index out of range");
        return;
    }

    var assembly = self.htp_codec.findOrCreateAssembly(@intFromPtr(pane), request_id, total, std.time.nanoTimestamp()) catch |err| {
        sendHtpProtocolError(self, pane, message_id, "internal", @errorName(err));
        return;
    };
    if (assembly.total != total or assembly.next_index != index) {
        self.htp_codec.removeAssembly(@intFromPtr(pane), request_id);
        sendHtpProtocolError(self, pane, message_id, "invalid_message", "unexpected chunk order");
        return;
    }
    if (data.len > HTP_MAX_ASSEMBLY_BYTES - assembly.buffer.items.len) {
        self.htp_codec.removeAssembly(@intFromPtr(pane), request_id);
        sendHtpProtocolError(self, pane, message_id, "resource_limit", "chunk assembly too large");
        return;
    }
    assembly.buffer.appendSlice(self.allocator, data) catch |err| {
        self.htp_codec.removeAssembly(@intFromPtr(pane), request_id);
        sendHtpProtocolError(self, pane, message_id, "internal", @errorName(err));
        return;
    };
    assembly.next_index += 1;
    if (index < total) return;

    const joined = assembly.buffer.toOwnedSlice(self.allocator) catch |err| {
        self.htp_codec.removeAssembly(@intFromPtr(pane), request_id);
        sendHtpProtocolError(self, pane, message_id, "internal", @errorName(err));
        return;
    };
    defer self.allocator.free(joined);
    self.htp_codec.removeAssembly(@intFromPtr(pane), request_id);
    handleHtpMessage(self, pane, joined);
}

fn dispatchHtpEvent(self: *App, pane: *Pane, message_id: ?[]const u8, channel: []const u8, payload: ?std.json.Value) void {
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
    sendHtpChunkedJson(self, pane, buf.written());
}

fn sendHtpChunkedJson(self: *App, pane: *Pane, json_text: []const u8) void {
    self.htp_codec.writeFramed(json_text, pane, writeFramedHtp) catch |err| {
        std.log.warn("htp: failed to frame response: {s}", .{@errorName(err)});
    };
}

fn writeFramedHtp(context: *anyopaque, bytes: []const u8) void {
    const pane: *Pane = @ptrCast(@alignCast(context));
    pane.writeEscapeSequence(bytes);
}

fn nextHtpMessageId(self: *App) u64 {
    return self.htp_codec.nextMessageId();
}
