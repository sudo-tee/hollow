const std = @import("std");
const ghostty = @import("term/ghostty.zig");

pub const Level = enum {
    info,
    warn,
    @"error",
    success,

    pub fn color(self: Level) ghostty.ColorRgb {
        return switch (self) {
            .info => .{ .r = 136, .g = 192, .b = 208 },
            .warn => .{ .r = 235, .g = 203, .b = 139 },
            .@"error" => .{ .r = 255, .g = 180, .b = 169 },
            .success => .{ .r = 163, .g = 190, .b = 140 },
        };
    }

    pub fn parse(text: []const u8) ?Level {
        inline for (std.meta.fields(Level)) |field| {
            if (std.mem.eql(u8, text, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }
};

pub fn parseHexColor(text: []const u8) ?ghostty.ColorRgb {
    if (text.len != 7 or text[0] != '#') return null;
    const r = std.fmt.parseInt(u8, text[1..3], 16) catch return null;
    const g = std.fmt.parseInt(u8, text[3..5], 16) catch return null;
    const b = std.fmt.parseInt(u8, text[5..7], 16) catch return null;
    return .{ .r = r, .g = g, .b = b };
}

test "notification levels provide Hollow theme colors" {
    try std.testing.expectEqual(Level.info, Level.parse("info").?);
    try std.testing.expectEqual(Level.warn, Level.parse("warn").?);
    try std.testing.expectEqual(Level.@"error", Level.parse("error").?);
    try std.testing.expectEqual(Level.success, Level.parse("success").?);
    try std.testing.expect(Level.parse("critical") == null);
    try std.testing.expectEqual(
        ghostty.ColorRgb{ .r = 136, .g = 192, .b = 208 },
        Level.info.color(),
    );
}

test "notification hex color parser accepts RGB hex" {
    try std.testing.expectEqual(
        ghostty.ColorRgb{ .r = 0x12, .g = 0xab, .b = 0xff },
        parseHexColor("#12abFF").?,
    );
    try std.testing.expect(parseHexColor("12abff") == null);
    try std.testing.expect(parseHexColor("#12abf") == null);
}
