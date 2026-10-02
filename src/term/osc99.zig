const std = @import("std");
const notification = @import("../notification.zig");

pub const max_sequence_bytes: usize = 8192;
const max_plain_payload_bytes: usize = 2048;
const max_encoded_payload_bytes: usize = 4096;
const max_assembled_payload_bytes: usize = 8192;
const max_assemblies: usize = 32;
const max_queued_notifications: usize = 32;

pub const Notification = struct {
    id: ?[]u8,
    title: []u8,
    message: []u8,
    level: notification.Level,
    ttl_ms: ?u64,
    close: bool = false,

    pub fn deinit(self: *Notification, allocator: std.mem.Allocator) void {
        if (self.id) |id| allocator.free(id);
        allocator.free(self.title);
        allocator.free(self.message);
    }
};

const PayloadKind = enum {
    title,
    body,
    close,
    unsupported,
};

const Packet = struct {
    id: ?[]const u8 = null,
    payload: []const u8,
    kind: PayloadKind = .title,
    done: bool = true,
    level: ?notification.Level = null,
    ttl_ms: ?u64 = null,
    ttl_was_set: bool = false,
    encoded: bool = false,
};

const PayloadError = error{ OutOfMemory, InvalidPayload };

fn appendPayload(allocator: std.mem.Allocator, target: *std.ArrayListUnmanaged(u8), bytes: []const u8) PayloadError!void {
    if (bytes.len > max_assembled_payload_bytes - target.items.len) return error.InvalidPayload;
    try target.appendSlice(allocator, bytes);
}

const Base64Stream = struct {
    pending: [4]u8 = undefined,
    len: usize = 0,

    fn append(self: *Base64Stream, allocator: std.mem.Allocator, target: *std.ArrayListUnmanaged(u8), encoded: []const u8) PayloadError!void {
        for (encoded) |byte| {
            self.pending[self.len] = byte;
            self.len += 1;
            if (self.len == self.pending.len) try self.finish(allocator, target);
        }
    }

    fn finish(self: *Base64Stream, allocator: std.mem.Allocator, target: *std.ArrayListUnmanaged(u8)) PayloadError!void {
        if (self.len == 0) return;
        var decoded: [3]u8 = undefined;
        const bytes = decodeBase64(self.pending[0..self.len], &decoded) orelse return error.InvalidPayload;
        try appendPayload(allocator, target, bytes);
        self.len = 0;
    }
};

const Assembly = struct {
    id: ?[]u8,
    title: std.ArrayListUnmanaged(u8) = .empty,
    body: std.ArrayListUnmanaged(u8) = .empty,
    title_decoder: Base64Stream = .{},
    body_decoder: Base64Stream = .{},
    level: notification.Level = .warn,
    ttl_ms: ?u64 = null,

    fn appendPacket(self: *Assembly, allocator: std.mem.Allocator, packet: Packet) PayloadError!void {
        const target = switch (packet.kind) {
            .title => &self.title,
            .body => &self.body,
            .close, .unsupported => unreachable,
        };
        const decoder = switch (packet.kind) {
            .title => &self.title_decoder,
            .body => &self.body_decoder,
            .close, .unsupported => unreachable,
        };
        if (packet.encoded) {
            try decoder.append(allocator, target, packet.payload);
        } else {
            try decoder.finish(allocator, target);
            try appendPayload(allocator, target, packet.payload);
        }
        if (packet.done) {
            try self.title_decoder.finish(allocator, &self.title);
            try self.body_decoder.finish(allocator, &self.body);
            if (!isSafeUtf8(self.title.items) or !isSafeUtf8(self.body.items)) return error.InvalidPayload;
        }
    }

    fn deinit(self: *Assembly, allocator: std.mem.Allocator) void {
        if (self.id) |id| allocator.free(id);
        self.title.deinit(allocator);
        self.body.deinit(allocator);
    }
};

pub const State = struct {
    assemblies: std.ArrayListUnmanaged(Assembly) = .empty,
    queued: std.ArrayListUnmanaged(Notification) = .empty,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        for (self.assemblies.items) |*assembly| assembly.deinit(allocator);
        self.assemblies.deinit(allocator);
        for (self.queued.items) |*item| item.deinit(allocator);
        self.queued.deinit(allocator);
    }

    pub fn hasNotifications(self: *const State) bool {
        return self.queued.items.len > 0;
    }

    pub fn popNotification(self: *State) ?Notification {
        if (self.queued.items.len == 0) return null;
        return self.queued.orderedRemove(0);
    }

    pub fn enqueueSimple(
        self: *State,
        allocator: std.mem.Allocator,
        title: []const u8,
        message: []const u8,
        level: notification.Level,
    ) error{OutOfMemory}!void {
        if (!isSafeUtf8(title) or !isSafeUtf8(message) or (title.len == 0 and message.len == 0)) return;
        var assembly: Assembly = .{ .id = null, .level = level };
        defer assembly.deinit(allocator);
        try assembly.title.appendSlice(allocator, title);
        try assembly.body.appendSlice(allocator, message);
        try self.enqueue(allocator, try makeNotification(allocator, &assembly));
    }

    pub fn feed(self: *State, allocator: std.mem.Allocator, sequence: []const u8) error{OutOfMemory}!void {
        const packet = parsePacket(sequence) orelse return;

        if (packet.kind == .unsupported) return;
        if (packet.kind == .close) {
            const id = packet.id orelse return;
            var close_id: ?[]u8 = try allocator.dupe(u8, id);
            errdefer if (close_id) |value| allocator.free(value);
            var close_title: ?[]u8 = try allocator.dupe(u8, "");
            errdefer if (close_title) |value| allocator.free(value);
            var close_message: ?[]u8 = try allocator.dupe(u8, "");
            errdefer if (close_message) |value| allocator.free(value);
            const close = Notification{
                .id = close_id.?,
                .title = close_title.?,
                .message = close_message.?,
                .level = .warn,
                .ttl_ms = null,
                .close = true,
            };
            close_id = null;
            close_title = null;
            close_message = null;
            try self.enqueue(allocator, close);
            if (self.findAssembly(packet.id)) |index| self.removeAssembly(allocator, index);
            return;
        }

        const assembly_index = try self.getAssembly(allocator, packet.id);
        const assembly = &self.assemblies.items[assembly_index];
        assembly.appendPacket(allocator, packet) catch |err| {
            self.removeAssembly(allocator, assembly_index);
            return switch (err) {
                error.InvalidPayload => {},
                error.OutOfMemory => error.OutOfMemory,
            };
        };

        if (packet.level) |level| assembly.level = level;
        if (packet.ttl_was_set) assembly.ttl_ms = packet.ttl_ms;
        if (!packet.done) return;
        // A completed notification replaces the previous one rather than
        // inheriting its text, urgency, or expiry policy.
        defer self.removeAssembly(allocator, assembly_index);

        if (assembly.title.items.len == 0 and assembly.body.items.len == 0) return;
        try self.enqueue(allocator, try makeNotification(allocator, assembly));
    }

    fn enqueue(self: *State, allocator: std.mem.Allocator, item: Notification) error{OutOfMemory}!void {
        if (self.queued.items.len == max_queued_notifications) {
            var oldest = self.queued.orderedRemove(0);
            oldest.deinit(allocator);
        }
        self.queued.append(allocator, item) catch |err| {
            var owned = item;
            owned.deinit(allocator);
            return err;
        };
    }

    fn getAssembly(self: *State, allocator: std.mem.Allocator, id: ?[]const u8) error{OutOfMemory}!usize {
        if (self.findAssembly(id)) |index| return index;

        if (self.assemblies.items.len == max_assemblies) self.removeAssembly(allocator, 0);
        const owned_id = if (id) |value| try allocator.dupe(u8, value) else null;
        errdefer if (owned_id) |value| allocator.free(value);
        try self.assemblies.append(allocator, .{ .id = owned_id });
        return self.assemblies.items.len - 1;
    }

    fn findAssembly(self: *const State, id: ?[]const u8) ?usize {
        for (self.assemblies.items, 0..) |assembly, index| {
            if (sameId(assembly.id, id)) return index;
        }
        return null;
    }

    fn removeAssembly(self: *State, allocator: std.mem.Allocator, index: usize) void {
        var removed = self.assemblies.orderedRemove(index);
        removed.deinit(allocator);
    }
};

fn sameId(lhs: ?[]const u8, rhs: ?[]const u8) bool {
    if (lhs == null or rhs == null) return lhs == null and rhs == null;
    return std.mem.eql(u8, lhs.?, rhs.?);
}

fn makeNotification(allocator: std.mem.Allocator, assembly: *const Assembly) error{OutOfMemory}!Notification {
    const id = if (assembly.id) |value| try allocator.dupe(u8, value) else null;
    errdefer if (id) |value| allocator.free(value);

    if (assembly.body.items.len == 0 and assembly.title.items.len > 0) {
        const message = try allocator.dupe(u8, assembly.title.items);
        errdefer allocator.free(message);
        const title = try allocator.dupe(u8, "");
        errdefer allocator.free(title);
        return .{
            .id = id,
            .title = title,
            .message = message,
            .level = assembly.level,
            .ttl_ms = assembly.ttl_ms,
        };
    }

    const title = try allocator.dupe(u8, assembly.title.items);
    errdefer allocator.free(title);
    const message = try allocator.dupe(u8, assembly.body.items);
    errdefer allocator.free(message);
    return .{
        .id = id,
        .title = title,
        .message = message,
        .level = assembly.level,
        .ttl_ms = assembly.ttl_ms,
    };
}

fn parsePacket(sequence: []const u8) ?Packet {
    const first_sep = std.mem.indexOfScalar(u8, sequence, ';') orelse return null;
    const metadata = sequence[0..first_sep];
    const raw_payload = sequence[first_sep + 1 ..];
    var result: Packet = .{ .payload = raw_payload };

    var fields = std.mem.splitScalar(u8, metadata, ':');
    while (fields.next()) |raw_field| {
        const field = std.mem.trim(u8, raw_field, " \t");
        const eq = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        const key = std.mem.trim(u8, field[0..eq], " \t");
        const value = std.mem.trim(u8, field[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "i")) {
            if (value.len > 128 or !validIdentifier(value)) return null;
            result.id = value;
        } else if (std.mem.eql(u8, key, "p")) {
            if (std.mem.eql(u8, value, "title")) {
                result.kind = .title;
            } else if (std.mem.eql(u8, value, "body")) {
                result.kind = .body;
            } else if (std.mem.eql(u8, value, "close")) {
                result.kind = .close;
            } else {
                result.kind = .unsupported;
            }
        } else if (std.mem.eql(u8, key, "d")) {
            if (std.mem.eql(u8, value, "0")) result.done = false else if (std.mem.eql(u8, value, "1")) result.done = true;
        } else if (std.mem.eql(u8, key, "e")) {
            result.encoded = std.mem.eql(u8, value, "1");
        } else if (std.mem.eql(u8, key, "u")) {
            result.level = if (std.mem.eql(u8, value, "0")) .info else if (std.mem.eql(u8, value, "2")) .@"error" else .warn;
        } else if (std.mem.eql(u8, key, "w")) {
            result.ttl_was_set = true;
            const value_ms = std.fmt.parseInt(i64, value, 10) catch -1;
            result.ttl_ms = if (value_ms >= 0) @intCast(value_ms) else null;
        }
    }

    if (result.encoded) {
        if (raw_payload.len > max_encoded_payload_bytes) return null;
    } else {
        if (raw_payload.len > max_plain_payload_bytes or !isSafeUtf8(raw_payload)) return null;
    }

    return result;
}

fn validIdentifier(value: []const u8) bool {
    for (value) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '+' or byte == '.')) return false;
    }
    return true;
}

pub fn isSafeUtf8(value: []const u8) bool {
    var iterator = (std.unicode.Utf8View.init(value) catch return false).iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint <= 0x1f or codepoint == 0x7f or (codepoint >= 0x80 and codepoint <= 0x9f)) return false;
    }
    return true;
}

fn decodeBase64(value: []const u8, out: []u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, value, '=')) |_| {
        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(value) catch return null;
        if (decoded_len > out.len) return null;
        std.base64.standard.Decoder.decode(out[0..decoded_len], value) catch return null;
        return out[0..decoded_len];
    }
    const decoded_len = std.base64.standard_no_pad.Decoder.calcSizeForSlice(value) catch return null;
    if (decoded_len > out.len) return null;
    std.base64.standard_no_pad.Decoder.decode(out[0..decoded_len], value) catch return null;
    return out[0..decoded_len];
}

test "OSC 99 emits title and body with urgency and timeout" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);

    try state.feed(std.testing.allocator, "i=build:d=0:p=title;Build finished");
    try std.testing.expect(!state.hasNotifications());
    try state.feed(std.testing.allocator, "i=build:p=body:u=2:w=5000;All tests passed");

    var item = state.popNotification().?;
    defer item.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("build", item.id.?);
    try std.testing.expectEqualStrings("Build finished", item.title);
    try std.testing.expectEqualStrings("All tests passed", item.message);
    try std.testing.expectEqual(notification.Level.@"error", item.level);
    try std.testing.expectEqual(@as(?u64, 5000), item.ttl_ms);
}

test "OSC 99 accepts simple and base64 payloads and supports closing IDs" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);

    try state.feed(std.testing.allocator, ";Hello");
    try state.feed(std.testing.allocator, "i=encoded:e=1;V29ybGQ=");
    try state.feed(std.testing.allocator, "i=encoded:p=close;");

    var simple = state.popNotification().?;
    defer simple.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Hello", simple.message);
    try std.testing.expectEqualStrings("", simple.title);

    var encoded = state.popNotification().?;
    defer encoded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("World", encoded.message);
    try std.testing.expectEqualStrings("encoded", encoded.id.?);

    var closed = state.popNotification().?;
    defer closed.deinit(std.testing.allocator);
    try std.testing.expect(closed.close);
    try std.testing.expectEqualStrings("encoded", closed.id.?);
}

test "OSC 99 rejects unsafe payloads and ignores unsupported payload types" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);

    try state.feed(std.testing.allocator, ";;bad\nmessage");
    try state.feed(std.testing.allocator, "p=icon;ignored");
    try std.testing.expect(!state.hasNotifications());
}

test "OSC 99 replacements do not inherit completed notification state" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);

    try state.feed(std.testing.allocator, "i=build:d=0:u=2:w=0;Old title");
    try state.feed(std.testing.allocator, "i=build:p=body;Old body");
    var old = state.popNotification().?;
    defer old.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), state.assemblies.items.len);

    try state.feed(std.testing.allocator, "i=build;New title");
    var updated = state.popNotification().?;
    defer updated.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", updated.title);
    try std.testing.expectEqualStrings("New title", updated.message);
    try std.testing.expectEqual(notification.Level.warn, updated.level);
    try std.testing.expectEqual(@as(?u64, null), updated.ttl_ms);

    try state.feed(std.testing.allocator, "i=build:d=0:u=0:w=1200;Next title");
    try state.feed(std.testing.allocator, "i=build:p=body;Next body");
    var chunked = state.popNotification().?;
    defer chunked.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Next title", chunked.title);
    try std.testing.expectEqualStrings("Next body", chunked.message);
    try std.testing.expectEqual(notification.Level.info, chunked.level);
    try std.testing.expectEqual(@as(?u64, 1200), chunked.ttl_ms);
}

test "OSC 99 decodes Base64 split at every encoded boundary" {
    for ([_][]const u8{ "SGVsbG8=", "SGVsbG8" }) |encoded| {
        for (1..encoded.len) |split| {
            var state: State = .{};
            defer state.deinit(std.testing.allocator);
            var first_buf: [64]u8 = undefined;
            var last_buf: [64]u8 = undefined;
            const first = try std.fmt.bufPrint(&first_buf, "i=chunk:d=0:e=1;{s}", .{encoded[0..split]});
            const last = try std.fmt.bufPrint(&last_buf, "i=chunk:e=1;{s}", .{encoded[split..]});
            try state.feed(std.testing.allocator, first);
            try std.testing.expect(!state.hasNotifications());
            try state.feed(std.testing.allocator, last);
            var item = state.popNotification().?;
            defer item.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings("Hello", item.message);
        }
    }
}

test "OSC 99 supports independently padded Base64 chunks and plain continuation" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    try state.feed(std.testing.allocator, "i=chunk:d=0:e=1;SGU=");
    try state.feed(std.testing.allocator, "i=chunk:d=0:e=1;bGxv");
    try state.feed(std.testing.allocator, "i=chunk; world");
    var item = state.popNotification().?;
    defer item.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Hello world", item.message);
}

test "OSC 99 validates encoded UTF-8 only after assembling title and body" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    // Base64 for the euro sign splits its UTF-8 bytes across decoded groups.
    try state.feed(std.testing.allocator, "i=utf8:d=0:e=1;4g==");
    try state.feed(std.testing.allocator, "i=utf8:d=0:e=1;gqw=");
    try state.feed(std.testing.allocator, "i=utf8:p=body:e=1;4oKs");
    var item = state.popNotification().?;
    defer item.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("€", item.title);
    try std.testing.expectEqualStrings("€", item.message);
}

test "OSC 99 accepts the full encoded packet limit and bounds decoded assemblies" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    const packet = "i=large:e=1;" ++ "QUFB" ** (max_encoded_payload_bytes / 4);
    try state.feed(std.testing.allocator, packet);
    var item = state.popNotification().?;
    defer item.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("A" ** 3072, item.message);

    const chunk = "i=large:d=0:e=1;" ++ "QUFB" ** (max_encoded_payload_bytes / 4);
    try state.feed(std.testing.allocator, chunk);
    try state.feed(std.testing.allocator, chunk);
    try state.feed(std.testing.allocator, packet);
    try std.testing.expect(!state.hasNotifications());
    try std.testing.expectEqual(@as(usize, 0), state.assemblies.items.len);
}

test "OSC 99 discards malformed or unsafe encoded assemblies" {
    for ([_][]const u8{ "A", "SG!v", "4g==", "Cg==" }) |encoded| {
        var state: State = .{};
        defer state.deinit(std.testing.allocator);
        try state.feed(std.testing.allocator, "i=bad:d=0;Title");
        var buf: [64]u8 = undefined;
        const packet = try std.fmt.bufPrint(&buf, "i=bad:p=body:e=1;{s}", .{encoded});
        try state.feed(std.testing.allocator, packet);
        try std.testing.expect(!state.hasNotifications());
        try std.testing.expectEqual(@as(usize, 0), state.assemblies.items.len);
    }
}
