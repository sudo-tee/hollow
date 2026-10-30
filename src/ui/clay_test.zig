const std = @import("std");
const c = @import("clay_c");

test "Clay workspace windows retire disjoint clipped columns within scroll capacity" {
    const surface = c.hollow_clay_create() orelse return error.OutOfMemory;
    defer c.hollow_clay_destroy(surface);
    var nodes: [5 + 23 * 5]c.HollowClayNode = undefined;
    var ids: [46][40]u8 = undefined;
    for (0..5) |i| {
        nodes[i] = node(0, -1, -1, if (i == 4) 23 else 1);
        nodes[i].scroll = true;
    }
    // Jump between entirely disjoint windows on consecutive frames. Clay keeps
    // the previous window's scroll records until its next update.
    for (0..12) |frame| {
        for (0..23) |row| {
            const base = 5 + row * 5;
            nodes[base] = node(1, -1, 23, 2);
            inline for (0..2) |col| {
                const index = base + 1 + col * 2;
                nodes[index] = node(1, if (col == 0) 192 else -1, 19, 1);
                nodes[index].scroll_x = true;
                const id = try std.fmt.bufPrint(&ids[row * 2 + col], "workspace:{d}:column:{d}", .{ frame * 23 + row, col });
                nodes[index].id = .{ .chars = id.ptr, .length = @intCast(id.len), .isStaticallyAllocated = false };
                nodes[index + 1] = node(2, 0, 0, 0);
                nodes[index + 1].text = .{ .chars = "workspace column", .length = 16, .isStaticallyAllocated = true };
                nodes[index + 1].wrap = 2;
            }
        }
        _ = layout(surface, &nodes, 800, 600, 0);
        try std.testing.expect(!c.hollow_clay_failed(surface));
    }
}

test "Clay flexible clipped label preserves fit right binding during resize" {
    const surface = c.hollow_clay_create() orelse return error.OutOfMemory;
    defer c.hollow_clay_destroy(surface);
    var nodes = [_]c.HollowClayNode{
        node(1, -1, 23, 2), node(1, -1, 23, 1), node(2, 0, 0, 0),
        node(1, 0, 23, 1),  node(2, 0, 0, 0),
    };
    nodes[1].scroll_x = true;
    const label = "a very long command label that must leave room for its binding";
    nodes[2].text = .{ .chars = label, .length = label.len, .isStaticallyAllocated = true };
    nodes[4].text = .{ .chars = "<C-a>", .length = 5, .isStaticallyAllocated = true };
    nodes[2].wrap = 2;
    nodes[4].wrap = 2;
    for ([_]f32{ 600, 200, 80, 400 }) |width| {
        _ = layout(surface, &nodes, width, 100, 0);
        try std.testing.expect(!c.hollow_clay_failed(surface));
        const left = c.hollow_clay_bounds(surface, &nodes, 1).boundingBox;
        const right = c.hollow_clay_bounds(surface, &nodes, 3).boundingBox;
        try std.testing.expectEqual(@as(f32, 40), right.width);
        try std.testing.expectApproxEqAbs(width, right.x + right.width, 0.02);
        try std.testing.expect(left.x + left.width <= right.x + 0.02);
    }
}

fn node(kind: c_int, width: f32, height: f32, children: c_int) c.HollowClayNode {
    var n = std.mem.zeroes(c.HollowClayNode);
    n.kind = kind;
    n.width = width;
    n.height = height;
    n.children = children;
    n.bg = .{ .r = 20, .g = 30, .b = 40, .a = 255 };
    return n;
}

fn layout(surface: *c.HollowClay, nodes: []c.HollowClayNode, width: f32, height: f32, scroll: f32) c.Clay_RenderCommandArray {
    return c.hollow_clay_layout(surface, nodes.ptr, @intCast(nodes.len), width, height, 8, 16, 150, 50, scroll, 1.0 / 60.0);
}

test "rectangle commands retain explicit full bleed node and padded geometry" {
    const surface = c.hollow_clay_create() orelse return error.OutOfMemory;
    defer c.hollow_clay_destroy(surface);
    var nodes = [_]c.HollowClayNode{ node(0, -1, -1, 2), node(0, -1, 1, 0), node(0, -1, 1, 0) };
    nodes[0].padding.left = 12;
    nodes[0].padding.right = 12;
    nodes[1].full_bleed_x = true;
    const commands = layout(surface, &nodes, 200, 100, 0);
    var found: usize = 0;
    for (commands.internalArray[0..@intCast(commands.length)]) |command| {
        if (command.commandType != c.CLAY_RENDER_COMMAND_TYPE_RECTANGLE) continue;
        const payload: *const c.HollowClayNode = @ptrCast(@alignCast(command.userData orelse continue));
        if (payload == &nodes[1] or payload == &nodes[2]) {
            try std.testing.expectEqual(@as(f32, 12), command.boundingBox.x);
            try std.testing.expectEqual(@as(f32, 176), command.boundingBox.width);
            try std.testing.expectEqual(payload == &nodes[1], payload.full_bleed_x);
            found += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), found);
}

test "full bleed paint is opt-in for framed overlays only" {
    const paint = @import("clay_paint.zig");
    const bounds = c.Clay_BoundingBox{ .x = 32, .y = 40, .width = 76, .height = 1 };
    const panel = c.Clay_BoundingBox{ .x = 20, .y = 10, .width = 100, .height = 80 };
    const expanded = paint.rectangleBounds(bounds, panel, 1, 1, true, true);
    try std.testing.expectEqual(@as(f32, 21), expanded.x);
    try std.testing.expectEqual(@as(f32, 98), expanded.width);
    try std.testing.expectEqual(bounds.y, expanded.y);
    try std.testing.expectEqual(bounds.height, expanded.height);
    try std.testing.expectEqualDeep(bounds, paint.rectangleBounds(bounds, panel, 1, 0, true, true));
    try std.testing.expectEqualDeep(bounds, paint.rectangleBounds(bounds, panel, 1, 1, false, true));
    try std.testing.expectEqualDeep(bounds, paint.rectangleBounds(bounds, panel, 1, 1, true, false));
}

test "Clay preserves nested rows and columns and reallocates grow space" {
    const surface = c.hollow_clay_create() orelse return error.OutOfMemory;
    defer c.hollow_clay_destroy(surface);
    var nodes = [_]c.HollowClayNode{
        node(1, -1, -1, 2),
        node(0, 100, -1, 0),
        node(0, -1, -1, 1),
        node(3, -1, 20, 0),
    };
    nodes[3].value = 0.5;
    var commands = layout(surface, &nodes, 400, 300, 0);
    try std.testing.expect(!c.hollow_clay_failed(surface));
    var found = false;
    for (commands.internalArray[0..@intCast(commands.length)]) |command| {
        if (command.commandType == c.CLAY_RENDER_COMMAND_TYPE_CUSTOM) {
            try std.testing.expectEqual(@as(f32, 100), command.boundingBox.x);
            try std.testing.expectEqual(@as(f32, 300), command.boundingBox.width);
            const payload: *const c.HollowClayNode = @ptrCast(@alignCast(command.renderData.custom.customData.?));
            try std.testing.expectEqual(@as(f32, 0.5), payload.value);
            found = true;
        }
    }
    try std.testing.expect(found);
    commands = layout(surface, &nodes, 600, 300, 0);
    for (commands.internalArray[0..@intCast(commands.length)]) |command| {
        if (command.commandType == c.CLAY_RENDER_COMMAND_TYPE_CUSTOM) try std.testing.expectEqual(@as(f32, 500), command.boundingBox.width);
    }
}

test "Clay scroll containers clip and hit test visible children" {
    const surface = c.hollow_clay_create() orelse return error.OutOfMemory;
    defer c.hollow_clay_destroy(surface);
    var nodes = [_]c.HollowClayNode{ node(0, -1, -1, 1), node(0, -1, -1, 3), node(0, -1, 80, 0), node(0, -1, 80, 0), node(0, -1, 80, 0) };
    nodes[1].scroll = true;
    nodes[2].clickable = true;
    nodes[4].clickable = true;
    const commands = layout(surface, &nodes, 300, 100, 0);
    try std.testing.expect(!c.hollow_clay_failed(surface));
    var clips: usize = 0;
    for (commands.internalArray[0..@intCast(commands.length)]) |command| {
        if (command.commandType == c.CLAY_RENDER_COMMAND_TYPE_SCISSOR_START) clips += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), clips);
    try std.testing.expectEqual(@as(c_int, 2), c.hollow_clay_hit(surface, &nodes, nodes.len, 150, 50));
    try std.testing.expectEqual(@as(c_int, -1), c.hollow_clay_hit(surface, &nodes, nodes.len, 150, 170));
    _ = layout(surface, &nodes, 300, 100, -10);
    try std.testing.expect(!c.hollow_clay_failed(surface));
    try std.testing.expectEqual(@as(c_int, 4), c.hollow_clay_hit(surface, &nodes, nodes.len, 150, 70));
}

test "Clay pointer queries select deepest clickable node at arbitrary event coordinates" {
    const surface = c.hollow_clay_create() orelse return error.OutOfMemory;
    defer c.hollow_clay_destroy(surface);
    var nodes = [_]c.HollowClayNode{
        node(0, -1, -1, 2), node(0, -1, 40, 1),
        node(0, 80, 60, 0), node(0, -1, 40, 0),
    };
    for (&nodes) |*n| n.clickable = true;
    // First layout has no previous geometry. Events need not share the layout's
    // pointer position, and repeated queries must not leave stale overlaps.
    _ = layout(surface, &nodes, 200, 100, 0);
    try std.testing.expectEqual(@as(c_int, 2), c.hollow_clay_hit(surface, &nodes, nodes.len, 10, 10));
    try std.testing.expectEqual(@as(c_int, 1), c.hollow_clay_hit(surface, &nodes, nodes.len, 100, 10));
    // Overflowing child overlaps the later sibling: paint order wins, not depth.
    try std.testing.expectEqual(@as(c_int, 3), c.hollow_clay_hit(surface, &nodes, nodes.len, 10, 50));
    try std.testing.expectEqual(@as(c_int, -1), c.hollow_clay_hit(surface, &nodes, nodes.len, -1, -1));
    nodes[2].clickable = false;
    try std.testing.expectEqual(@as(c_int, 1), c.hollow_clay_hit(surface, &nodes, nodes.len, 10, 10));
    // Layout rebuild/resize updates overlap geometry immediately.
    _ = layout(surface, &nodes, 50, 100, 0);
    try std.testing.expectEqual(@as(c_int, -1), c.hollow_clay_hit(surface, &nodes, nodes.len, 100, 10));
}

test "Clay pointer queries switch surface context and restore the caller context" {
    const first = c.hollow_clay_create() orelse return error.OutOfMemory;
    defer c.hollow_clay_destroy(first);
    const second = c.hollow_clay_create() orelse return error.OutOfMemory;
    defer c.hollow_clay_destroy(second);
    var first_nodes = [_]c.HollowClayNode{node(0, -1, -1, 0)};
    var second_nodes = [_]c.HollowClayNode{node(0, -1, -1, 0)};
    first_nodes[0].clickable = true;
    second_nodes[0].clickable = true;
    _ = layout(first, &first_nodes, 100, 100, 0);
    _ = layout(second, &second_nodes, 300, 100, 0);
    const previous = c.Clay_GetCurrentContext();
    try std.testing.expectEqual(@as(c_int, -1), c.hollow_clay_hit(first, &first_nodes, first_nodes.len, 200, 50));
    try std.testing.expectEqual(previous, c.Clay_GetCurrentContext());
    try std.testing.expectEqual(@as(c_int, 0), c.hollow_clay_hit(second, &second_nodes, second_nodes.len, 200, 50));
    c.Clay_SetCurrentContext(null);
    try std.testing.expectEqual(@as(c_int, 0), c.hollow_clay_hit(first, &first_nodes, first_nodes.len, 50, 50));
    try std.testing.expect(c.Clay_GetCurrentContext() == null);
}

test "Clay inspector floating capture prevents clicks through to ordinary nodes" {
    const surface = c.hollow_clay_create() orelse return error.OutOfMemory;
    defer c.hollow_clay_destroy(surface);
    // Fixed width deliberately extends under the floating inspector panel.
    var nodes = [_]c.HollowClayNode{node(0, 1200, 800, 0)};
    nodes[0].clickable = true;
    c.hollow_clay_set_debug(surface, true);
    _ = layout(surface, &nodes, 1200, 800, 0);
    try std.testing.expect(!c.hollow_clay_failed(surface));
    const bounds = c.hollow_clay_visible_bounds(surface, &nodes, nodes.len, 0);
    try std.testing.expect(bounds.found and bounds.boundingBox.width == 1200);
    try std.testing.expectEqual(@as(c_int, 0), c.hollow_clay_hit(surface, &nodes, nodes.len, 100, 100));
    try std.testing.expectEqual(@as(c_int, -1), c.hollow_clay_hit(surface, &nodes, nodes.len, 1100, 100));
}

test "Clay empty and rejected layouts never return stale pointer hits" {
    const surface = c.hollow_clay_create() orelse return error.OutOfMemory;
    defer c.hollow_clay_destroy(surface);
    var nodes = [_]c.HollowClayNode{node(0, -1, -1, 0)};
    nodes[0].clickable = true;
    try std.testing.expectEqual(@as(c_int, -1), c.hollow_clay_hit(surface, &nodes, nodes.len, 10, 10));
    _ = layout(surface, &nodes, 100, 100, 0);
    try std.testing.expectEqual(@as(c_int, 0), c.hollow_clay_hit(surface, &nodes, nodes.len, 10, 10));
    _ = layout(surface, nodes[0..0], 100, 100, 0);
    try std.testing.expectEqual(@as(c_int, -1), c.hollow_clay_hit(surface, &nodes, nodes.len, 10, 10));
    _ = layout(surface, &nodes, 100, 100, 0);
    _ = c.hollow_clay_layout(surface, &nodes, c.HOLLOW_CLAY_MAX_NODES + 1, 100, 100, 8, 16, 10, 10, 0, 0);
    try std.testing.expect(c.hollow_clay_failed(surface));
    try std.testing.expectEqual(@as(c_int, -1), c.hollow_clay_hit(surface, &nodes, nodes.len, 10, 10));
}

test "Clay wraps text using Hollow cell metrics and resets measurement cache" {
    const surface = c.hollow_clay_create() orelse return error.OutOfMemory;
    defer c.hollow_clay_destroy(surface);
    var nodes = [_]c.HollowClayNode{ node(0, -1, -1, 1), node(2, 0, 0, 0) };
    nodes[1].text = .{ .chars = "hello world", .length = 11, .isStaticallyAllocated = true };
    var commands = layout(surface, &nodes, 60, 100, 0);
    var lines: usize = 0;
    for (commands.internalArray[0..@intCast(commands.length)]) |command| {
        if (command.commandType == c.CLAY_RENDER_COMMAND_TYPE_TEXT) {
            try std.testing.expect(command.boundingBox.width <= 60);
            lines += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), lines);
    commands = c.hollow_clay_layout(surface, &nodes, nodes.len, 60, 100, 4, 16, -1, -1, 0, 1.0 / 60.0);
    lines = 0;
    for (commands.internalArray[0..@intCast(commands.length)]) |command| {
        if (command.commandType == c.CLAY_RENDER_COMMAND_TYPE_TEXT) lines += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), lines);
    try std.testing.expect(!c.hollow_clay_failed(surface));
}

test "Clay per-side border widths replace uniform fallback including zero sides" {
    const surface = c.hollow_clay_create() orelse return error.OutOfMemory;
    defer c.hollow_clay_destroy(surface);
    var nodes = [_]c.HollowClayNode{node(0, -1, -1, 0)};
    nodes[0].border = .{ .r = 1, .g = 2, .b = 3, .a = 255 };
    nodes[0].border_size = 9;
    nodes[0].border_width_set = true;
    nodes[0].border_width = .{ .left = 3, .right = 0, .top = 1, .bottom = 2, .betweenChildren = 0 };
    var commands = layout(surface, &nodes, 200, 100, 0);
    var found = false;
    for (commands.internalArray[0..@intCast(commands.length)]) |command| {
        if (command.commandType != c.CLAY_RENDER_COMMAND_TYPE_BORDER) continue;
        try std.testing.expectEqualDeep(nodes[0].border_width, command.renderData.border.width);
        found = true;
    }
    try std.testing.expect(found);
    nodes[0].border_width_set = false;
    commands = layout(surface, &nodes, 200, 100, 0);
    found = false;
    for (commands.internalArray[0..@intCast(commands.length)]) |command| {
        if (command.commandType != c.CLAY_RENDER_COMMAND_TYPE_BORDER) continue;
        try std.testing.expectEqual(@as(u16, 9), command.renderData.border.width.left);
        try std.testing.expectEqual(@as(u16, 9), command.renderData.border.width.right);
        found = true;
    }
    try std.testing.expect(found);
}

test "Clay between-children borders emit divider rectangles in both directions" {
    const surface = c.hollow_clay_create() orelse return error.OutOfMemory;
    defer c.hollow_clay_destroy(surface);
    var nodes = [_]c.HollowClayNode{ node(0, -1, -1, 3), node(0, 20, 20, 0), node(0, 20, 20, 0), node(0, 20, 20, 0) };
    nodes[0].gap = 6;
    nodes[0].border = .{ .r = 200, .g = 100, .b = 50, .a = 255 };
    nodes[0].border_width_set = true;
    nodes[0].border_width.betweenChildren = 2;
    for ([_]c_int{ 0, 1 }) |kind| {
        nodes[0].kind = kind;
        const commands = layout(surface, &nodes, 200, 100, 0);
        var dividers: usize = 0;
        for (commands.internalArray[0..@intCast(commands.length)]) |command| {
            if (command.commandType != c.CLAY_RENDER_COMMAND_TYPE_RECTANGLE or command.renderData.rectangle.backgroundColor.r != 200) continue;
            try std.testing.expectEqual(@as(f32, 2), if (kind == 0) command.boundingBox.height else command.boundingBox.width);
            try std.testing.expectEqual(if (kind == 0) @as(f32, 200) else @as(f32, 100), if (kind == 0) command.boundingBox.width else command.boundingBox.height);
            dividers += 1;
        }
        try std.testing.expectEqual(@as(usize, 2), dividers);
        try std.testing.expect(!c.hollow_clay_failed(surface));
    }
}

test "Clay text alignment positions shorter wrapped lines within their text box" {
    const surface = c.hollow_clay_create() orelse return error.OutOfMemory;
    defer c.hollow_clay_destroy(surface);
    var nodes = [_]c.HollowClayNode{ node(0, 64, 100, 1), node(2, 0, 0, 0) };
    const text = "abcdefgh x";
    nodes[1].text = .{ .chars = text, .length = text.len, .isStaticallyAllocated = true };
    for ([_]f32{ 0, 28, 56 }, 0..) |expected_x, alignment| {
        nodes[1].text_align = @intCast(alignment);
        const commands = layout(surface, &nodes, 200, 100, 0);
        var lines: usize = 0;
        for (commands.internalArray[0..@intCast(commands.length)]) |command| {
            if (command.commandType != c.CLAY_RENDER_COMMAND_TYPE_TEXT) continue;
            if (command.renderData.text.stringContents.length == 1) {
                try std.testing.expectEqual(expected_x, command.boundingBox.x);
            }
            lines += 1;
        }
        try std.testing.expectEqual(@as(usize, 2), lines);
    }
}

test "Clay FIT and GROW constraints bound dimensions while FIXED stays authoritative" {
    const surface = c.hollow_clay_create() orelse return error.OutOfMemory;
    defer c.hollow_clay_destroy(surface);
    var nodes = [_]c.HollowClayNode{ node(0, -1, -1, 1), node(0, 0, 0, 0) };
    nodes[1].min_width = 80;
    nodes[1].max_width = 120;
    nodes[1].min_height = 30;
    nodes[1].max_height = 60;
    _ = layout(surface, &nodes, 200, 100, 0);
    var bounds = c.hollow_clay_bounds(surface, &nodes, 1).boundingBox;
    try std.testing.expectEqual(@as(f32, 80), bounds.width);
    try std.testing.expectEqual(@as(f32, 30), bounds.height);
    nodes[1].width = -1;
    nodes[1].height = -1;
    _ = layout(surface, &nodes, 200, 100, 0);
    bounds = c.hollow_clay_bounds(surface, &nodes, 1).boundingBox;
    try std.testing.expectEqual(@as(f32, 120), bounds.width);
    try std.testing.expectEqual(@as(f32, 60), bounds.height);
    nodes[1].width = 150;
    nodes[1].height = 70;
    _ = layout(surface, &nodes, 200, 100, 0);
    bounds = c.hollow_clay_bounds(surface, &nodes, 1).boundingBox;
    try std.testing.expectEqual(@as(f32, 150), bounds.width);
    try std.testing.expectEqual(@as(f32, 70), bounds.height);
}

test "Clay FIT frame constraints respect host size and frame maximum height" {
    const surface = c.hollow_clay_create() orelse return error.OutOfMemory;
    defer c.hollow_clay_destroy(surface);
    var nodes = [_]c.HollowClayNode{ node(0, 0, 0, 1), node(0, 0, 0, 0) };
    nodes[0].min_width = 80;
    nodes[0].max_width = 120;
    nodes[0].min_height = 80;
    nodes[0].max_height = 200;
    nodes[1].min_height = 150;
    var frame: c.HollowClayFrame = std.mem.zeroes(c.HollowClayFrame);
    frame.enabled = true;
    frame.max_height = 100;
    frame.margin = .{ .left = 10, .right = 10, .top = 10, .bottom = 10 };
    c.hollow_clay_frame(surface, frame);
    _ = layout(surface, &nodes, 200, 300, 0);
    var bounds = c.hollow_clay_bounds(surface, &nodes, 0).boundingBox;
    try std.testing.expectEqual(@as(f32, 80), bounds.width);
    try std.testing.expectEqual(@as(f32, 100), bounds.height);
    _ = layout(surface, &nodes, 70, 70, 0);
    bounds = c.hollow_clay_bounds(surface, &nodes, 0).boundingBox;
    try std.testing.expectEqual(@as(f32, 50), bounds.width);
    try std.testing.expectEqual(@as(f32, 50), bounds.height);
    // Explicit frame height is also bounded by max_height, not node limits.
    frame.height = 250;
    c.hollow_clay_frame(surface, frame);
    _ = layout(surface, &nodes, 200, 300, 0);
    try std.testing.expectEqual(@as(f32, 100), c.hollow_clay_bounds(surface, &nodes, 0).boundingBox.height);
    try std.testing.expect(!c.hollow_clay_failed(surface));
}

test "Clay contexts can be switched and destroyed independently" {
    const first = c.hollow_clay_create() orelse return error.OutOfMemory;
    defer c.hollow_clay_destroy(first);
    const second = c.hollow_clay_create() orelse return error.OutOfMemory;
    var nodes = [_]c.HollowClayNode{node(0, -1, -1, 0)};
    _ = layout(first, &nodes, 200, 100, 0);
    _ = layout(second, &nodes, 400, 100, 0);
    c.hollow_clay_destroy(second);
    const commands = layout(first, &nodes, 200, 100, 0);
    try std.testing.expect(!c.hollow_clay_failed(first));
    try std.testing.expectEqual(@as(f32, 200), commands.internalArray[0].boundingBox.width);
}

test "Clay overlay frame owns alignment and clamps the panel to its host" {
    const surface = c.hollow_clay_create() orelse return error.OutOfMemory;
    defer c.hollow_clay_destroy(surface);
    var nodes = [_]c.HollowClayNode{ node(0, 0, 0, 1), node(3, -1, 40, 0) };
    c.hollow_clay_frame(surface, .{
        .enabled = true,
        .width = 200,
        .height = 60,
        .margin = .{ .left = 10, .right = 10, .top = 10, .bottom = 10 },
        .align_x = 2,
        .align_y = 2,
    });
    _ = layout(surface, &nodes, 400, 300, 0);
    try std.testing.expect(!c.hollow_clay_failed(surface));
    var panel = c.hollow_clay_bounds(surface, &nodes, 0);
    try std.testing.expect(panel.found);
    try std.testing.expectEqual(@as(f32, 190), panel.boundingBox.x);
    try std.testing.expectEqual(@as(f32, 230), panel.boundingBox.y);
    _ = layout(surface, &nodes, 120, 100, 0);
    panel = c.hollow_clay_bounds(surface, &nodes, 0);
    try std.testing.expectEqual(@as(f32, 100), panel.boundingBox.width);
    try std.testing.expectEqual(@as(f32, 10), panel.boundingBox.x);
    try std.testing.expect(!c.hollow_clay_failed(surface));
    c.hollow_clay_frame(surface, .{
        .enabled = true,
        .width = 200,
        .height = 60,
        .margin = .{ .left = 10, .right = 10, .top = 10, .bottom = 10 },
        .align_x = 1,
        .align_y = 1,
    });
    _ = layout(surface, &nodes, 400, 300, 0);
    panel = c.hollow_clay_bounds(surface, &nodes, 0);
    try std.testing.expectEqual(@as(f32, 100), panel.boundingBox.x);
    try std.testing.expectEqual(@as(f32, 120), panel.boundingBox.y);
}

test "Clay confirmation wraps its prompt and keeps both footer buttons inside the panel" {
    const surface = c.hollow_clay_create() orelse return error.OutOfMemory;
    defer c.hollow_clay_destroy(surface);
    var nodes = [_]c.HollowClayNode{
        node(0, 0, 0, 1), // Panel, fit height inside the host frame.
        node(0, -1, 0, 5), // Dialog content.
        node(2, 0, 0, 0), // Title.
        node(0, -1, 1, 0), // Divider.
        node(2, 0, 0, 0), // Wrapped prompt.
        node(0, 0, 19, 0), // Footer separation.
        node(1, -1, 0, 3), // Footer: spacer, keep, delete.
        node(0, -1, 0, 0),
        node(0, 0, 0, 1),
        node(2, 0, 0, 0),
        node(0, 0, 0, 1),
        node(2, 0, 0, 0),
    };
    const prompt = "This is the existing confirmation dialog using Clay geometry. Tab or arrow keys change the selected action. Enter confirms; Escape cancels. The same callbacks and overlay shell are retained.";
    nodes[0].padding = .{ .left = 4, .right = 4, .top = 19, .bottom = 9 };
    nodes[2].text = .{ .chars = "Delete archived tasks?", .length = 22, .isStaticallyAllocated = true };
    nodes[4].text = .{ .chars = prompt, .length = prompt.len, .isStaticallyAllocated = true };
    nodes[6].gap = 16;
    nodes[8].padding = .{ .left = 8, .right = 8, .top = 0, .bottom = 0 };
    nodes[8].clickable = true;
    nodes[9].text = .{ .chars = "Keep tasks", .length = 10, .isStaticallyAllocated = true };
    nodes[10].padding = nodes[8].padding;
    nodes[10].clickable = true;
    nodes[11].text = .{ .chars = "Delete tasks", .length = 12, .isStaticallyAllocated = true };
    c.hollow_clay_frame(surface, .{
        .enabled = true,
        .width = 520,
        .height = 0,
        .margin = .{ .left = 8, .right = 8, .top = 19, .bottom = 19 },
        .align_x = 1,
        .align_y = 1,
    });
    for ([_]f32{ 1100, 440, 320 }) |width| {
        const commands = c.hollow_clay_layout(surface, &nodes, nodes.len, width, 692, 8, 19, -1, -1, 0, 1.0 / 60.0);
        try std.testing.expect(!c.hollow_clay_failed(surface));
        const panel = c.hollow_clay_bounds(surface, &nodes, 0).boundingBox;
        var prompt_lines: usize = 0;
        var labels: usize = 0;
        for (commands.internalArray[0..@intCast(commands.length)]) |command| {
            if (command.commandType != c.CLAY_RENDER_COMMAND_TYPE_TEXT) continue;
            const text = command.renderData.text.stringContents;
            const b = command.boundingBox;
            try std.testing.expect(b.x >= panel.x);
            try std.testing.expect(b.x + b.width <= panel.x + panel.width);
            try std.testing.expect(b.y + b.height <= panel.y + panel.height);
            if (text.baseChars == prompt.ptr) prompt_lines += 1;
            const slice = text.chars[0..@intCast(text.length)];
            if (std.mem.eql(u8, slice, "Keep tasks") or std.mem.eql(u8, slice, "Delete tasks")) labels += 1;
        }
        try std.testing.expect(prompt_lines > 1);
        try std.testing.expectEqual(@as(usize, 2), labels);
        inline for (.{ 8, 10 }) |index| {
            const button = c.hollow_clay_bounds(surface, &nodes, index).boundingBox;
            try std.testing.expect(button.width > 0 and button.height > 0);
            try std.testing.expect(button.x + button.width <= panel.x + panel.width);
            try std.testing.expect(button.y + button.height <= panel.y + panel.height);
            try std.testing.expectEqual(@as(c_int, index), c.hollow_clay_hit(surface, &nodes, nodes.len, button.x + button.width / 2, button.y + button.height / 2));
        }
    }
}

test "Clay horizontal input viewport keeps an unwrapped caret visible while editing and resizing" {
    const surface = c.hollow_clay_create() orelse return error.OutOfMemory;
    defer c.hollow_clay_destroy(surface);
    var nodes = [_]c.HollowClayNode{
        node(1, -1, 19, 3),
        node(0, 0, 19, 1),
        node(2, 0, 0, 0),
        node(0, 0, 19, 1),
        node(2, 0, 0, 0),
        node(0, 0, 19, 1),
        node(2, 0, 0, 0),
    };
    nodes[0].id = .{ .chars = "field", .length = 5, .isStaticallyAllocated = true };
    nodes[0].scroll_x = true;
    nodes[0].reveal = .{ .chars = "caret", .length = 5, .isStaticallyAllocated = true };
    nodes[3].id = nodes[0].reveal;
    const long_text = "a long input with many words";
    nodes[2].text = .{ .chars = long_text, .length = long_text.len, .isStaticallyAllocated = true };
    nodes[4].text = .{ .chars = " ", .length = 1, .isStaticallyAllocated = true };
    inline for (.{ 2, 4, 6 }) |i| {
        nodes[i].wrap = 2;
    }
    for ([_]f32{ 100, 64, 140 }) |width| {
        const commands = c.hollow_clay_layout(surface, &nodes, nodes.len, width, 100, 8, 19, -1, -1, 0, 1.0 / 60.0);
        try std.testing.expect(!c.hollow_clay_failed(surface));
        const view = c.hollow_clay_bounds(surface, &nodes, 0).boundingBox;
        const caret = c.hollow_clay_bounds(surface, &nodes, 3).boundingBox;
        try std.testing.expect(caret.x >= view.x);
        try std.testing.expect(caret.x + caret.width <= view.x + view.width);
        var horizontal_clip = false;
        var before_lines: usize = 0;
        for (commands.internalArray[0..@intCast(commands.length)]) |command| {
            if (command.commandType == c.CLAY_RENDER_COMMAND_TYPE_SCISSOR_START) {
                horizontal_clip = command.renderData.clip.horizontal;
            }
            if (command.commandType == c.CLAY_RENDER_COMMAND_TYPE_TEXT and command.renderData.text.stringContents.baseChars == long_text.ptr) before_lines += 1;
        }
        try std.testing.expect(horizontal_clip);
        try std.testing.expectEqual(@as(usize, 1), before_lines);
        _ = c.hollow_clay_layout(surface, &nodes, nodes.len, width, 100, 8, 19, -1, -1, 0, 1.0 / 60.0);
        try std.testing.expectEqual(caret.x, c.hollow_clay_bounds(surface, &nodes, 3).boundingBox.x);
    }
    // Moving left to the beginning repositions the caret before the long suffix.
    nodes[6].text = nodes[2].text;
    nodes[2].text = .{ .chars = "", .length = 0, .isStaticallyAllocated = true };
    _ = c.hollow_clay_layout(surface, &nodes, nodes.len, 100, 100, 8, 19, -1, -1, 0, 1.0 / 60.0);
    try std.testing.expectEqual(@as(f32, 0), c.hollow_clay_bounds(surface, &nodes, 3).boundingBox.x);
    // Deleting the long content resets the old scroll offset as well.
    nodes[6].text = nodes[2].text;
    _ = c.hollow_clay_layout(surface, &nodes, nodes.len, 100, 100, 8, 19, -1, -1, 0, 1.0 / 60.0);
    try std.testing.expectEqual(@as(f32, 0), c.hollow_clay_bounds(surface, &nodes, 3).boundingBox.x);
    try std.testing.expect(!c.hollow_clay_failed(surface));
}

test "Clay framed input fits styled runs and caret within the dialog content" {
    const surface = c.hollow_clay_create() orelse return error.OutOfMemory;
    defer c.hollow_clay_destroy(surface);
    var nodes = [_]c.HollowClayNode{
        node(0, 0, 0, 1),  node(0, -1, 0, 3),
        node(2, 0, 0, 0),  node(0, -1, 1, 0),
        node(0, -1, 0, 1), node(1, -1, 19, 3),
        node(0, 0, 19, 1), node(2, 0, 0, 0),
        node(0, 0, 19, 1), node(2, 0, 0, 0),
        node(0, 0, 19, 1), node(2, 0, 0, 0),
    };
    nodes[0].padding = .{ .left = 4, .right = 4, .top = 19, .bottom = 9 };
    nodes[2].text = .{ .chars = "Rename workspace", .length = 16, .isStaticallyAllocated = true };
    nodes[4].padding = .{ .left = 4, .right = 4, .top = 2, .bottom = 2 };
    nodes[5].scroll_x = true;
    nodes[5].reveal = .{ .chars = "caret", .length = 5, .isStaticallyAllocated = true };
    nodes[8].id = nodes[5].reveal;
    const value = "a-workspace-name-long-enough-to-exercise-horizontal-scrolling-and-caret-reveal";
    nodes[7].text = .{ .chars = value, .length = value.len, .isStaticallyAllocated = true };
    nodes[9].text = .{ .chars = " ", .length = 1, .isStaticallyAllocated = true };
    nodes[9].bold = true;
    inline for (.{ 7, 9, 11 }) |i| nodes[i].wrap = 2;
    for ([_]f32{ 520, 0 }) |panel_width| {
        c.hollow_clay_frame(surface, .{
            .enabled = true,
            .width = panel_width,
            .height = 0,
            .margin = .{ .left = 8, .right = 8, .top = 19, .bottom = 19 },
            .align_x = 1,
            .align_y = 1,
        });
        for ([_]f32{ 1100, 320 }) |width| {
            _ = c.hollow_clay_layout(surface, &nodes, nodes.len, width, 692, 8, 19, -1, -1, 0, 1.0 / 60.0);
            try std.testing.expect(!c.hollow_clay_failed(surface));
            const panel = c.hollow_clay_bounds(surface, &nodes, 0).boundingBox;
            const viewport = c.hollow_clay_bounds(surface, &nodes, 5).boundingBox;
            const caret = c.hollow_clay_bounds(surface, &nodes, 8).boundingBox;
            try std.testing.expect(viewport.width > 0);
            try std.testing.expect(viewport.x >= panel.x);
            try std.testing.expect(viewport.x + viewport.width <= panel.x + panel.width);
            try std.testing.expect(caret.x >= viewport.x);
            try std.testing.expect(caret.x + caret.width <= viewport.x + viewport.width);
            try std.testing.expectEqual(@as(f32, 19), caret.height);
            try std.testing.expect(caret.y + caret.height <= panel.y + panel.height);
        }
    }
}

test "Clay list reveal clips offscreen hit bounds without clipping sibling controls" {
    const surface = c.hollow_clay_create() orelse return error.OutOfMemory;
    defer c.hollow_clay_destroy(surface);
    var nodes = [_]c.HollowClayNode{
        node(0, -1, -1, 3),  node(0, -1, 40, 0),
        node(0, -1, 100, 4), node(0, -1, 40, 0),
        node(0, -1, 40, 0),  node(0, -1, 40, 0),
        node(0, -1, 40, 0),  node(0, -1, 40, 0),
    };
    nodes[2].scroll = true;
    nodes[2].reveal = .{ .chars = "last", .length = 4, .isStaticallyAllocated = true };
    nodes[6].id = nodes[2].reveal;
    nodes[4].id = .{ .chars = "second", .length = 6, .isStaticallyAllocated = true };
    for (nodes[3..]) |*n| n.clickable = true;
    _ = layout(surface, &nodes, 300, 220, 0);
    try std.testing.expect(!c.hollow_clay_failed(surface));
    try std.testing.expect(!c.hollow_clay_visible_bounds(surface, &nodes, nodes.len, 3).found);
    const partial = c.hollow_clay_visible_bounds(surface, &nodes, nodes.len, 4);
    try std.testing.expect(partial.found);
    try std.testing.expectEqual(@as(f32, 40), partial.boundingBox.y);
    try std.testing.expectEqual(@as(f32, 20), partial.boundingBox.height);
    try std.testing.expectEqual(@as(c_int, -1), c.hollow_clay_hit(surface, &nodes, nodes.len, 150, 20));
    try std.testing.expectEqual(@as(c_int, 4), c.hollow_clay_hit(surface, &nodes, nodes.len, 150, 45));
    const footer = c.hollow_clay_visible_bounds(surface, &nodes, nodes.len, 7);
    try std.testing.expect(footer.found);
    try std.testing.expectEqual(@as(f32, 40), footer.boundingBox.height);
    try std.testing.expectEqual(@as(c_int, 7), c.hollow_clay_hit(surface, &nodes, nodes.len, 150, 160));
    // Wheel navigation aligns its first visible row even if it was partly visible.
    nodes[2].reveal = nodes[4].id;
    nodes[2].reveal_start = true;
    _ = layout(surface, &nodes, 300, 220, 0);
    try std.testing.expectEqual(@as(f32, 40), c.hollow_clay_bounds(surface, &nodes, 4).boundingBox.y);
    const last = c.hollow_clay_visible_bounds(surface, &nodes, nodes.len, 6);
    try std.testing.expect(last.found);
    try std.testing.expectEqual(@as(f32, 20), last.boundingBox.height);
    try std.testing.expectEqual(@as(c_int, 7), c.hollow_clay_hit(surface, &nodes, nodes.len, 150, 150));
}

test "Clay vertical list reveal preserves row x with scrollbar gutter" {
    const surface = c.hollow_clay_create() orelse return error.OutOfMemory;
    defer c.hollow_clay_destroy(surface);
    var nodes: [13]c.HollowClayNode = undefined;
    nodes[0] = node(0, -1, -1, 1);
    nodes[1] = node(0, -1, 100, 11);
    nodes[1].scroll = true;
    nodes[1].scroll_x = true;
    nodes[1].padding.right = 8;
    for (nodes[2..]) |*row| row.* = node(0, -1, 25, 0);
    nodes[2].id = .{ .chars = "first", .length = 5, .isStaticallyAllocated = true };
    nodes[7].id = .{ .chars = "middle", .length = 6, .isStaticallyAllocated = true };
    nodes[12].id = .{ .chars = "last", .length = 4, .isStaticallyAllocated = true };
    // Home, End, scrollbar drag, and Home again; drag aligns the first visible row.
    for ([_]usize{ 2, 12, 7, 2 }) |index| {
        nodes[1].reveal = nodes[index].id;
        nodes[1].reveal_start = index == 7;
        _ = layout(surface, &nodes, 300, 100, 0);
        try std.testing.expect(!c.hollow_clay_failed(surface));
        const viewport = c.hollow_clay_bounds(surface, &nodes, 1).boundingBox;
        const row = c.hollow_clay_bounds(surface, &nodes, @intCast(index)).boundingBox;
        try std.testing.expectEqual(viewport.x, row.x);
        try std.testing.expectEqual(viewport.width - 8, row.width);
        const visible = c.hollow_clay_visible_bounds(surface, &nodes, nodes.len, @intCast(index));
        try std.testing.expect(visible.found);
    }
}

test "Clay framed select allocates a grow viewport and reveals selection after resize" {
    const surface = c.hollow_clay_create() orelse return error.OutOfMemory;
    defer c.hollow_clay_destroy(surface);
    var nodes: [33]c.HollowClayNode = undefined;
    nodes[0] = node(0, 0, 0, 1);
    nodes[0].padding = .{ .left = 4, .right = 4, .top = 19, .bottom = 9 };
    nodes[1] = node(0, -1, -1, 7);
    nodes[2] = node(0, -1, 19, 0); // Title/counter.
    nodes[3] = node(0, -1, 1, 0);
    nodes[4] = node(0, -1, 23, 0); // Filter field.
    nodes[5] = node(0, -1, 1, 0);
    nodes[6] = node(0, -1, -1, 24);
    nodes[6].scroll = true;
    nodes[6].scroll_x = true;
    nodes[6].reveal = .{ .chars = "selected", .length = 8, .isStaticallyAllocated = true };
    for (nodes[7..31], 0..) |*row, i| {
        row.* = node(0, -1, if (i % 2 == 0) 23 else 46, 0);
        row.clickable = true;
    }
    nodes[30].id = nodes[6].reveal;
    nodes[31] = node(0, -1, 1, 0);
    nodes[32] = node(0, -1, 19, 0); // Action hints below the viewport.
    c.hollow_clay_frame(surface, .{
        .enabled = true,
        .width = 520,
        .height = 266,
        .margin = .{ .left = 8, .right = 8, .top = 19, .bottom = 19 },
        .align_x = 1,
        .align_y = 1,
    });
    for ([_]f32{ 692, 160, 692 }) |height| {
        _ = c.hollow_clay_layout(surface, &nodes, nodes.len, 1100, height, 8, 19, -1, -1, 0, 1.0 / 60.0);
        try std.testing.expect(!c.hollow_clay_failed(surface));
        const viewport = c.hollow_clay_bounds(surface, &nodes, 6).boundingBox;
        try std.testing.expect(viewport.height > 0);
        const selected = c.hollow_clay_visible_bounds(surface, &nodes, nodes.len, 30);
        try std.testing.expect(selected.found);
        try std.testing.expect(selected.boundingBox.y >= viewport.y);
        try std.testing.expect(selected.boundingBox.y + selected.boundingBox.height <= viewport.y + viewport.height);
        try std.testing.expect(!c.hollow_clay_visible_bounds(surface, &nodes, nodes.len, 7).found);
        for (7..31) |index| {
            const row = c.hollow_clay_visible_bounds(surface, &nodes, nodes.len, @intCast(index));
            if (!row.found) continue;
            try std.testing.expect(row.boundingBox.y >= viewport.y);
            try std.testing.expect(row.boundingBox.y + row.boundingBox.height <= viewport.y + viewport.height);
        }
        try std.testing.expect(c.hollow_clay_visible_bounds(surface, &nodes, nodes.len, 32).found);
    }
}

test "Clay list clips long unwrapped labels to the viewport rather than panel padding" {
    const surface = c.hollow_clay_create() orelse return error.OutOfMemory;
    defer c.hollow_clay_destroy(surface);
    var nodes = [_]c.HollowClayNode{
        node(0, 0, 0, 1),   node(0, -1, -1, 2),
        node(0, -1, -1, 1), node(0, -1, 23, 1),
        node(2, 0, 0, 0),   node(0, -1, 19, 0),
    };
    nodes[0].padding = .{ .left = 4, .right = 4, .top = 4, .bottom = 4 };
    nodes[2].scroll = true;
    nodes[2].scroll_x = true;
    nodes[2].reveal = .{ .chars = "row", .length = 3, .isStaticallyAllocated = true };
    nodes[3].id = nodes[2].reveal;
    nodes[3].clickable = true;
    const label = "a-very-long-unwrapped-filename-that-must-not-expand-the-select-viewport-or-escape-its-clipping";
    nodes[4].text = .{ .chars = label, .length = label.len, .isStaticallyAllocated = true };
    nodes[4].wrap = 2;
    c.hollow_clay_frame(surface, .{
        .enabled = true,
        .width = 200,
        .height = 160,
        .margin = .{ .left = 8, .right = 8, .top = 8, .bottom = 8 },
        .align_x = 1,
        .align_y = 1,
    });
    _ = layout(surface, &nodes, 400, 300, 0);
    try std.testing.expect(!c.hollow_clay_failed(surface));
    const panel = c.hollow_clay_bounds(surface, &nodes, 0).boundingBox;
    const viewport = c.hollow_clay_bounds(surface, &nodes, 2).boundingBox;
    try std.testing.expectEqual(@as(f32, 192), viewport.width);
    const row = c.hollow_clay_visible_bounds(surface, &nodes, nodes.len, 3);
    try std.testing.expect(row.found);
    try std.testing.expectEqual(viewport.width, row.boundingBox.width);
    try std.testing.expectEqual(@as(c_int, 3), c.hollow_clay_hit(surface, &nodes, nodes.len, viewport.x + 1, viewport.y + 1));
    try std.testing.expectEqual(@as(c_int, -1), c.hollow_clay_hit(surface, &nodes, nodes.len, panel.x + panel.width - 1, viewport.y + 1));
}

test "Clay paint snapping rounds edges, not origin plus size" {
    const paint = @import("clay_paint.zig");
    const b = paint.snap(.{ .x = 10.4, .y = 3.6, .width = 20.2, .height = 0.3 });
    try std.testing.expectEqual(@as(f32, 10), b.x);
    try std.testing.expectEqual(@as(f32, 4), b.y);
    try std.testing.expectEqual(@as(f32, 21), b.width);
    try std.testing.expectEqual(@as(f32, 0), b.height);
}

test "Clay paint scissor without axis flags clips both axes" {
    const paint = @import("clay_paint.zig");
    const screen: c.Clay_BoundingBox = .{ .x = 0, .y = 0, .width = 800, .height = 600 };
    const pane: c.Clay_BoundingBox = .{ .x = 400, .y = 40, .width = 400, .height = 200 };
    const floating = paint.scissorBounds(screen, pane, std.mem.zeroes(c.Clay_ClipRenderData));
    try std.testing.expectEqual(pane.x, floating.x);
    try std.testing.expectEqual(pane.y, floating.y);
    try std.testing.expectEqual(pane.width, floating.width);
    try std.testing.expectEqual(pane.height, floating.height);
    const vertical = paint.scissorBounds(screen, pane, .{ .horizontal = false, .vertical = true });
    try std.testing.expectEqual(screen.x, vertical.x);
    try std.testing.expectEqual(screen.width, vertical.width);
    try std.testing.expectEqual(pane.y, vertical.y);
    try std.testing.expectEqual(pane.height, vertical.height);
}

fn debugRect(label: []const u8, index: u32, children: c_int, x: f32, y: f32, w: f32, h: f32) c.HollowClayDebugRect {
    var r = std.mem.zeroes(c.HollowClayDebugRect);
    r.id = .{ .chars = label.ptr, .length = @intCast(label.len), .isStaticallyAllocated = true };
    r.index = index;
    r.children = children;
    r.x = x;
    r.y = y;
    r.width = w;
    r.height = h;
    return r;
}

fn expectDebugBounds(r: c.HollowClayDebugRect) !void {
    const data = c.Clay_GetElementData(c.Clay_GetElementIdWithIndex(r.id, r.index));
    try std.testing.expect(data.found);
    try std.testing.expectApproxEqAbs(r.x, data.boundingBox.x, 0.01);
    try std.testing.expectApproxEqAbs(r.y, data.boundingBox.y, 0.01);
    try std.testing.expectApproxEqAbs(r.width, data.boundingBox.width, 0.01);
    try std.testing.expectApproxEqAbs(r.height, data.boundingBox.height, 0.01);
}

test "debug mirror reproduces externally computed split geometry" {
    const surface = c.hollow_clay_create() orelse return error.OutOfMemory;
    defer c.hollow_clay_destroy(surface);
    var rects = [_]c.HollowClayDebugRect{
        debugRect("window", 0, 3, 0, 0, 800, 600),
        debugRect("topbar", 0, 0, 0, 0, 800, 30),
        debugRect("content", 0, 2, 0, 30, 800, 540),
        // Vertical split with a one-pixel divider, and a floating pane on top.
        debugRect("split.vertical", 0, 2, 0, 30, 800, 540),
        debugRect("pane", 1, 0, 0, 30, 399, 540),
        debugRect("split.horizontal", 1, 2, 400, 30, 400, 540),
        debugRect("pane", 2, 0, 400, 30, 400, 269),
        debugRect("pane", 3, 0, 400, 300, 400, 270),
        debugRect("pane", 4, 0, 100, 100, 200, 200),
        debugRect("bottombar", 0, 0, 0, 580, 800, 20),
    };
    rects[4].detail = .{ .chars = "80x24 active", .length = 12, .isStaticallyAllocated = true };
    rects[8].floating = true;
    for (0..3) |_| {
        const commands = c.hollow_clay_debug_layout(surface, &rects, rects.len, 800, 600, 8, 16, -1, -1, false, 0, 1.0 / 60.0);
        try std.testing.expect(!c.hollow_clay_failed(surface));
        try std.testing.expect(commands.length > 0); // The inspector panel itself.
    }
    for (rects) |r| try expectDebugBounds(r);
    try std.testing.expect(!c.hollow_clay_debug_closed(surface));
}

test "debug mirror rejects malformed trees" {
    const surface = c.hollow_clay_create() orelse return error.OutOfMemory;
    defer c.hollow_clay_destroy(surface);
    var rects = [_]c.HollowClayDebugRect{
        debugRect("window", 0, 2, 0, 0, 800, 600),
        debugRect("pane", 0, 0, 0, 0, 800, 600),
    };
    _ = c.hollow_clay_debug_layout(surface, &rects, rects.len, 800, 600, 8, 16, -1, -1, false, 0, 0);
    try std.testing.expect(c.hollow_clay_failed(surface));
}

test "inspector fits a maximum-size surface" {
    const surface = c.hollow_clay_create() orelse return error.OutOfMemory;
    defer c.hollow_clay_destroy(surface);
    var nodes: [c.HOLLOW_CLAY_MAX_NODES]c.HollowClayNode = undefined;
    nodes[0] = node(1, -1, -1, nodes.len - 1);
    for (nodes[1..]) |*n| {
        n.* = node(2, 0, 0, 0);
        n.text = .{ .chars = "palette entry label", .length = 19, .isStaticallyAllocated = true };
    }
    c.hollow_clay_set_debug(surface, true);
    for (0..2) |_| {
        _ = layout(surface, &nodes, 1600, 900, 0);
        try std.testing.expect(!c.hollow_clay_failed(surface));
    }
}

test "surface inspector receives presses and reports its close button" {
    const surface = c.hollow_clay_create() orelse return error.OutOfMemory;
    defer c.hollow_clay_destroy(surface);
    var nodes = [_]c.HollowClayNode{ node(0, -1, -1, 1), node(0, -1, 20, 0) };
    c.hollow_clay_set_debug(surface, true);
    // Clay's close button is the 20 px square at the header's right padding.
    const x: f32 = 1200 - 10 - 10;
    const y: f32 = 15;
    // Hover first so Clay records the pointer over the button, then press.
    _ = c.hollow_clay_layout(surface, &nodes, nodes.len, 1200, 800, 8, 16, x, y, 0, 1.0 / 60.0);
    try std.testing.expect(!c.hollow_clay_debug_closed(surface));
    c.hollow_clay_set_pointer_down(surface, true);
    _ = c.hollow_clay_layout(surface, &nodes, nodes.len, 1200, 800, 8, 16, x, y, 0, 1.0 / 60.0);
    try std.testing.expect(c.hollow_clay_debug_closed(surface));
}

test "grid inspector reports its close button after a click" {
    const surface = c.hollow_clay_create() orelse return error.OutOfMemory;
    defer c.hollow_clay_destroy(surface);
    var rects = [_]c.HollowClayDebugRect{debugRect("window", 0, 0, 0, 0, 1200, 800)};
    const x: f32 = 1200 - 10 - 10;
    const y: f32 = 15;
    var closed = false;
    for ([_]bool{ false, true, false }) |down| {
        _ = c.hollow_clay_debug_layout(surface, &rects, rects.len, 1200, 800, 8, 16, x, y, down, 0, 1.0 / 60.0);
        closed = closed or c.hollow_clay_debug_closed(surface);
    }
    try std.testing.expect(closed);
}

test "inspector width clamps and moves the panel" {
    const input = @import("clay_inspector_input.zig");
    defer _ = input.setWidth(input.default_width, 2000);
    try std.testing.expectEqual(@as(f32, 250), input.clampWidth(10, 1200));
    try std.testing.expectEqual(@as(f32, 1100), input.clampWidth(5000, 1200));
    try std.testing.expectEqual(@as(f32, 400), input.clampWidth(std.math.nan(f32), 1200));
    try std.testing.expectEqual(@as(f32, 600), input.setWidth(600, 1200));
    const area: input.Rect = .{ .width = 1200, .height = 800 };
    try std.testing.expect(input.nearEdge(area, 602, 10));
    try std.testing.expect(!input.inPanel(area, 590, 10));
    try std.testing.expect(input.inPanel(area, 610, 10));
}

test "debug mirror carries styles, infers padding and paints only the inspector" {
    const surface = c.hollow_clay_create() orelse return error.OutOfMemory;
    defer c.hollow_clay_destroy(surface);
    const red: c.Clay_Color = .{ .r = 200, .g = 10, .b = 10, .a = 255 };
    const blue: c.Clay_Color = .{ .r = 10, .g = 10, .b = 200, .a = 72 };
    var rects = [_]c.HollowClayDebugRect{
        debugRect("frame", 0, 2, 0, 0, 800, 30),
        debugRect("item", 0, 0, 6, 4, 100, 22),
        debugRect("item", 1, 0, 120, 4, 100, 22),
    };
    rects[0].background = red;
    rects[0].padding = .{ .left = 99, .top = 99, .right = 3, .bottom = 4 };
    rects[1].border_color = blue;
    rects[1].border_width = 1;
    rects[1].corner_radius = 5;
    rects[1].padding = .{ .left = 8, .right = 8 };
    rects[1].text_color = red;
    rects[1].font_id = 1;
    rects[1].detail = .{ .chars = "tab", .length = 3, .isStaticallyAllocated = true };
    var commands: c.Clay_RenderCommandArray = undefined;
    for (0..3) |_| {
        commands = c.hollow_clay_debug_layout(surface, &rects, rects.len, 800, 600, 8, 16, -1, -1, false, 0, 1.0 / 60.0);
        try std.testing.expect(!c.hollow_clay_failed(surface));
    }
    for (rects) |r| try expectDebugBounds(r);
    for (commands.internalArray[0..@intCast(commands.length)]) |command| {
        try std.testing.expect(command.userData == null);
        if (command.commandType == c.CLAY_RENDER_COMMAND_TYPE_RECTANGLE) {
            const bg = command.renderData.rectangle.backgroundColor;
            try std.testing.expect(!(bg.r == red.r and bg.g == red.g and bg.b == red.b));
        }
        if (command.commandType == c.CLAY_RENDER_COMMAND_TYPE_TEXT) {
            const text = command.renderData.text;
            try std.testing.expect(!(text.fontId == 1 and text.textColor.r == red.r and text.textColor.b == red.b));
        }
        if (command.commandType == c.CLAY_RENDER_COMMAND_TYPE_BORDER) {
            try std.testing.expect(command.renderData.border.color.b != blue.b or command.renderData.border.color.a != blue.a);
        }
    }
}
