const ghostty = @import("../term/ghostty.zig");

pub const Side = enum {
    left,
    right,
};

pub const Segment = struct {
    text: []const u8,
    fg: ?ghostty.ColorRgb = null,
    bg: ?ghostty.ColorRgb = null,
    bold: bool = false,
};
