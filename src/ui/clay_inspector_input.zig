//! Pointer input shared by Clay inspector panels.
const std = @import("std");
const c = @import("clay_c");

pub const Rect = struct { x: f32 = 0, y: f32 = 0, width: f32 = 0, height: f32 = 0 };

pub const default_width: f32 = 400;
pub const min_width: f32 = 250;
/// Room kept for the inspected layout beside the panel.
const min_layout_width: f32 = 100;
/// Half-width of the grab zone on the panel's left edge.
const edge_grab: f32 = 4;

/// Panel width shared by every inspector; Clay keeps it as a process global.
pub fn width() f32 {
    return @floatFromInt(c.Clay__debugViewWidth);
}

/// The panel width `requested` clamps to inside a layout `available` wide.
pub fn clampWidth(requested: f32, available: f32) f32 {
    const value = if (std.math.isFinite(requested)) requested else default_width;
    return @round(std.math.clamp(value, min_width, @max(min_width, available - min_layout_width)));
}

/// Applies a clamped width and returns it.
pub fn setWidth(requested: f32, available: f32) f32 {
    const value = clampWidth(requested, available);
    c.Clay__debugViewWidth = @intFromFloat(value);
    return value;
}

/// True near the panel's left edge, where a press starts a resize.
pub fn nearEdge(area: Rect, x: f32, y: f32) bool {
    const edge = area.x + area.width - width();
    return @abs(x - edge) <= edge_grab and y >= area.y and y < area.y + area.height;
}

/// True when (x, y) is over the inspector panel Clay docks on the right edge
/// of a layout occupying `area`.
pub fn inPanel(area: Rect, x: f32, y: f32) bool {
    const right = area.x + area.width;
    return x >= right - width() and x < right and y >= area.y and y < area.y + area.height;
}

/// Primary button state as Clay sees it. A press and release within one frame
/// still reaches Clay as a press on the next layout.
pub const Latch = struct {
    down: bool = false,
    seen: bool = false,
    release_pending: bool = false,

    pub fn press(self: *Latch) void {
        self.* = .{ .down = true };
    }

    /// True when a press was active.
    pub fn release(self: *Latch) bool {
        if (!self.down) return false;
        if (self.seen) self.down = false else self.release_pending = true;
        return true;
    }

    /// Call after each layout that consumed `down`.
    pub fn advance(self: *Latch) void {
        if (self.down) self.seen = true;
        if (self.release_pending) self.* = .{};
    }
};
