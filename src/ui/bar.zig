const ghostty = @import("../term/ghostty.zig");

pub const Side = enum {
    left,
    right,
};

pub const Segment = struct {
    pub const Padding = struct {
        top: f32 = 0,
        right: f32 = 0,
        bottom: f32 = 0,
        left: f32 = 0,
    };
    text: []const u8 = "",
    fg: ?ghostty.ColorRgb = null,
    bg: ?ghostty.ColorRgb = null,
    bold: bool = false,
    id: ?[]const u8 = null,
    spacer: bool = false,
    radius: f32 = 0,
    border: ?ghostty.ColorRgb = null,
    border_size: f32 = 1.0,
    padding: Padding = .{},
};

pub fn rowPadding(segments: []const Segment) Segment.Padding {
    var padding = Segment.Padding{};
    for (segments) |seg| {
        if (seg.spacer or seg.text.len == 0) continue;
        padding.top = @max(padding.top, seg.padding.top);
        padding.bottom = @max(padding.bottom, seg.padding.bottom);
    }
    return padding;
}
