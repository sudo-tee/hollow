/// Small UTF-8 encoding helpers shared across the renderer.
///
/// These are pure byte-level utilities with no dependencies on FreeType,
/// HarfBuzz, or sokol, so they can be unit-tested in isolation.

const std = @import("std");

/// Encode a single codepoint into `buf` as UTF-8.
/// Returns the number of bytes written. Returns `error.BufferTooSmall` if
/// `buf` cannot hold the encoded sequence.
pub fn encodeUtf8(cp: u32, buf: []u8) error{BufferTooSmall}!usize {
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
/// continuation bytes the result is 1 (treated as a single-byte fallback).
pub fn utf8CodepointLen(first_byte: u8) usize {
    if (first_byte < 0x80) return 1;
    if (first_byte < 0xE0) return 2;
    if (first_byte < 0xF0) return 3;
    return 4;
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

test "utf8CodepointLen: leading byte classification" {
    try std.testing.expectEqual(@as(usize, 1), utf8CodepointLen(0x00));
    try std.testing.expectEqual(@as(usize, 1), utf8CodepointLen(0x7F));
    try std.testing.expectEqual(@as(usize, 2), utf8CodepointLen(0xC2));
    try std.testing.expectEqual(@as(usize, 3), utf8CodepointLen(0xE0));
    try std.testing.expectEqual(@as(usize, 4), utf8CodepointLen(0xF0));
    try std.testing.expectEqual(@as(usize, 4), utf8CodepointLen(0xF4));
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
