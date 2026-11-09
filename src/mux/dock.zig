//! Window-edge dock slots. A docked pane lives outside every tab's split
//! tree, so it stays on screen across tab switches. Docks are carved out of
//! the content area before the active tab is laid out.
const std = @import("std");
const Pane = @import("../pane.zig").Pane;
const GhosttyRuntime = @import("../term/ghostty.zig").Runtime;
const types = @import("types.zig");
const layout = @import("layout.zig");

const PaneEdge = types.PaneEdge;
const PaneBounds = types.PaneBounds;
const LayoutLeaf = types.LayoutLeaf;
const SplitNode = types.SplitNode;
const DividerHit = types.DividerHit;

/// `global` docks belong to the window and show in every workspace;
/// `workspace` docks show only while their workspace is active.
pub const DockScope = enum { global, workspace };

/// Carve order: side docks span the full height, top/bottom fit between them.
const EDGE_ORDER = [_]PaneEdge{ .left, .right, .top, .bottom };

pub const Docks = struct {
    slots: [4]Slot = @splat(.{}),

    pub const Slot = struct {
        pane: ?*Pane = null,
        /// Childless split used only as the ratio holder, so divider drags and
        /// cell snapping share the tab split code. `ratio` is the first (left
        /// or top) share of the region the dock is carved from.
        node: SplitNode = .{ .kind = .split },
    };

    pub const Iterator = struct {
        docks: *Docks,
        index: usize = 0,

        pub fn next(self: *Iterator) ?*Pane {
            while (self.index < self.docks.slots.len) {
                const entry = &self.docks.slots[self.index];
                self.index += 1;
                if (entry.pane) |pane| return pane;
            }
            return null;
        }
    };

    pub fn iterator(self: *Docks) Iterator {
        return .{ .docks = self };
    }

    pub fn slot(self: *Docks, edge: PaneEdge) *Slot {
        return &self.slots[@backingInt(edge)];
    }

    pub fn edgeOf(self: *const Docks, pane: *const Pane) ?PaneEdge {
        for (self.slots, 0..) |entry, index| {
            if (entry.pane == pane) return @fromBackingInt(@intCast(index));
        }
        return null;
    }

    pub fn contains(self: *const Docks, pane: *const Pane) bool {
        return self.edgeOf(pane) != null;
    }

    pub fn containsNode(self: *const Docks, node: *const SplitNode) bool {
        for (&self.slots) |*entry| {
            if (entry.pane != null and &entry.node == node) return true;
        }
        return false;
    }

    pub fn isEmpty(self: *const Docks) bool {
        for (self.slots) |entry| if (entry.pane != null) return false;
        return true;
    }

    /// `share` is the dock's share of the region it is carved from.
    pub fn place(self: *Docks, edge: PaneEdge, pane: *Pane, share: f32) !void {
        const entry = self.slot(edge);
        if (entry.pane != null and entry.pane != pane) return error.DockOccupied;
        const clamped = std.math.clamp(share, 0.05, 0.95);
        entry.pane = pane;
        entry.node = .{
            .kind = .split,
            .direction = directionFor(edge),
            .ratio = if (placesFirst(edge)) clamped else 1.0 - clamped,
        };
    }

    pub fn remove(self: *Docks, pane: *const Pane) ?PaneEdge {
        const edge = self.edgeOf(pane) orelse return null;
        self.slot(edge).pane = null;
        return edge;
    }

    pub fn size(self: *Docks, edge: PaneEdge) f32 {
        const entry = self.slot(edge);
        return if (placesFirst(edge)) entry.node.ratio else 1.0 - entry.node.ratio;
    }

    /// Grow (`delta > 0`) or shrink the dock holding `pane`.
    pub fn resize(self: *Docks, pane: *const Pane, delta: f32) bool {
        const edge = self.edgeOf(pane) orelse return false;
        const entry = self.slot(edge);
        const signed = if (placesFirst(edge)) delta else -delta;
        entry.node.ratio = std.math.clamp(entry.node.ratio + signed, 0.05, 0.95);
        return true;
    }

    /// Carve visible docks out of `bounds`, appending their leaves to `out`.
    /// `bounds` is left holding the remaining (tab) region.
    pub fn carve(self: *Docks, bounds: *PaneBounds, out: []LayoutLeaf, written: *usize, cell_w: u32, cell_h: u32) void {
        for (EDGE_ORDER) |edge| {
            const entry = self.slot(edge);
            const pane = entry.pane orelse continue;
            if (pane.is_hidden) continue;
            const dock_bounds, const rest = splitFor(entry, edge, bounds.*, cell_w, cell_h);
            if (written.* < out.len) {
                out[written.*] = .{ .pane = pane, .bounds = dock_bounds };
                written.* += 1;
            }
            bounds.* = rest;
        }
    }

    /// Hit-test dock seams in carve order; `bounds` is narrowed like `carve`.
    pub fn hitTestDivider(self: *Docks, bounds: *PaneBounds, mx: f32, my: f32, radius: f32, cell_w: u32, cell_h: u32) ?DividerHit {
        for (EDGE_ORDER) |edge| {
            const entry = self.slot(edge);
            const pane = entry.pane orelse continue;
            if (pane.is_hidden) continue;
            const region = bounds.*;
            const dock_bounds, const rest = splitFor(entry, edge, region, cell_w, cell_h);
            const seam: f32, const along: f32, const start: f32, const span: f32 = switch (edge) {
                .left => .{ @floatFromInt(dock_bounds.x + dock_bounds.width), my, @floatFromInt(region.y), @floatFromInt(region.height) },
                .right => .{ @floatFromInt(dock_bounds.x), my, @floatFromInt(region.y), @floatFromInt(region.height) },
                .top => .{ @floatFromInt(dock_bounds.y + dock_bounds.height), mx, @floatFromInt(region.x), @floatFromInt(region.width) },
                .bottom => .{ @floatFromInt(dock_bounds.y), mx, @floatFromInt(region.x), @floatFromInt(region.width) },
            };
            const across = switch (edge) {
                .left, .right => mx,
                .top, .bottom => my,
            };
            if (along >= start and along < start + span and @abs(across - seam) <= radius) {
                return .{ .node = &entry.node, .bounds = region };
            }
            bounds.* = rest;
        }
        return null;
    }

    pub fn deinit(self: *Docks, allocator: std.mem.Allocator, runtime: *GhosttyRuntime) void {
        for (&self.slots) |*entry| {
            if (entry.pane) |pane| {
                pane.deinit(runtime);
                allocator.destroy(pane);
            }
            entry.* = .{};
        }
    }

    fn splitFor(entry: *const Slot, edge: PaneEdge, bounds: PaneBounds, cell_w: u32, cell_h: u32) struct { PaneBounds, PaneBounds } {
        const first, const second = layout.splitChildBounds(&entry.node, bounds, cell_w, cell_h);
        return if (placesFirst(edge)) .{ first, second } else .{ second, first };
    }
};

pub fn directionFor(edge: PaneEdge) types.SplitDirection {
    return switch (edge) {
        .left, .right => .vertical,
        .top, .bottom => .horizontal,
    };
}

pub fn placesFirst(edge: PaneEdge) bool {
    return edge == .left or edge == .top;
}
