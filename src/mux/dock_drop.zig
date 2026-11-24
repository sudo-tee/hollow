//! Window-edge drop targets for pane drags: dock a tiled pane, or move a
//! docked pane to another edge or scope.
const std = @import("std");
const types = @import("types.zig");
const dock = @import("dock.zig");
const Mux = @import("mux.zig").Mux;
const Pane = @import("../pane.zig").Pane;

const Bounds = types.PaneBounds;
const PaneEdge = types.PaneEdge;
const DockScope = dock.DockScope;

/// Share given to a tiled pane docked by drag, matching the context menu.
pub const default_share: f32 = 0.3;

pub const Target = struct { edge: PaneEdge, scope: DockScope };

pub const Status = enum { ok, occupied, none };

pub fn label(edge: PaneEdge) []const u8 {
    return switch (edge) {
        .left => "Left",
        .right => "Right",
        .top => "Top",
        .bottom => "Bottom",
    };
}

pub fn scopeLabel(scope: DockScope) []const u8 {
    return switch (scope) {
        .global => "Global",
        .workspace => "Workspace",
    };
}

/// The content edge within `band` pixels of the pointer; the nearest wins.
/// The band never exceeds a sixth of the content so small windows keep
/// their pane drop zones.
pub fn edgeAt(content: Bounds, x: f32, y: f32, band: f32) ?PaneEdge {
    const left: f32 = @floatFromInt(content.x);
    const top: f32 = @floatFromInt(content.y);
    const w: f32 = @floatFromInt(content.width);
    const h: f32 = @floatFromInt(content.height);
    if (x < left or y < top or x >= left + w or y >= top + h) return null;
    var best: ?PaneEdge = null;
    var distance: f32 = std.math.inf(f32);
    for ([_]f32{ x - left, left + w - x, y - top, top + h - y }, [_]f32{ w, w, h, h }, [_]PaneEdge{ .left, .right, .top, .bottom }) |d, span, edge| {
        if (d < @min(band, span / 6) and d < distance) {
            distance = d;
            best = edge;
        }
    }
    return best;
}

/// A docked pane keeps its scope; a tiled pane defaults to a workspace dock.
/// `flip` selects the other scope.
pub fn scopeFor(mux: *Mux, pane: *const Pane, flip: bool) DockScope {
    const scope: DockScope = if (mux.paneDock(pane)) |location| location.scope else .workspace;
    if (!flip) return scope;
    return if (scope == .global) .workspace else .global;
}

fn docksFor(mux: *Mux, scope: DockScope) ?*dock.Docks {
    return switch (scope) {
        .global => &mux.global_docks,
        .workspace => &(mux.activeWorkspace() orelse return null).docks,
    };
}

pub fn status(mux: *Mux, pane: *Pane, target: Target) Status {
    const ws = mux.activeWorkspace() orelse return .none;
    if (mux.paneDock(pane)) |current| {
        if (current.edge == target.edge and current.scope == target.scope) return .none;
        if (current.workspace != null and current.workspace != ws) return .none;
    } else {
        const tab = ws.tabContainingPane(pane) orelse return .none;
        if (tab.panes.items.len <= 1) return .none;
    }
    const docks = docksFor(mux, target.scope) orelse return .none;
    const occupant = docks.slot(target.edge).pane;
    return if (occupant == null or occupant == pane) .ok else .occupied;
}

/// The share `pane` starts with once docked: a moved dock keeps its own.
pub fn shareFor(mux: *Mux, pane: *const Pane) f32 {
    return if (mux.paneDock(pane)) |location| location.ratio else default_share;
}

pub const max_docks = 8;

/// The thickness of every shown dock except `skip`.
pub fn measure(global: *const dock.Docks, local: *const dock.Docks, skip: ?*const Pane, content: Bounds, cell_w: u32, cell_h: u32, out: *[max_docks]dock.Thickness) []dock.Thickness {
    var g = global.*;
    var l = local.*;
    var bounds = content;
    var leaves: [max_docks]types.LayoutLeaf = undefined;
    var written: usize = 0;
    g.carve(&bounds, &leaves, &written, cell_w, cell_h);
    const global_count = written;
    l.carve(&bounds, &leaves, &written, cell_w, cell_h);
    var len: usize = 0;
    for (leaves[0..written], 0..) |leaf, i| {
        if (leaf.pane == skip) continue;
        const edge = (if (i < global_count) g.edgeOf(leaf.pane) else l.edgeOf(leaf.pane)) orelse continue;
        const size = if (dock.directionFor(edge) == .vertical) leaf.bounds.width else leaf.bounds.height;
        out[len] = .{ .pane = leaf.pane, .edge = edge, .size = size };
        len += 1;
    }
    return out[0..len];
}

/// Re-share the shown docks so each keeps its measured thickness. Global
/// docks carve before workspace docks, so moving a dock between scopes
/// changes the regions the others share.
pub fn keepSizes(global: *dock.Docks, local: *dock.Docks, kept: []const dock.Thickness, content: Bounds, cell_w: u32, cell_h: u32) void {
    var bounds = content;
    global.keepThickness(&bounds, kept, cell_w, cell_h);
    local.keepThickness(&bounds, kept, cell_w, cell_h);
}

/// Bounds `pane` would occupy after docking at `target`, found by moving it
/// in copies of the docks the same way a drop does.
pub fn preview(mux: *Mux, pane: *Pane, target: Target, content: Bounds, cell_w: u32, cell_h: u32) ?Bounds {
    if (status(mux, pane, target) != .ok) return null;
    const ws = mux.activeWorkspace() orelse return null;
    var buf: [max_docks]dock.Thickness = undefined;
    const kept = measure(&mux.global_docks, &ws.docks, null, content, cell_w, cell_h, &buf);
    var global = mux.global_docks;
    var local = ws.docks;
    _ = global.remove(pane);
    _ = local.remove(pane);
    const docks = if (target.scope == .global) &global else &local;
    docks.place(target.edge, pane, shareFor(mux, pane)) catch return null;
    keepSizes(&global, &local, kept, content, cell_w, cell_h);
    var bounds = content;
    var leaves: [max_docks]types.LayoutLeaf = undefined;
    var written: usize = 0;
    global.carve(&bounds, &leaves, &written, cell_w, cell_h);
    local.carve(&bounds, &leaves, &written, cell_w, cell_h);
    for (leaves[0..written]) |leaf| if (leaf.pane == pane) return leaf.bounds;
    return null;
}

test "edge bands pick the nearest content edge and stay out of the middle" {
    const b: Bounds = .{ .x = 100, .y = 50, .width = 600, .height = 300 };
    try std.testing.expectEqual(@as(?PaneEdge, .left), edgeAt(b, 110, 200, 32));
    try std.testing.expectEqual(@as(?PaneEdge, .right), edgeAt(b, 690, 200, 32));
    try std.testing.expectEqual(@as(?PaneEdge, .top), edgeAt(b, 400, 55, 32));
    try std.testing.expectEqual(@as(?PaneEdge, .bottom), edgeAt(b, 400, 345, 32));
    try std.testing.expectEqual(@as(?PaneEdge, null), edgeAt(b, 400, 200, 32));
    try std.testing.expectEqual(@as(?PaneEdge, null), edgeAt(b, 90, 200, 32));
    // A 300px-tall area caps the band at 50px even when more is requested.
    try std.testing.expectEqual(@as(?PaneEdge, .top), edgeAt(b, 400, 95, 200));
    try std.testing.expectEqual(@as(?PaneEdge, null), edgeAt(b, 400, 105, 200));
}
