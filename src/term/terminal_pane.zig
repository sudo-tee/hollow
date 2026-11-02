//! Terminal-owned resources, extracted incrementally from the generic pane node.
//! During migration Pane embeds this value; it will become the terminal content
//! arm once all terminal consumers have moved behind the content boundary.
const ghostty = @import("ghostty.zig");
const Pty = @import("../pty/pty.zig").Pty;

pub const TerminalPane = struct {
    pty: ?Pty = null,
    terminal: ?*anyopaque = null,
    terminal_runtime: ?*ghostty.Runtime = null,
    render_state: ?*anyopaque = null,
    row_iterator: ?*anyopaque = null,
    row_cells: ?*anyopaque = null,
    /// The render helpers have received their first render-state update.
    render_state_ready: bool = false,
    /// Parser readiness survives releasing render helpers on hidden tabs.
    terminal_output_ready: bool = false,
    /// A PTY poll already refreshed this frame's render state.
    render_state_fresh: bool = false,
    key_encoder: ?*anyopaque = null,
    key_event: ?*anyopaque = null,
    mouse_encoder: ?*anyopaque = null,
    mouse_event: ?*anyopaque = null,
    /// Borrowed only during synchronous bracketed-paste encoding.
    paste_output: ?*ghostty.PasteOutput = null,

    pub fn initInput(runtime: *ghostty.Runtime, terminal: ?*anyopaque) !TerminalPane {
        const key_encoder = try runtime.createKeyEncoder();
        errdefer runtime.freeKeyEncoder(key_encoder);
        runtime.syncKeyEncoder(key_encoder, terminal);
        const key_event = try runtime.createKeyEvent();
        errdefer runtime.freeKeyEvent(key_event);
        const mouse_encoder = try runtime.createMouseEncoder();
        errdefer runtime.freeMouseEncoder(mouse_encoder);
        const mouse_event = try runtime.createMouseEvent();
        return .{
            .terminal_runtime = runtime,
            .key_encoder = key_encoder,
            .key_event = key_event,
            .mouse_encoder = mouse_encoder,
            .mouse_event = mouse_event,
        };
    }

    pub fn deinitInput(self: *TerminalPane, runtime: *ghostty.Runtime) void {
        runtime.freeMouseEvent(self.mouse_event);
        runtime.freeMouseEncoder(self.mouse_encoder);
        runtime.freeKeyEvent(self.key_event);
        runtime.freeKeyEncoder(self.key_encoder);
        self.mouse_event = null;
        self.mouse_encoder = null;
        self.key_event = null;
        self.key_encoder = null;
    }

    pub fn deinitPty(self: *TerminalPane) void {
        if (self.pty) |*pty| pty.deinit();
        self.pty = null;
    }

    pub fn deinit(self: *TerminalPane, runtime: *ghostty.Runtime) void {
        self.deinitInput(runtime);
        self.freeRenderHandles(runtime);
        runtime.setTerminalUserdata(self.terminal, null);
        runtime.freeTerminal(self.terminal);
        self.deinitPty();
        self.* = .{};
    }

    fn freeRenderHandles(self: *TerminalPane, runtime: anytype) void {
        runtime.freeRowCells(self.row_cells);
        self.row_cells = null;
        runtime.freeRowIterator(self.row_iterator);
        self.row_iterator = null;
        runtime.freeRenderState(self.render_state);
        self.render_state = null;
    }

    pub fn hasRenderHelpers(self: *const TerminalPane) bool {
        return self.render_state != null and self.row_iterator != null and self.row_cells != null;
    }

    pub fn renderHelpersReady(self: *const TerminalPane) bool {
        return self.render_state_ready and self.hasRenderHelpers();
    }

    pub fn recreateRenderHelpers(self: *TerminalPane, runtime: *ghostty.Runtime) void {
        const std = @import("std");
        var failed: RenderResource = undefined;
        self.replaceRenderHelpers(runtime, &failed) catch |err| {
            std.log.err("pane: recreate {s} failed: {s}", .{ @tagName(failed), @errorName(err) });
        };
    }

    const RenderResource = enum { render_state, row_iterator, row_cells };

    /// Fallible ownership transaction, also exercised with an allocation-failing
    /// test runtime. No live handles or readiness flags change before success.
    fn replaceRenderHelpers(self: *TerminalPane, runtime: anytype, failed: *RenderResource) !void {
        failed.* = .render_state;
        const new_render_state = try runtime.createRenderState();
        errdefer runtime.freeRenderState(new_render_state);
        failed.* = .row_iterator;
        const new_row_iterator = try runtime.createRowIterator();
        errdefer runtime.freeRowIterator(new_row_iterator);
        failed.* = .row_cells;
        const new_row_cells = try runtime.createRowCells();
        // Publish all three only after every allocation succeeds. A failed
        // recreation leaves the previous helpers intact and releases its locals.
        self.freeRenderHandles(runtime);
        self.render_state = new_render_state;
        self.row_iterator = new_row_iterator;
        self.row_cells = new_row_cells;
        self.render_state_ready = false;
    }

    pub fn releaseRenderHelpers(self: *TerminalPane, runtime: *ghostty.Runtime) void {
        self.freeRenderHandles(runtime);
        self.render_state_ready = false;
        self.render_state_fresh = false;
    }

    pub fn syncInput(self: *TerminalPane, runtime: *ghostty.Runtime, terminal: ?*anyopaque) void {
        runtime.syncKeyEncoder(self.key_encoder, terminal);
        runtime.syncMouseEncoder(self.mouse_encoder, terminal);
    }

    pub fn encodeKey(self: *TerminalPane, runtime: *ghostty.Runtime, key: ghostty.Key, mods: u32, action: ghostty.KeyAction, consumed_mods: u32, unshifted_codepoint: u32, utf8: ?[]const u8, out: []u8) ?[]const u8 {
        return runtime.encodeKey(self.key_encoder, self.key_event, key, mods, action, consumed_mods, unshifted_codepoint, utf8, out);
    }

    pub fn encodeMouse(self: *TerminalPane, runtime: *ghostty.Runtime, action: ghostty.MouseAction, button: ?ghostty.MouseButton, mods: u32, position: ghostty.MousePosition, out: []u8) ?[]const u8 {
        runtime.setMouseEncoderAnyButtonPressed(self.mouse_encoder, action != .release and button != null);
        return runtime.encodeMouse(self.mouse_encoder, self.mouse_event, action, button, mods, position, out);
    }
};

test "terminal input resources are owned and released independently of the pane node" {
    const std = @import("std");
    var runtime = try ghostty.Runtime.init(std.testing.allocator, null);
    defer runtime.deinit();
    const terminal = try runtime.createTerminal(80, 24, 0);
    defer runtime.freeTerminal(terminal);
    var content = try TerminalPane.initInput(&runtime, terminal);
    defer content.deinitInput(&runtime);
    try std.testing.expect(content.key_encoder != null and content.key_event != null);
    try std.testing.expect(content.mouse_encoder != null and content.mouse_event != null);
    content.syncInput(&runtime, terminal);
    var out: [128]u8 = undefined;
    try std.testing.expectEqualStrings("\r", content.encodeKey(&runtime, .enter, 0, .press, 0, 0, null, &out).?);
    content.deinitInput(&runtime);
    try std.testing.expect(content.key_encoder == null and content.key_event == null);
    try std.testing.expect(content.mouse_encoder == null and content.mouse_event == null);
}

test "terminal render helper lifetime preserves parser readiness across hidden tabs" {
    const std = @import("std");
    var runtime = try ghostty.Runtime.init(std.testing.allocator, null);
    defer runtime.deinit();
    var content: TerminalPane = .{
        .terminal_runtime = &runtime,
        .terminal = try runtime.createTerminal(80, 24, 0),
        .terminal_output_ready = true,
    };
    defer content.deinit(&runtime);
    content.recreateRenderHelpers(&runtime);
    try std.testing.expect(content.hasRenderHelpers());
    try std.testing.expect(!content.renderHelpersReady());
    content.render_state_ready = true;
    content.render_state_fresh = true;
    try std.testing.expect(content.renderHelpersReady());
    const terminal = content.terminal;
    content.releaseRenderHelpers(&runtime);
    content.releaseRenderHelpers(&runtime);
    try std.testing.expect(!content.hasRenderHelpers());
    try std.testing.expect(!content.render_state_ready and !content.render_state_fresh);
    try std.testing.expect(content.terminal_output_ready);
    try std.testing.expectEqual(terminal, content.terminal);
    content.recreateRenderHelpers(&runtime);
    try std.testing.expect(content.hasRenderHelpers());
    try std.testing.expect(content.terminal_output_ready);
    content.deinit(&runtime);
    try std.testing.expect(content.terminal == null and content.terminal_runtime == null);
    try std.testing.expect(!content.terminal_output_ready);
}

test "failed render helper recreation unwinds allocations and preserves existing resources" {
    const std = @import("std");
    const Fake = struct {
        fail_at: usize,
        created: usize = 0,
        live: usize = 3,

        fn create(self: *@This()) !?*anyopaque {
            self.created += 1;
            if (self.created == self.fail_at) return error.OutOfMemory;
            self.live += 1;
            return @ptrFromInt(self.created * 16);
        }
        fn createRenderState(self: *@This()) !?*anyopaque {
            return self.create();
        }
        fn createRowIterator(self: *@This()) !?*anyopaque {
            return self.create();
        }
        fn createRowCells(self: *@This()) !?*anyopaque {
            return self.create();
        }
        fn freeRenderState(self: *@This(), handle: ?*anyopaque) void {
            if (handle != null) self.live -= 1;
        }
        fn freeRowIterator(self: *@This(), handle: ?*anyopaque) void {
            if (handle != null) self.live -= 1;
        }
        fn freeRowCells(self: *@This(), handle: ?*anyopaque) void {
            if (handle != null) self.live -= 1;
        }
    };
    for (1..4) |fail_at| {
        var runtime: Fake = .{ .fail_at = fail_at };
        var content: TerminalPane = .{
            .render_state = @ptrFromInt(1024),
            .row_iterator = @ptrFromInt(2048),
            .row_cells = @ptrFromInt(3072),
            .render_state_ready = true,
            .render_state_fresh = true,
            .terminal_output_ready = true,
        };
        const original = content;
        var failed: TerminalPane.RenderResource = undefined;
        try std.testing.expectError(error.OutOfMemory, content.replaceRenderHelpers(&runtime, &failed));
        try std.testing.expectEqual(std.enums.values(TerminalPane.RenderResource)[fail_at - 1], failed);
        try std.testing.expectEqual(original.render_state, content.render_state);
        try std.testing.expectEqual(original.row_iterator, content.row_iterator);
        try std.testing.expectEqual(original.row_cells, content.row_cells);
        try std.testing.expect(content.render_state_ready and content.render_state_fresh);
        try std.testing.expectEqual(@as(usize, 3), runtime.live);
        runtime.fail_at = 0;
        try content.replaceRenderHelpers(&runtime, &failed);
        try std.testing.expect(content.render_state != original.render_state);
        try std.testing.expect(!content.render_state_ready);
        try std.testing.expect(content.render_state_fresh and content.terminal_output_ready);
        try std.testing.expectEqual(@as(usize, 3), runtime.live);
        content.freeRenderHandles(&runtime);
        content.freeRenderHandles(&runtime);
        try std.testing.expectEqual(@as(usize, 0), runtime.live);
    }
}
