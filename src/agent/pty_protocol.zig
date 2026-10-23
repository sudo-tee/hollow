//! Wire format for `hollow-agent pty`. A frame is kind:u8, stream:u32 LE,
//! len:u32 LE, then `len` payload bytes. One process serves one PTY on
//! `stream`; the stream field reserves room for multiplexing several later.
const std = @import("std");

pub const header_len = 9;
pub const max_payload = 1024 * 1024;
pub const stream: u32 = 1;
pub const version = 1;

pub const Kind = enum(u8) {
    // agent -> client
    hello = 1,
    output = 4,
    exit = 6,
    @"error" = 7,
    // client -> agent
    spawn = 2,
    input = 3,
    resize = 5,
    close = 8,
    _,
};

pub const Header = struct {
    kind: Kind,
    stream: u32 = stream,
    len: u32,

    pub fn encode(self: Header) [header_len]u8 {
        var out: [header_len]u8 = undefined;
        out[0] = @intFromEnum(self.kind);
        std.mem.writeInt(u32, out[1..5], self.stream, .little);
        std.mem.writeInt(u32, out[5..9], self.len, .little);
        return out;
    }

    pub fn decode(bytes: *const [header_len]u8) !Header {
        const len = std.mem.readInt(u32, bytes[5..9], .little);
        if (len > max_payload) return error.PayloadTooLarge;
        return .{ .kind = @enumFromInt(bytes[0]), .stream = std.mem.readInt(u32, bytes[1..5], .little), .len = len };
    }
};

pub const PathStyle = enum { posix, wsl };

pub const EnvVar = struct { key: []const u8, value: []const u8 };

/// JSON payload of the spawn frame. An empty argv selects the user's login
/// shell. `path_style = .wsl` converts Windows cwd/path-like env values.
pub const Spawn = struct {
    cols: u16 = 80,
    rows: u16 = 24,
    cwd: ?[]const u8 = null,
    argv: []const []const u8 = &.{},
    env: []const EnvVar = &.{},
    command: ?[]const u8 = null,
    close_on_exit: bool = false,
    path_style: PathStyle = .posix,
    shell_integration: bool = true,
    one_shot: bool = false,
    user_shell: bool = false,
};

pub fn encodeResize(cols: u16, rows: u16) [4]u8 {
    var out: [4]u8 = undefined;
    std.mem.writeInt(u16, out[0..2], cols, .little);
    std.mem.writeInt(u16, out[2..4], rows, .little);
    return out;
}

pub fn decodeResize(payload: []const u8) !struct { cols: u16, rows: u16 } {
    if (payload.len != 4) return error.InvalidResize;
    const cols = std.mem.readInt(u16, payload[0..2], .little);
    const rows = std.mem.readInt(u16, payload[2..4], .little);
    if (cols == 0 or rows == 0) return error.InvalidResize;
    return .{ .cols = cols, .rows = rows };
}

/// Incremental frame splitter over an arbitrary byte stream.
pub const Reader = struct {
    buffer: std.ArrayList(u8) = .empty,
    start: usize = 0,

    pub fn deinit(self: *Reader, allocator: std.mem.Allocator) void {
        self.buffer.deinit(allocator);
    }

    pub fn push(self: *Reader, allocator: std.mem.Allocator, bytes: []const u8) !void {
        if (self.start > 0 and self.start == self.buffer.items.len) {
            self.buffer.clearRetainingCapacity();
            self.start = 0;
        } else if (self.start >= 64 * 1024) {
            const rest = self.buffer.items.len - self.start;
            std.mem.copyForwards(u8, self.buffer.items[0..rest], self.buffer.items[self.start..]);
            self.buffer.items.len = rest;
            self.start = 0;
        }
        try self.buffer.appendSlice(allocator, bytes);
    }

    /// Returned payload is valid until the next push().
    pub fn next(self: *Reader) !?struct { header: Header, payload: []const u8 } {
        const available = self.buffer.items[self.start..];
        if (available.len < header_len) return null;
        const header = try Header.decode(available[0..header_len]);
        if (available.len - header_len < header.len) return null;
        self.start += header_len + header.len;
        return .{ .header = header, .payload = available[header_len..][0..header.len] };
    }

    pub fn buffered(self: *const Reader) usize {
        return self.buffer.items.len - self.start;
    }
};

test "header round trip and size bound" {
    const header: Header = .{ .kind = .output, .stream = 7, .len = 0x010203 };
    const bytes = header.encode();
    try std.testing.expectEqualSlices(u8, &.{ 4, 7, 0, 0, 0, 3, 2, 1, 0 }, &bytes);
    try std.testing.expectEqual(header, try Header.decode(&bytes));
    const oversized = (Header{ .kind = .input, .len = max_payload + 1 }).encode();
    try std.testing.expectError(error.PayloadTooLarge, Header.decode(&oversized));
}

test "reader splits fragmented frames" {
    const a = std.testing.allocator;
    var reader: Reader = .{};
    defer reader.deinit(a);
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(a);
    try wire.appendSlice(a, &(Header{ .kind = .input, .len = 3 }).encode());
    try wire.appendSlice(a, "abc");
    try wire.appendSlice(a, &(Header{ .kind = .resize, .len = 4 }).encode());
    try wire.appendSlice(a, &encodeResize(120, 40));
    for (wire.items) |byte| try reader.push(a, &.{byte});
    const first = (try reader.next()).?;
    try std.testing.expectEqual(Kind.input, first.header.kind);
    try std.testing.expectEqualStrings("abc", first.payload);
    const second = (try reader.next()).?;
    const size = try decodeResize(second.payload);
    try std.testing.expectEqual(@as(u16, 120), size.cols);
    try std.testing.expectEqual(@as(u16, 40), size.rows);
    try std.testing.expect((try reader.next()) == null);
}

test "spawn JSON accepts defaults and ignores unknown fields" {
    const parsed = try std.json.parseFromSlice(Spawn, std.testing.allocator, "{\"cols\":100,\"path_style\":\"wsl\",\"env\":[{\"key\":\"A\",\"value\":\"b\"}],\"future\":1}", .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u16, 100), parsed.value.cols);
    try std.testing.expectEqual(@as(u16, 24), parsed.value.rows);
    try std.testing.expectEqual(PathStyle.wsl, parsed.value.path_style);
    try std.testing.expectEqualStrings("b", parsed.value.env[0].value);
    try std.testing.expect(parsed.value.shell_integration);
}
