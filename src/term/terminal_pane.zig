//! Terminal-owned resources, extracted incrementally from the generic pane node.
//! During migration Pane embeds this value; it will become the terminal content
//! arm once all terminal consumers have moved behind the content boundary.
const ghostty = @import("ghostty.zig");
const Pty = @import("../pty/pty.zig").Pty;

pub const TerminalPane = struct {
    pty: ?Pty = null,
    key_encoder: ?*anyopaque = null,
    key_event: ?*anyopaque = null,
    mouse_encoder: ?*anyopaque = null,
    mouse_event: ?*anyopaque = null,

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
