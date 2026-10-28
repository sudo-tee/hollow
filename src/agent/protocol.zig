//! Hollow Agent Protocol v1 wire primitives. Transport and payload dispatch are
//! deliberately outside this module; all integers use little-endian encoding.

const std = @import("std");

pub const header_len = 22;
pub const max_payload = 1024 * 1024;
pub const max_data = 16 * 1024;

pub const Kind = enum(u8) {
    hello = 1,
    hello_ack = 2,
    request = 3,
    response = 4,
    error_response = 5,
    data = 6,
    cancel = 7,
    ping = 8,
    pong = 9,
    window_update = 10,
};

pub const Header = struct {
    kind: Kind,
    flags: u8 = 0,
    request_id: u64 = 0,
    stream_id: u64 = 0,
    payload_len: u32,

    pub fn encode(self: Header) ![header_len]u8 {
        try validate(self);
        var out: [header_len]u8 = undefined;
        putInt(u32, out[0..4], self.payload_len);
        out[4] = @backingInt(self.kind);
        out[5] = self.flags;
        putInt(u64, out[6..14], self.request_id);
        putInt(u64, out[14..22], self.stream_id);
        return out;
    }

    pub fn decode(bytes: *const [header_len]u8) !Header {
        const kind: Kind = switch (bytes[4]) {
            1 => .hello,
            2 => .hello_ack,
            3 => .request,
            4 => .response,
            5 => .error_response,
            6 => .data,
            7 => .cancel,
            8 => .ping,
            9 => .pong,
            10 => .window_update,
            else => return error.UnknownKind,
        };
        const result = Header{
            .kind = kind,
            .flags = bytes[5],
            .request_id = getInt(u64, bytes[6..14]),
            .stream_id = getInt(u64, bytes[14..22]),
            .payload_len = getInt(u32, bytes[0..4]),
        };
        try validate(result);
        return result;
    }
};

fn validate(h: Header) !void {
    if (h.flags != 0) return error.InvalidFlags;
    if (h.payload_len > max_payload) return error.PayloadTooLarge;
    if (h.kind == .data and h.payload_len > max_data) return error.DataTooLarge;
}

/// WINDOW_UPDATE payload is one positive u64 LE consumed-byte count.
/// Stream selection is carried by the frame header; zero credit is invalid.
pub fn decodeWindowUpdate(payload: *const [8]u8) !u64 {
    const amount = getInt(u64, payload);
    if (amount == 0) return error.InvalidWindowUpdate;
    return amount;
}

/// Accepts arbitrary byte fragments. Returns a decoded header exactly when all
/// 22 bytes have arrived. Caller owns bounded payload reading (max_payload).
pub const Decoder = struct {
    bytes: [header_len]u8 = undefined,
    used: usize = 0,

    pub fn push(self: *Decoder, input: []const u8) !?Header {
        // This decoder consumes headers only. Never silently discard bytes from
        // the payload (or the next header) in a larger transport read.
        if (input.len > header_len - self.used) return error.ExcessHeaderBytes;
        var i: usize = 0;
        while (i < input.len) : (i += 1) {
            if (self.used == header_len) return error.HeaderNotTaken;
            self.bytes[self.used] = input[i];
            self.used += 1;
            if (self.used == header_len) return try Header.decode(&self.bytes);
        }
        return null;
    }

    /// Reset after caller has consumed decoded header and its payload.
    pub fn reset(self: *Decoder) void {
        self.used = 0;
    }
};

test "header decoder rejects extra bytes without consuming input" {
    var decoder = Decoder{};
    const oversized = @as([header_len + 1]u8, @splat(0));
    try std.testing.expectError(error.ExcessHeaderBytes, decoder.push(&oversized));
    try std.testing.expectEqual(@as(usize, 0), decoder.used);
}

fn putInt(comptime T: type, dst: []u8, value: T) void {
    for (0..@sizeOf(T)) |i| dst[i] = @truncate(value >> @intCast(i * 8));
}

fn getInt(comptime T: type, src: []const u8) T {
    var value: T = 0;
    for (0..@sizeOf(T)) |i| value |= @as(T, src[i]) << @intCast(i * 8);
    return value;
}

test "header endian fixture and round trip" {
    const h = Header{ .kind = .request, .flags = 0, .request_id = 0x0807060504030201, .stream_id = 0x1817161514131211, .payload_len = 0x00030201 };
    const encoded = try h.encode();
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 0, 3, 0, 1, 2, 3, 4, 5, 6, 7, 8, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18 }, &encoded);
    try std.testing.expectEqual(h, try Header.decode(&encoded));
}

test "incremental decoder accepts every header fragmentation boundary" {
    const h = Header{ .kind = .hello, .payload_len = 0 };
    const bytes = try h.encode();
    for (0..header_len) |boundary| {
        var decoder = Decoder{};
        try std.testing.expect((try decoder.push(bytes[0..boundary])) == null);
        const got = try decoder.push(bytes[boundary..]);
        try std.testing.expectEqual(h, got.?);
    }
}

test "validation rejects flags, unknown kinds, oversized payload and DATA" {
    try std.testing.expectError(error.InvalidFlags, (Header{ .kind = .ping, .flags = 1, .payload_len = 0 }).encode());
    try std.testing.expectError(error.PayloadTooLarge, (Header{ .kind = .request, .payload_len = max_payload + 1 }).encode());
    try std.testing.expectError(error.DataTooLarge, (Header{ .kind = .data, .payload_len = max_data + 1 }).encode());
    var bad: [header_len]u8 = undefined;
    @memset(&bad, 0);
    bad[4] = 99;
    try std.testing.expectError(error.UnknownKind, Header.decode(&bad));
    const zero = try (Header{ .kind = .ping, .payload_len = 0 }).encode();
    try std.testing.expectEqual(@as(u32, 0), (try Header.decode(&zero)).payload_len);
}

test "window update must carry positive u64 little endian credit" {
    try std.testing.expectEqual(@as(u64, 0x0807060504030201), try decodeWindowUpdate(&.{ 1, 2, 3, 4, 5, 6, 7, 8 }));
    const zero_credit = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectError(error.InvalidWindowUpdate, decodeWindowUpdate(&zero_credit));
}
