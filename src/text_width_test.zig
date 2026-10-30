//! Headless integration contract: Clay and renderer/Lua width helpers agree.
const std = @import("std");
const c = @import("clay_c");
const text_width = @import("text_width.zig");

test "Clay text measurement uses shared grapheme columns" {
    const surface = c.hollow_clay_create() orelse return error.OutOfMemory;
    defer c.hollow_clay_destroy(surface);
    for ([_][]const u8{ "中文", "e\u{301}", "😀", "👨\u{200D}👩\u{200D}👧", "❤\u{FE0F}" }) |text| {
        var nodes = std.mem.zeroes([2]c.HollowClayNode);
        nodes[0].kind = 1;
        nodes[0].width = -1;
        nodes[0].height = -1;
        nodes[0].children = 1;
        nodes[1].kind = 2;
        nodes[1].wrap = 2;
        nodes[1].fg = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
        nodes[1].text = .{ .chars = text.ptr, .length = @intCast(text.len), .isStaticallyAllocated = false };
        const commands = c.hollow_clay_layout(surface, &nodes, nodes.len, 800, 100, 8, 16, 0, 0, 0, 1.0 / 60.0);
        try std.testing.expect(!c.hollow_clay_failed(surface));
        var found = false;
        for (commands.internalArray[0..@intCast(commands.length)]) |command| {
            if (command.commandType != c.CLAY_RENDER_COMMAND_TYPE_TEXT) continue;
            try std.testing.expectEqual(@as(f32, @floatFromInt(text_width.width(text))) * 8, command.boundingBox.width);
            found = true;
        }
        try std.testing.expect(found);
    }
}

test {
    _ = text_width;
}
