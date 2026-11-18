//! Bounded, opt-in character policy for background-like terminal decorations.
const std = @import("std");

pub const max_extra_glyphs = 128;

pub const Config = struct {
    enabled: bool = false,
    extra: [max_extra_glyphs]u21 = @splat(0),
    extra_len: u8 = 0,
    generation: u32 = 0,

    pub fn contains(self: *const Config, cp: u32) bool {
        // Powerline triangles, rounded caps and diagonal separators, including
        // their thin/outlined variants. Ordinary text is never included.
        if (cp >= 0xe0b0 and cp <= 0xe0bf) return true;
        for (self.extra[0..self.extra_len]) |extra| if (extra == cp) return true;
        return false;
    }

    pub fn fades(self: *const Config, cp: u32, cell_alpha: u8, protected: bool) bool {
        return self.enabled and cell_alpha < 255 and !protected and self.contains(cp);
    }

    pub fn add(self: *Config, text: []const u8) !void {
        if (text.len == 0 or text.len > 4) return error.InvalidArgument;
        const len = std.unicode.utf8ByteSequenceLength(text[0]) catch return error.InvalidArgument;
        if (text.len != len) return error.InvalidArgument;
        const cp = std.unicode.utf8Decode(text) catch return error.InvalidArgument;
        if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) return error.InvalidArgument;
        if (self.contains(cp)) return;
        if (self.extra_len == max_extra_glyphs) return error.ResourceExhausted;
        self.extra[self.extra_len] = cp;
        self.extra_len += 1;
    }
};

test "Powerline opacity is opt-in, extends defaults and exempts protected cells" {
    var config: Config = .{};
    try std.testing.expect(!config.fades(0xe0b0, 115, false));
    config.enabled = true;
    for (0xe0b0..0xe0c0) |cp| try std.testing.expect(config.fades(@intCast(cp), 115, false));
    try std.testing.expect(!config.fades('A', 115, false));
    try std.testing.expect(!config.fades(0xe0b0, 255, false));
    try std.testing.expect(!config.fades(0xe0b0, 115, true));
    try config.add("▶");
    try config.add("▶");
    try std.testing.expectEqual(@as(u8, 1), config.extra_len);
    try std.testing.expect(config.fades(0x25b6, 0, false));
    try std.testing.expect(config.contains(0xe0b6));
    try std.testing.expectError(error.InvalidArgument, config.add("ab"));
    try std.testing.expectError(error.InvalidArgument, config.add("\xff"));
    try std.testing.expectError(error.InvalidArgument, config.add("\x80"));
    try std.testing.expectError(error.InvalidArgument, config.add("\xed\xa0\x80"));
    try std.testing.expectError(error.InvalidArgument, config.add("\n"));
}

test "Powerline extension list is bounded" {
    var config: Config = .{};
    var buf: [4]u8 = undefined;
    for (0..max_extra_glyphs) |i| {
        const n = try std.unicode.utf8Encode(@intCast(0x100 + i), &buf);
        try config.add(buf[0..n]);
    }
    try std.testing.expectError(error.ResourceExhausted, config.add("▶"));
}
