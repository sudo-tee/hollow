/// Small UTF-8 encoding helpers shared across the renderer.
///
/// These are pure byte-level utilities with no dependencies on FreeType,
/// HarfBuzz, or sokol, so they can be unit-tested in isolation.
const std = @import("std");

/// Encode a single codepoint into `buf` as UTF-8, replacing invalid scalars
/// (surrogates and values above U+10FFFF) with U+FFFD.
/// Returns the number of bytes written. Returns `error.BufferTooSmall` if
/// `buf` cannot hold the encoded sequence.
pub fn encodeUtf8(input: u32, buf: []u8) error{BufferTooSmall}!usize {
    const cp = if (input > 0x10FFFF or (input >= 0xD800 and input <= 0xDFFF)) 0xFFFD else input;
    if (cp < 0x80) {
        if (buf.len < 1) return error.BufferTooSmall;
        buf[0] = @intCast(cp);
        return 1;
    }
    if (cp < 0x800) {
        if (buf.len < 2) return error.BufferTooSmall;
        buf[0] = @intCast(0xC0 | (cp >> 6));
        buf[1] = @intCast(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        if (buf.len < 3) return error.BufferTooSmall;
        buf[0] = @intCast(0xE0 | (cp >> 12));
        buf[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        buf[2] = @intCast(0x80 | (cp & 0x3F));
        return 3;
    }
    if (buf.len < 4) return error.BufferTooSmall;
    buf[0] = @intCast(0xF0 | (cp >> 18));
    buf[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
    buf[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
    buf[3] = @intCast(0x80 | (cp & 0x3F));
    return 4;
}

/// Return the byte length of the UTF-8 sequence starting with `first_byte`.
/// Assumes `first_byte` is the leading byte of a well-formed sequence; for
/// invalid leading bytes the result is 1 (treated as a single-byte fallback).
pub fn utf8CodepointLen(first_byte: u8) usize {
    if (first_byte < 0x80) return 1;
    if (first_byte < 0xC2 or first_byte > 0xF4) return 1;
    if (first_byte < 0xE0) return 2;
    if (first_byte < 0xF0) return 3;
    return 4;
}

pub const Utf8Codepoint = struct {
    /// Input bytes consumed (always at least one for nonempty input).
    len: usize,
    codepoint: u21,
    /// Valid UTF-8 suitable for shaping, with malformed input replaced by U+FFFD.
    text: []const u8,
};

/// Decode the first scalar, consuming one byte on malformed or truncated UTF-8.
/// This keeps bad input from swallowing following ASCII or reaching the shaper.
pub fn nextUtf8Codepoint(text: []const u8) ?Utf8Codepoint {
    if (text.len == 0) return null;
    const len = utf8CodepointLen(text[0]);
    const replacement: Utf8Codepoint = .{ .len = 1, .codepoint = 0xFFFD, .text = "\u{FFFD}" };
    if (len > text.len or (len == 1 and text[0] >= 0x80)) return replacement;
    const cp = std.unicode.utf8Decode(text[0..len]) catch return replacement;
    return .{ .len = len, .codepoint = cp, .text = text[0..len] };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "encodeUtf8: ASCII" {
    var buf: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try encodeUtf8('A', &buf));
    try std.testing.expectEqualSlices(u8, &.{'A'}, buf[0..1]);
}

test "encodeUtf8: two-byte (U+00A9 ©)" {
    var buf: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try encodeUtf8(0xA9, &buf));
    try std.testing.expectEqualSlices(u8, &.{ 0xC2, 0xA9 }, buf[0..2]);
}

test "encodeUtf8: three-byte (U+20AC €)" {
    var buf: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try encodeUtf8(0x20AC, &buf));
    try std.testing.expectEqualSlices(u8, &.{ 0xE2, 0x82, 0xAC }, buf[0..3]);
}

test "encodeUtf8: four-byte (U+1F600 😀)" {
    var buf: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try encodeUtf8(0x1F600, &buf));
    try std.testing.expectEqualSlices(u8, &.{ 0xF0, 0x9F, 0x98, 0x80 }, buf[0..4]);
}

test "encodeUtf8: buffer too small" {
    var buf: [1]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, encodeUtf8(0xA9, &buf));
}

test "encodeUtf8: invalid scalars become replacement characters" {
    var buf: [4]u8 = undefined;
    for ([_]u32{ 0xD800, 0xDFFF, 0x110000, std.math.maxInt(u32) }) |cp| {
        const len = try encodeUtf8(cp, &buf);
        try std.testing.expectEqualStrings("\u{FFFD}", buf[0..len]);
        try std.testing.expectError(error.BufferTooSmall, encodeUtf8(cp, buf[0..2]));
    }
}

test "utf8CodepointLen: leading byte classification" {
    try std.testing.expectEqual(@as(usize, 1), utf8CodepointLen(0x00));
    try std.testing.expectEqual(@as(usize, 1), utf8CodepointLen(0x7F));
    try std.testing.expectEqual(@as(usize, 2), utf8CodepointLen(0xC2));
    try std.testing.expectEqual(@as(usize, 3), utf8CodepointLen(0xE0));
    try std.testing.expectEqual(@as(usize, 4), utf8CodepointLen(0xF0));
    try std.testing.expectEqual(@as(usize, 4), utf8CodepointLen(0xF4));
    for ([_]u8{ 0x80, 0xBF, 0xC0, 0xC1, 0xF5, 0xFF }) |byte| {
        try std.testing.expectEqual(@as(usize, 1), utf8CodepointLen(byte));
    }
}

test "nextUtf8Codepoint: valid scalars and empty input" {
    try std.testing.expect(nextUtf8Codepoint("") == null);
    const input = "Aé中😀";
    const expected = [_]u21{ 'A', 0xE9, 0x4E2D, 0x1F600 };
    var offset: usize = 0;
    for (expected) |cp| {
        const decoded = nextUtf8Codepoint(input[offset..]).?;
        try std.testing.expectEqual(cp, decoded.codepoint);
        try std.testing.expectEqualStrings(input[offset..][0..decoded.len], decoded.text);
        offset += decoded.len;
    }
    try std.testing.expectEqual(input.len, offset);
}

test "nextUtf8Codepoint: invalid sequences consume one byte and preserve following text" {
    const invalid = [_][]const u8{
        "\x80",   "\xC0\xAF",     "\xC2",             "\xE2\x82",         "\xF0\x9F\x98",
        "\xE2AB", "\xED\xA0\x80", "\xF4\x90\x80\x80", "\xF5\x80\x80\x80",
    };
    for (invalid) |input| {
        const decoded = nextUtf8Codepoint(input).?;
        try std.testing.expectEqual(@as(usize, 1), decoded.len);
        try std.testing.expectEqual(@as(u21, 0xFFFD), decoded.codepoint);
        try std.testing.expectEqualStrings("\u{FFFD}", decoded.text);
    }
    var offset: usize = 0;
    const input = "\xE2AB";
    const expected = [_]u21{ 0xFFFD, 'A', 'B' };
    for (expected) |cp| {
        const decoded = nextUtf8Codepoint(input[offset..]).?;
        try std.testing.expectEqual(cp, decoded.codepoint);
        offset += decoded.len;
    }
    try std.testing.expectEqual(input.len, offset);
}

test "encodeUtf8: roundtrip via std.unicode" {
    var buf: [4]u8 = undefined;
    const cps = [_]u32{ 0x41, 0xA9, 0x20AC, 0x1F600, 0x0 };
    for (cps) |cp| {
        const len = try encodeUtf8(cp, &buf);
        const view = try std.unicode.Utf8View.init(buf[0..len]);
        var it = view.iterator();
        try std.testing.expectEqual(cp, it.nextCodepoint().?);
    }
}
