const std = @import("std");
const fastmem = @import("../fastmem.zig");
const ghostty = @import("../term/ghostty.zig");
const FrameSnapshot = @import("../render/debug_backend.zig").FrameSnapshot;

pub fn countUtf8Codepoints(text: []const u8) usize {
    var i: usize = 0;
    var count: usize = 0;
    while (i < text.len) {
        const b = text[i];
        const step: usize = if (b < 0x80) 1 else if (b < 0xE0) 2 else if (b < 0xF0) 3 else 4;
        if (i + step > text.len) break;
        i += step;
        count += 1;
    }
    return count;
}

pub fn snapshotHash(snapshot: *const FrameSnapshot, render_mode: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(render_mode);
    hasher.update(std.mem.asBytes(&snapshot.rows));
    hasher.update(std.mem.asBytes(&snapshot.cols));
    const dirty = @intFromEnum(snapshot.dirty);
    hasher.update(std.mem.asBytes(&dirty));
    hasher.update(snapshot.title);
    var line_idx: usize = 0;
    while (line_idx < snapshot.visible_line_count and line_idx < snapshot.lines.len) : (line_idx += 1) {
        hasher.update(snapshot.lines[line_idx][0..snapshot.line_lens[line_idx]]);
        hasher.update("\n");
    }
    return hasher.final();
}

pub fn titleCString(text: []const u8) [256:0]u8 {
    const max_len = 255;
    var buf: [max_len + 1:0]u8 = [_:0]u8{0} ** (max_len + 1);
    const trimmed = if (text.len > max_len) text[0..max_len] else text;
    fastmem.copy(u8, buf[0..trimmed.len], trimmed);
    return buf;
}

pub fn firstCodepoint(text: []const u8) u32 {
    if (text.len == 0) return 0;
    const len = std.unicode.utf8ByteSequenceLength(text[0]) catch return text[0];
    if (len > text.len) return text[0];
    return std.unicode.utf8Decode(text[0..len]) catch text[0];
}

pub fn appendCellText(runtime: *ghostty.Runtime, row_cells: ?*anyopaque, out: []u8, len: *usize) void {
    if (len.* >= out.len) return;
    const max_grapheme_len = 16;
    const grapheme_len = @min(runtime.cellGraphemeLen(row_cells), max_grapheme_len);
    if (grapheme_len == 0) {
        out[len.*] = ' ';
        len.* += 1;
        return;
    }

    var cps: [16]u32 = [_]u32{0} ** 16;
    runtime.cellGraphemes(row_cells, &cps);
    var cp_index: usize = 0;
    while (cp_index < grapheme_len and cps[cp_index] != 0) : (cp_index += 1) {
        var utf8_buf: [4]u8 = undefined;
        const encoded_len = encodeCodepointInto(cps[cp_index], &utf8_buf) orelse continue;
        if (len.* + encoded_len > out.len) return;
        fastmem.copy(u8, out[len.* .. len.* + encoded_len], utf8_buf[0..encoded_len]);
        len.* += encoded_len;
    }
}

pub fn appendGridRefText(runtime: *ghostty.Runtime, ref: *const ghostty.GridRef, raw_cell: u64, out: []u8, len: *usize) void {
    if (len.* >= out.len) return;
    var cps: [16]u32 = [_]u32{0} ** 16;
    const grapheme_len = @min(runtime.gridRefGraphemesInto(ref, cps[0..]) orelse 0, cps.len);
    if (grapheme_len == 0) {
        if (!runtime.cellHasText(raw_cell)) {
            out[len.*] = ' ';
            len.* += 1;
            return;
        }
        const cp = runtime.cellCodepoint(raw_cell);
        var utf8_buf: [4]u8 = undefined;
        const encoded_len = encodeCodepointInto(cp, &utf8_buf) orelse return;
        if (len.* + encoded_len > out.len) return;
        fastmem.copy(u8, out[len.* .. len.* + encoded_len], utf8_buf[0..encoded_len]);
        len.* += encoded_len;
        return;
    }

    var cp_index: usize = 0;
    while (cp_index < grapheme_len and cps[cp_index] != 0) : (cp_index += 1) {
        var utf8_buf: [4]u8 = undefined;
        const encoded_len = encodeCodepointInto(cps[cp_index], &utf8_buf) orelse continue;
        if (len.* + encoded_len > out.len) return;
        fastmem.copy(u8, out[len.* .. len.* + encoded_len], utf8_buf[0..encoded_len]);
        len.* += encoded_len;
    }
}

pub fn captureCopyModeCellText(allocator: std.mem.Allocator, runtime: *ghostty.Runtime, row_cells: ?*anyopaque) ![]u8 {
    var buf: [32]u8 = undefined;
    var len: usize = 0;
    appendCellText(runtime, row_cells, &buf, &len);
    return try allocator.dupe(u8, buf[0..len]);
}

pub fn appendCopyModeCellBytes(out: []u8, len: *usize, cell_text: []const u8) void {
    if (cell_text.len == 0) return;
    if (len.* + cell_text.len > out.len) return;
    fastmem.copy(u8, out[len.* .. len.* + cell_text.len], cell_text);
    len.* += cell_text.len;
}

pub fn encodeCodepointInto(codepoint: u32, buf: *[4]u8) ?usize {
    if (codepoint == 0) return null;
    if (codepoint < 0x80) {
        buf[0] = @intCast(codepoint);
        return 1;
    }
    if (codepoint < 0x800) {
        buf[0] = @intCast(0xC0 | (codepoint >> 6));
        buf[1] = @intCast(0x80 | (codepoint & 0x3F));
        return 2;
    }
    if (codepoint < 0x10000) {
        buf[0] = @intCast(0xE0 | (codepoint >> 12));
        buf[1] = @intCast(0x80 | ((codepoint >> 6) & 0x3F));
        buf[2] = @intCast(0x80 | (codepoint & 0x3F));
        return 3;
    }
    buf[0] = @intCast(0xF0 | (codepoint >> 18));
    buf[1] = @intCast(0x80 | ((codepoint >> 12) & 0x3F));
    buf[2] = @intCast(0x80 | ((codepoint >> 6) & 0x3F));
    buf[3] = @intCast(0x80 | (codepoint & 0x3F));
    return 4;
}

pub fn legacyPrintableKeyText(key: ghostty.Key, mods: u32, out: *[4]u8) ?[]const u8 {
    const shift = (mods & ghostty.Mods.shift) != 0;
    const ch: u8 = switch (key) {
        .a => if (shift) 'A' else 'a',
        .b => if (shift) 'B' else 'b',
        .c => if (shift) 'C' else 'c',
        .d => if (shift) 'D' else 'd',
        .e => if (shift) 'E' else 'e',
        .f => if (shift) 'F' else 'f',
        .g => if (shift) 'G' else 'g',
        .h => if (shift) 'H' else 'h',
        .i => if (shift) 'I' else 'i',
        .j => if (shift) 'J' else 'j',
        .k => if (shift) 'K' else 'k',
        .l => if (shift) 'L' else 'l',
        .m => if (shift) 'M' else 'm',
        .n => if (shift) 'N' else 'n',
        .o => if (shift) 'O' else 'o',
        .p => if (shift) 'P' else 'p',
        .q => if (shift) 'Q' else 'q',
        .r => if (shift) 'R' else 'r',
        .s => if (shift) 'S' else 's',
        .t => if (shift) 'T' else 't',
        .u => if (shift) 'U' else 'u',
        .v => if (shift) 'V' else 'v',
        .w => if (shift) 'W' else 'w',
        .x => if (shift) 'X' else 'x',
        .y => if (shift) 'Y' else 'y',
        .z => if (shift) 'Z' else 'z',
        .digit_0 => if (shift) ')' else '0',
        .digit_1 => if (shift) '!' else '1',
        .digit_2 => if (shift) '@' else '2',
        .digit_3 => if (shift) '#' else '3',
        .digit_4 => if (shift) '$' else '4',
        .digit_5 => if (shift) '%' else '5',
        .digit_6 => if (shift) '^' else '6',
        .digit_7 => if (shift) '&' else '7',
        .digit_8 => if (shift) '*' else '8',
        .digit_9 => if (shift) '(' else '9',
        .space => ' ',
        .tab => if (shift) return null else '\t',
        .enter => '\r',
        .backspace => 0x7f,
        .minus => if (shift) '_' else '-',
        .equal => if (shift) '+' else '=',
        .bracket_left => if (shift) '{' else '[',
        .bracket_right => if (shift) '}' else ']',
        .backslash => if (shift) '|' else '\\',
        .semicolon => if (shift) ':' else ';',
        .quote => if (shift) '"' else '\'',
        .backquote => if (shift) '~' else '`',
        .comma => if (shift) '<' else ',',
        .period => if (shift) '>' else '.',
        .slash => if (shift) '?' else '/',
        else => return null,
    };
    out[0] = ch;
    return out[0..1];
}

test "app helpers count utf8 codepoints by leading byte" {
    try std.testing.expectEqual(@as(usize, 0), countUtf8Codepoints(""));
    try std.testing.expectEqual(@as(usize, 5), countUtf8Codepoints("hello"));
    try std.testing.expectEqual(@as(usize, 3), countUtf8Codepoints("A\xc3\xa9\xe2\x82\xac"));
    try std.testing.expectEqual(@as(usize, 1), countUtf8Codepoints("\xf0\x9f\x98\x80"));
    try std.testing.expectEqual(@as(usize, 1), countUtf8Codepoints("\xe2\x82"));
}

test "titleCString truncates and null terminates window titles" {
    var input: [300]u8 = undefined;
    @memset(&input, 'x');

    const title = titleCString(input[0..]);

    try std.testing.expectEqual(@as(u8, 'x'), title[0]);
    try std.testing.expectEqual(@as(u8, 'x'), title[254]);
    try std.testing.expectEqual(@as(u8, 0), title[255]);
}

test "firstCodepoint handles ascii utf8 and invalid prefixes" {
    try std.testing.expectEqual(@as(u32, 0), firstCodepoint(""));
    try std.testing.expectEqual(@as(u32, 'A'), firstCodepoint("ABC"));
    try std.testing.expectEqual(@as(u32, 0x20AC), firstCodepoint("\xe2\x82\xac rest"));
    try std.testing.expectEqual(@as(u32, 0xF0), firstCodepoint("\xf0\x9f"));
    try std.testing.expectEqual(@as(u32, 0xFF), firstCodepoint("\xffbad"));
}

test "encodeCodepointInto emits utf8 byte sequences" {
    var buf: [4]u8 = undefined;

    try std.testing.expectEqual(@as(?usize, null), encodeCodepointInto(0, &buf));
    try std.testing.expectEqual(@as(?usize, 1), encodeCodepointInto('A', &buf));
    try std.testing.expectEqualStrings("A", buf[0..1]);

    try std.testing.expectEqual(@as(?usize, 2), encodeCodepointInto(0x00E9, &buf));
    try std.testing.expectEqualSlices(u8, "\xc3\xa9", buf[0..2]);

    try std.testing.expectEqual(@as(?usize, 3), encodeCodepointInto(0x20AC, &buf));
    try std.testing.expectEqualSlices(u8, "\xe2\x82\xac", buf[0..3]);

    try std.testing.expectEqual(@as(?usize, 4), encodeCodepointInto(0x1F600, &buf));
    try std.testing.expectEqualSlices(u8, "\xf0\x9f\x98\x80", buf[0..4]);
}

test "legacyPrintableKeyText maps printable keys and shifted symbols" {
    var out: [4]u8 = undefined;

    try std.testing.expectEqualStrings("a", legacyPrintableKeyText(.a, 0, &out).?);
    try std.testing.expectEqualStrings("A", legacyPrintableKeyText(.a, ghostty.Mods.shift, &out).?);
    try std.testing.expectEqualStrings("1", legacyPrintableKeyText(.digit_1, 0, &out).?);
    try std.testing.expectEqualStrings("!", legacyPrintableKeyText(.digit_1, ghostty.Mods.shift, &out).?);
    try std.testing.expectEqualStrings("/", legacyPrintableKeyText(.slash, 0, &out).?);
    try std.testing.expectEqualStrings("?", legacyPrintableKeyText(.slash, ghostty.Mods.shift, &out).?);
    try std.testing.expectEqualStrings("\r", legacyPrintableKeyText(.enter, 0, &out).?);
    try std.testing.expectEqualStrings("\x7f", legacyPrintableKeyText(.backspace, 0, &out).?);
    try std.testing.expectEqual(@as(?[]const u8, null), legacyPrintableKeyText(.tab, ghostty.Mods.shift, &out));
    try std.testing.expectEqual(@as(?[]const u8, null), legacyPrintableKeyText(.escape, 0, &out));
}
