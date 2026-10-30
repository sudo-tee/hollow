//! Shared UI width contract: Ghostty mode-2027 grapheme widths, not byte/scalar counts.
const std = @import("std");
const NativeGrapheme = extern struct { bytes: usize, width: u8, valid: bool };
extern fn hollow_text_next_grapheme(text: [*]const u8, len: usize) NativeGrapheme;
extern fn hollow_text_width(text: [*]const u8, len: usize) usize;

pub const Grapheme = struct { len: usize, width: u8, text: []const u8 };

pub fn next(text: []const u8) ?Grapheme {
    if (text.len == 0) return null;
    const cluster = hollow_text_next_grapheme(text.ptr, text.len);
    return .{ .len = cluster.bytes, .width = cluster.width, .text = if (cluster.valid) text[0..cluster.bytes] else "\u{FFFD}" };
}

pub fn width(text: []const u8) usize {
    return hollow_text_width(text.ptr, text.len);
}

test "shared widths cover CJK combining emoji variation and ZWJ" {
    const cases = .{
        .{ "ASCII", 5 },
        .{ "中文", 4 },
        .{ "e\u{301}", 1 },
        .{ "😀", 2 },
        .{ "👨\u{200D}👩\u{200D}👧", 2 },
        .{ "❤\u{FE0F}", 2 },
        .{ "❤\u{FE0E}", 1 },
        .{ "🇺🇸", 2 },
    };
    inline for (cases) |case| try std.testing.expectEqual(@as(usize, case[1]), width(case[0]));
    const cluster = next("e\u{301}中").?;
    try std.testing.expectEqualStrings("e\u{301}", cluster.text);
    try std.testing.expectEqual(@as(u8, 1), cluster.width);
    try std.testing.expectEqualStrings("\u{FFFD}", next("\xFFx").?.text);
}

test "shared segmentation does not split long combining clusters" {
    var text: [1 + 100 * 2 + 1]u8 = undefined;
    text[0] = 'e';
    for (0..100) |i| @memcpy(text[1 + i * 2 ..][0..2], "\u{301}");
    text[text.len - 1] = 'x';
    try std.testing.expectEqual(text.len - 1, next(&text).?.len);
    try std.testing.expectEqual(@as(usize, 2), width(&text));
}
