const std = @import("std");

fn be32(value: u32) [4]u8 {
    return .{ @truncate(value >> 24), @truncate(value >> 16), @truncate(value >> 8), @truncate(value) };
}

fn crc32(bytes: []const u8) u32 {
    var crc: u32 = 0xffffffff;
    for (bytes) |byte| {
        crc ^= byte;
        for (0..8) |_| crc = (crc >> 1) ^ (if (crc & 1 != 0) @as(u32, 0xedb88320) else 0);
    }
    return ~crc;
}

fn chunk(out: *std.ArrayList(u8), allocator: std.mem.Allocator, kind: *const [4]u8, data: []const u8) !void {
    try out.appendSlice(allocator, &be32(@intCast(data.len)));
    const start = out.items.len;
    try out.appendSlice(allocator, kind);
    try out.appendSlice(allocator, data);
    try out.appendSlice(allocator, &be32(crc32(out.items[start..])));
}

/// Encode top-down RGBA pixels, cropping to a rectangle in framebuffer coordinates.
pub fn encode(allocator: std.mem.Allocator, pixels: []const u8, frame_width: usize, x: usize, y: usize, width: usize, height: usize) ![]u8 {
    const frame_height = pixels.len / (frame_width * 4);
    if (width == 0 or height == 0 or x + width > frame_width or y + height > frame_height) return error.InvalidScreenshotBounds;

    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(allocator);
    for (y..y + height) |row| {
        try raw.append(allocator, 0); // PNG filter: none
        try raw.appendSlice(allocator, pixels[(row * frame_width + x) * 4 ..][0 .. width * 4]);
    }

    var compressed: std.ArrayList(u8) = .empty;
    defer compressed.deinit(allocator);
    try compressed.appendSlice(allocator, &.{ 0x78, 0x01 }); // zlib, no compression
    var offset: usize = 0;
    while (offset < raw.items.len) {
        const size: u16 = @intCast(@min(raw.items.len - offset, 65535));
        try compressed.appendSlice(allocator, &.{ if (offset + size == raw.items.len) 1 else 0, @truncate(size), @truncate(size >> 8), @truncate(~size), @truncate((~size) >> 8) });
        try compressed.appendSlice(allocator, raw.items[offset..][0..size]);
        offset += size;
    }
    var a: u32 = 1;
    var b: u32 = 0;
    for (raw.items) |byte| {
        a = (a + byte) % 65521;
        b = (b + a) % 65521;
    }
    try compressed.appendSlice(allocator, &be32((b << 16) | a));

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    @memcpy(ihdr[0..4], &be32(@intCast(width)));
    @memcpy(ihdr[4..8], &be32(@intCast(height)));
    ihdr[8] = 8;
    ihdr[9] = 6; // RGBA
    @memset(ihdr[10..], 0);
    try chunk(&out, allocator, "IHDR", &ihdr);
    try chunk(&out, allocator, "IDAT", compressed.items);
    try chunk(&out, allocator, "IEND", "");
    return out.toOwnedSlice(allocator);
}

test "PNG crop round trip" {
    const allocator = std.testing.allocator;
    const pixels = [_]u8{
        1, 2, 3, 255, 4, 5, 6, 255,
        7, 8, 9, 255, 10, 11, 12, 255,
    };
    const png = try encode(allocator, &pixels, 2, 1, 0, 1, 2);
    defer allocator.free(png);
    try std.testing.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n", png[0..8]);
    try std.testing.expectEqualSlices(u8, &be32(1), png[16..20]);
    try std.testing.expectEqualSlices(u8, &be32(2), png[20..24]);
}
