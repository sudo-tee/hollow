//! Native placeholder for a persistent pane whose process exited. Pure state
//! and text; rendering and key routing live with their callers.
const std = @import("std");
const Pane = @import("../pane.zig").Pane;
const ghostty = @import("../term/ghostty.zig");

pub const State = struct {
    /// Shell-style exit code (128 + signal for signals), when known.
    status: ?u32,
    /// The owner advertised respawn, so Enter can restart the process.
    respawn: bool,
};

/// Exited, still-attached session pane. Lost attachments are not "dead": the
/// process may still run on the host.
pub fn state(pane: *Pane) ?State {
    const term = pane.asTerminal() orelse return null;
    const pty = if (term.pty) |*value| value else return null;
    if (pty.* != .session) return null;
    const session = &pty.session;
    if (session.status == null or session.detached or session.close_request != null) return null;
    if (session.connection.status().phase == .ended) return null;
    return .{ .status = session.exitStatus(), .respawn = session.connection.supportsRespawn() };
}

pub const max_text = 96;

pub fn format(buf: *[max_text]u8, value: State) []const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    if (value.status) |code| {
        writer.print("Process exited with code {d}", .{code}) catch {};
    } else writer.writeAll("Process exited") catch {};
    if (value.respawn) writer.writeAll(" · Enter respawn") catch {};
    writer.writeAll(" · Ctrl+D close") catch {};
    return writer.buffered();
}

pub const Key = enum { respawn, close };

/// Default placeholder keys: plain Enter and Ctrl+D. Lock bits are ignored.
pub fn key(value: State, pressed: ghostty.Key, mods: u32) ?Key {
    const Mods = ghostty.Mods;
    const held = mods & (Mods.shift | Mods.ctrl | Mods.alt | Mods.super);
    if (pressed == .enter and held == Mods.none and value.respawn) return .respawn;
    if (pressed == .d and held == Mods.ctrl) return .close;
    return null;
}

test "dead pane text names the exit code and only offers advertised keys" {
    var buf: [max_text]u8 = undefined;
    try std.testing.expectEqualStrings("Process exited with code 3 · Enter respawn · Ctrl+D close", format(&buf, .{ .status = 3, .respawn = true }));
    try std.testing.expectEqualStrings("Process exited · Ctrl+D close", format(&buf, .{ .status = null, .respawn = false }));
    const with = State{ .status = 0, .respawn = true };
    const without = State{ .status = 0, .respawn = false };
    const Mods = ghostty.Mods;
    try std.testing.expectEqual(@as(?Key, .respawn), key(with, .enter, Mods.none));
    try std.testing.expectEqual(@as(?Key, .respawn), key(with, .enter, 0x10)); // caps lock
    try std.testing.expectEqual(@as(?Key, null), key(without, .enter, Mods.none));
    try std.testing.expectEqual(@as(?Key, .close), key(without, .d, Mods.ctrl));
    try std.testing.expectEqual(@as(?Key, null), key(with, .d, Mods.none));
    try std.testing.expectEqual(@as(?Key, null), key(with, .d, Mods.ctrl | Mods.shift));
    try std.testing.expectEqual(@as(?Key, null), key(with, .enter, Mods.alt));
}
