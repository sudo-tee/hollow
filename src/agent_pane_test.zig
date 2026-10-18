const std = @import("std");
const io = @import("io.zig");
const Pane = @import("pane.zig").Pane;
const ghostty = @import("term/ghostty.zig");
const a = std.testing.allocator;

const Callbacks = struct {
    fn write(_: ?*anyopaque, userdata: ?*anyopaque, bytes: [*]const u8, len: usize) callconv(.c) void {
        const pane: *Pane = @ptrCast(@alignCast(userdata orelse return));
        pane.sendText(bytes[0..len]);
    }
    fn noop(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {}
    fn string(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) ghostty.String {
        return .{ .ptr = null, .len = 0 };
    }
    fn size(_: ?*anyopaque, _: ?*anyopaque, _: *ghostty.SizeReportSize) callconv(.c) bool {
        return false;
    }
    fn scheme(_: ?*anyopaque, _: ?*anyopaque, _: *ghostty.ColorScheme) callconv(.c) bool {
        return false;
    }
    fn attributes(_: ?*anyopaque, _: ?*anyopaque, _: *ghostty.DeviceAttributes) callconv(.c) bool {
        return false;
    }
    const value: ghostty.TerminalCallbacks = .{
        .write_pty = write,
        .bell = noop,
        .enquiry = string,
        .xtversion = string,
        .size = size,
        .color_scheme = scheme,
        .device_attributes = attributes,
        .title_changed = noop,
    };
};

fn poll(pane: *Pane, runtime: *ghostty.Runtime) !void {
    _ = try pane.pollPty(runtime, 8, 65536, 10 * std.time.ns_per_ms, 4096, false);
    try std.Io.sleep(io.get(), .fromMilliseconds(1), .awake);
}

fn screenContains(pane: *Pane, runtime: *ghostty.Runtime, expected: []const u8) !void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    for (0..pane.rows) |y| {
        for (0..pane.cols) |x| {
            var ref: ghostty.GridRef = .{ .size = @sizeOf(ghostty.GridRef), .node = null, .x = 0, .y = 0 };
            const point: ghostty.Point = .{ .tag = .active, .value = .{ .coordinate = .{ .x = @intCast(x), .y = @intCast(y) } } };
            try std.testing.expectEqual(ghostty.success, runtime.terminal_grid_ref(pane.terminal, point, &ref));
            const cell = runtime.gridRefCell(&ref) orelse return error.MissingCell;
            const codepoint = runtime.cellCodepointRaw(cell);
            try text.append(a, if (codepoint > 0 and codepoint < 128) @intCast(codepoint) else ' ');
        }
    }
    if (std.mem.indexOf(u8, text.items, expected) == null) {
        std.debug.print("missing '{s}' in terminal: '{s}'\n", .{ expected, text.items });
        return error.MissingTerminalText;
    }
}

test "agent pane bootstrap, deferred startup input, background parsing and final exit" {
    var runtime = try ghostty.Runtime.init(a, null);
    defer runtime.deinit();
    var pane = Pane.init(a);
    defer pane.deinit(&runtime);
    try pane.bootstrap(&runtime, Callbacks.value, .{ .allocator = a }, 8, 16, 640, 384, null, null, null, null);
    try std.testing.expect(pane.is_remote);
    try std.testing.expectEqual(@as(usize, 0), pane.childPid());
    const deadline = io.nanoTimestamp() + 10 * std.time.ns_per_s;
    while (pane.boot_output.items.len == 0) {
        if (io.nanoTimestamp() >= deadline) return error.Timeout;
        try poll(&pane, &runtime);
    }
    try std.testing.expect(std.mem.indexOf(u8, pane.boot_output.items, "READY") != null);
    pane.resize(&runtime, 80, 24, 8, 16, false);
    pane.render_state_ready = true;
    pane.terminal_output_ready = true;
    const input = try a.alloc(u8, 131072);
    defer a.free(input);
    for (input, 0..) |*byte, index| byte.* = @truncate(index);
    try pane.queueStartupInput(input);
    while (pane.active_screen != @intFromEnum(ghostty.TerminalScreen.alternate)) {
        if (io.nanoTimestamp() >= deadline) return error.Timeout;
        try poll(&pane, &runtime);
    }
    try std.testing.expectEqual(@as(usize, 0), pane.pending_startup_input.len);
    try std.testing.expect(pane.render_state_fresh);
    try screenContains(&pane, &runtime, "ALT_SCREEN");
    pane.releaseRenderHelpers(&runtime);
    pane.sendText("done\n");
    while (pane.child_alive_cached) {
        if (io.nanoTimestamp() >= deadline) return error.Timeout;
        try poll(&pane, &runtime);
    }
    try std.testing.expectEqual(@intFromEnum(ghostty.TerminalScreen.primary), pane.active_screen);
    try std.testing.expectEqual(@as(?u32, 7), pane.pty.?.exitStatus());
    try std.testing.expectEqual(@as(usize, 0), pane.boot_output.items.len);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(input, &digest, .{});
    const expected = std.fmt.bytesToHex(digest, .lower);
    try screenContains(&pane, &runtime, &expected);
    try screenContains(&pane, &runtime, "RESPONSE_OK");
    try screenContains(&pane, &runtime, "FINAL");
}

test "agent pane closing with partially queued startup input leaves another pane usable" {
    var runtime = try ghostty.Runtime.init(a, null);
    defer runtime.deinit();
    var first = Pane.init(a);
    defer first.deinit(&runtime);
    var second = Pane.init(a);
    defer second.deinit(&runtime);
    try first.bootstrap(&runtime, Callbacks.value, .{ .allocator = a }, 8, 16, 640, 384, null, null, null, null);
    try second.bootstrap(&runtime, Callbacks.value, .{ .allocator = a }, 8, 16, 640, 384, null, null, null, null);
    const deadline = io.nanoTimestamp() + 10 * std.time.ns_per_s;
    while (first.boot_output.items.len == 0 or second.boot_output.items.len == 0) {
        if (io.nanoTimestamp() >= deadline) return error.Timeout;
        try poll(&first, &runtime);
        try poll(&second, &runtime);
    }
    const input = try a.alloc(u8, 131072);
    defer a.free(input);
    for (input, 0..) |*byte, index| byte.* = @truncate(index);
    try first.queueStartupInput(input);
    // One startup tick must accept only a prefix; the original allocation must
    // still be freed in full when replacing input and closing this pane.
    try poll(&first, &runtime);
    try std.testing.expect(first.pending_startup_input.len > 0);
    try std.testing.expect(first.pending_startup_input.len < first.pending_startup_input_capacity);
    try first.queueStartupInput("queued during partial delivery");
    while (first.pending_startup_input.len == first.pending_startup_input_capacity) {
        if (io.nanoTimestamp() >= deadline) return error.Timeout;
        try poll(&first, &runtime);
    }
    try std.testing.expect(first.pending_startup_input.len > 0);
    first.deinit(&runtime);
    try std.testing.expect(second.pty.?.isAlive());
    second.resize(&runtime, 80, 24, 8, 16, false);
    second.terminal_output_ready = true;
    second.render_state_ready = true;
    try second.queueStartupInput(input);
    while (second.active_screen != @intFromEnum(ghostty.TerminalScreen.alternate)) {
        if (io.nanoTimestamp() >= deadline) return error.Timeout;
        try poll(&second, &runtime);
    }
    second.sendText("survived\n");
    while (second.child_alive_cached) {
        if (io.nanoTimestamp() >= deadline) return error.Timeout;
        try poll(&second, &runtime);
    }
    try std.testing.expectEqual(@as(?u32, 7), second.pty.?.exitStatus());
    try screenContains(&second, &runtime, "FINAL");
}
