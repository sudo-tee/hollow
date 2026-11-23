const std = @import("std");
const bounds = @import("../ui/semantics.zig").Bounds;
const pane_drop = @import("../mux/pane_drop.zig");
const PaneBounds = @import("../mux.zig").PaneBounds;

pub const Drag = struct {
    workspace: usize,
    tab: usize,
    active_tab: usize,
    pane: ?usize = null,
    x: f32,
    y: f32,
    started: bool = false,
    canceled: bool = false,
    hover_tab: ?usize = null,
    hover_since: i128 = 0,
    preview_tab: ?usize = null,
    drop: ?Drop = null,

    pub fn track(self: *Drag, x: f32, y: f32, scale: f32) bool {
        self.started = self.started or @abs(x - self.x) >= 5 * scale or @abs(y - self.y) >= 5 * scale;
        return self.started and !self.canceled;
    }
};

pub const Drop = union(enum) {
    tab: struct { id: usize, marker: bounds },
    reorder: struct { id: usize, after: bool, marker: bounds },
    pane: struct { id: usize, tab: usize, zone: pane_drop.Zone, marker: bounds },
};

pub fn rect(b: PaneBounds) bounds {
    return .{ .x = @floatFromInt(b.x), .y = @floatFromInt(b.y), .width = @floatFromInt(b.width), .height = @floatFromInt(b.height) };
}

pub fn contains(b: bounds, x: f32, y: f32) bool {
    return x >= b.x and y >= b.y and x < b.x + b.width and y < b.y + b.height;
}

pub fn handle(b: PaneBounds, scale: f32) bounds {
    const r = rect(b);
    const w = @min(r.width, 42 * scale);
    return .{ .x = r.x + (r.width - w) / 2, .y = r.y, .width = w, .height = @min(r.height, 12 * scale) };
}

pub fn handleReveal(b: PaneBounds, scale: f32) bounds {
    var r = rect(b);
    r.height = @min(r.height, 28 * scale);
    return r;
}

/// Show the action relative to the target under the pointer, not the
/// projected layout after the dragged pane's old split collapses.
pub fn paneMarker(b: PaneBounds, zone: pane_drop.Zone) bounds {
    const r = rect(b);
    const half_w = r.width / 2;
    const half_h = r.height / 2;
    return switch (zone) {
        .left => .{ .x = r.x, .y = r.y, .width = half_w, .height = r.height },
        .right => .{ .x = r.x + half_w, .y = r.y, .width = half_w, .height = r.height },
        .top => .{ .x = r.x, .y = r.y, .width = r.width, .height = half_h },
        .bottom => .{ .x = r.x, .y = r.y + half_h, .width = r.width, .height = half_h },
        .swap => .{ .x = r.x + r.width / 5, .y = r.y + r.height / 5, .width = r.width * 3 / 5, .height = r.height * 3 / 5 },
    };
}

test "preview marks only the chosen half or an inset center of the hovered pane" {
    const b: PaneBounds = .{ .x = 10, .y = 20, .width = 300, .height = 200 };
    try std.testing.expectEqual(bounds{ .x = 10, .y = 20, .width = 150, .height = 200 }, paneMarker(b, .left));
    try std.testing.expectEqual(bounds{ .x = 160, .y = 20, .width = 150, .height = 200 }, paneMarker(b, .right));
    try std.testing.expectEqual(bounds{ .x = 10, .y = 20, .width = 300, .height = 100 }, paneMarker(b, .top));
    try std.testing.expectEqual(bounds{ .x = 10, .y = 120, .width = 300, .height = 100 }, paneMarker(b, .bottom));
    try std.testing.expectEqual(bounds{ .x = 70, .y = 60, .width = 180, .height = 120 }, paneMarker(b, .swap));
}

test "the reveal strip surrounds the handle without extending into the pane body" {
    const b: PaneBounds = .{ .x = 20, .y = 40, .width = 200, .height = 120 };
    const h = handle(b, 1);
    const r = handleReveal(b, 1);
    try std.testing.expect(contains(r, h.x + h.width - 1, h.y + h.height - 1));
    try std.testing.expect(contains(r, 25, 65));
    try std.testing.expect(!contains(h, 25, 65));
    try std.testing.expect(!contains(r, 120, 68));
}

test "layout drag waits for a threshold before arming and cancellation is sticky" {
    var drag: Drag = .{ .workspace = 1, .tab = 2, .active_tab = 2, .x = 10, .y = 10 };
    try std.testing.expect(!drag.track(14, 14, 1));
    try std.testing.expect(drag.track(15, 10, 1));
    try std.testing.expect(drag.track(10, 10, 1));
    drag.canceled = true;
    try std.testing.expect(!drag.track(30, 40, 1));
}
