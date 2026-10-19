//! Experimental `hollow-agent mux` v1. Separate negotiation and semantics from
//! dedicated PTY v1, while reusing its nine-byte frame envelope and spawn JSON.
const std = @import("std");
pub const pty = @import("pty_protocol.zig");
pub const Header = pty.Header;
pub const Reader = pty.Reader;
pub const Spawn = pty.Spawn;
pub const header_len = pty.header_len;
pub const max_streams = 32;
pub const window = 64 * 1024;
pub const max_data = 16 * 1024;
pub const max_spawn = 64 * 1024;
pub const control_limit = 64 * 1024;
pub const hello = "{\"protocol\":\"hollow-mux\",\"version\":1,\"capabilities\":[\"multi-pty\",\"windows\"],\"max_streams\":32,\"window\":65536,\"max_data\":16384,\"max_spawn\":65536}";
pub const hello_ack = "{\"protocol\":\"hollow-mux\",\"version\":1}";

// Additional kinds are intentionally not added to the dedicated PTY enum.
pub const negotiate: pty.Kind = @enumFromInt(9);
pub const spawned: pty.Kind = @enumFromInt(10);
pub const credit: pty.Kind = @enumFromInt(11);
pub const focus: pty.Kind = @enumFromInt(12);

pub fn amount(bytes: []const u8) !u32 {
    if (bytes.len != 4) return error.InvalidCredit;
    const value = std.mem.readInt(u32, bytes[0..4], .little);
    if (value == 0 or value > window) return error.InvalidCredit;
    return value;
}

pub fn addCredit(current: u32, bytes: []const u8) !u32 {
    const value = try amount(bytes);
    if (current > window - value) return error.InvalidCredit;
    return current + value;
}

pub fn validateHeader(h: Header) !void {
    const limit: u32 = switch (h.kind) {
        .spawn => max_spawn,
        .input => max_data,
        negotiate => 128,
        .resize, credit => 4,
        .close, focus => 0,
        else => return error.InvalidKind,
    };
    if (h.len > limit) return error.PayloadTooLarge;
    if ((h.kind == negotiate) != (h.stream == 0)) return error.InvalidStream;
}

test "credit arithmetic rejects zero overflow and oversized grants" {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, 1024, .little);
    try std.testing.expectEqual(@as(u32, window), try addCredit(window - 1024, &bytes));
    try std.testing.expectError(error.InvalidCredit, addCredit(window, &bytes));
    std.mem.writeInt(u32, &bytes, 0, .little);
    try std.testing.expectError(error.InvalidCredit, amount(&bytes));
}

test "mux limits checked from header before payload arrives" {
    try validateHeader(.{ .kind = .spawn, .stream = 2, .len = max_spawn });
    try std.testing.expectError(error.PayloadTooLarge, validateHeader(.{ .kind = .input, .len = max_data + 1 }));
    try std.testing.expectError(error.InvalidStream, validateHeader(.{ .kind = negotiate, .stream = 1, .len = 0 }));
}
