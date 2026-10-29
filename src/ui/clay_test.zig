const std = @import("std");
const c = @import("clay_c");

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
