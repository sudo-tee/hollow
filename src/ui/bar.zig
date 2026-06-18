const ghostty = @import("../term/ghostty.zig");

pub const Side = enum {
    left,
    right,
};

pub const Segment = struct {
    text: []const u8 = "",
    fg: ?ghostty.ColorRgb = null,
    bg: ?ghostty.ColorRgb = null,
    bold: bool = false,
    id: ?[]const u8 = null,
    spacer: bool = false,
    radius: f32 = 0,
    border: ?ghostty.ColorRgb = null,
    border_size: f32 = 1.0,
};
