const std = @import("std");
const types = @import("types.zig");
const layout = @import("layout.zig");
const Tab = @import("tab.zig").Tab;
const Pane = @import("../pane.zig").Pane;
const Bounds = types.PaneBounds;
const Node = types.SplitNode;

pub const Zone = enum {
    left,
    right,
    top,
    bottom,
    swap,

    pub fn label(self: Zone) []const u8 {
        return switch (self) {
            .left => "Left",
            .right => "Right",
            .top => "Top",
            .bottom => "Bottom",
            .swap => "Swap",
        };
    }

    fn first(self: Zone) bool {
        return self == .left or self == .top;
    }

    fn direction(self: Zone) types.SplitDirection {
        return if (self == .left or self == .right) .vertical else .horizontal;
    }
};

pub fn zoneAt(b: Bounds, x: f32, y: f32) Zone {
    const fx = (x - @as(f32, @floatFromInt(b.x))) / @as(f32, @floatFromInt(@max(1, b.width)));
    const fy = (y - @as(f32, @floatFromInt(b.y))) / @as(f32, @floatFromInt(@max(1, b.height)));
    var distance: f32 = 0.25;
    var zone: Zone = .swap;
    for ([_]f32{ fx, 1 - fx, fy, 1 - fy }, [_]Zone{ .left, .right, .top, .bottom }) |d, candidate| {
        if (d < distance) {
            distance = d;
            zone = candidate;
        }
    }
    return zone;
}

pub fn eligible(tab: *Tab, pane: *Pane) bool {
    return tab.maximized_pane == null and !pane.is_hidden and !pane.is_floating and
        layout.findPaneLeafNode(tab.root_split orelse return false, pane) != null;
}

fn depth(node: *Node, pane: *Pane, level: usize) ?usize {
    if (node.kind == .pane) return if (node.pane == pane) level else null;
    return depth(node.first.?, pane, level + 1) orelse depth(node.second.?, pane, level + 1);
}

pub fn canDrop(source: *Tab, pane: *Pane, dest: *Tab, target: *Pane, zone: Zone) bool {
    if (pane == target or !eligible(source, pane) or !eligible(dest, target)) return false;
    if (zone == .swap) return true;
    if (source != dest and dest.panes.items.len >= types.MAX_LAYOUT_LEAVES) return false;
    return depth(dest.root_split.?, target, 1).? < @import("../session/layout.zig").max_depth;
}

pub fn preview(source: *Tab, pane: *Pane, dest: *Tab, target: *Pane, zone: Zone, bounds: Bounds, cell_w: u32, cell_h: u32) ?Bounds {
    if (!canDrop(source, pane, dest, target, zone)) return null;
    var leaves: [types.MAX_LAYOUT_LEAVES]types.LayoutLeaf = undefined;
    var count: usize = 0;
    const skip = if (source == dest and zone != .swap) pane else null;
    layout.layoutVisibleTree(dest.root_split.?, bounds, &leaves, &count, skip, cell_w, cell_h);
    for (leaves[0..count]) |leaf| {
        if (leaf.pane != target) continue;
        if (zone == .swap) return leaf.bounds;
        const children = layout.splitChildBounds(&.{ .kind = .split, .direction = zone.direction(), .ratio = 0.5 }, leaf.bounds, cell_w, cell_h);
        if (children[0].width == 0 or children[0].height == 0 or children[1].width == 0 or children[1].height == 0) return null;
        return if (zone.first()) children[0] else children[1];
    }
    return null;
}

/// All allocations precede detaching the live pane. The target leaf is looked
/// up again afterwards because collapsing the old split can relocate it.
pub fn place(source: *Tab, pane: *Pane, dest: *Tab, target: *Pane, zone: Zone) !bool {
    if (!canDrop(source, pane, dest, target, zone)) return false;
    if (zone == .swap) {
        const a = layout.findPaneLeafNode(source.root_split.?, pane).?;
        const b = layout.findPaneLeafNode(dest.root_split.?, target).?;
        a.pane = target;
        b.pane = pane;
        if (source != dest) {
            for (source.panes.items) |*p| if (p.* == pane) {
                p.* = target;
                break;
            };
            for (dest.panes.items) |*p| if (p.* == target) {
                p.* = pane;
                break;
            };
            if (source.active_pane == pane) source.active_pane = target;
            // These hints belong to the layout slot, not to the live process.
            std.mem.swap(usize, &pane.restore_anchor_id, &target.restore_anchor_id);
            std.mem.swap(f32, &pane.restore_ratio, &target.restore_ratio);
            std.mem.swap(bool, &pane.restore_split_horizontal, &target.restore_split_horizontal);
            std.mem.swap(bool, &pane.restore_place_first, &target.restore_place_first);
            std.mem.swap(?types.PaneEdge, &pane.placed_edge, &target.placed_edge);
            for (source.panes.items) |p| if (p.restore_anchor_id == pane.id) {
                p.restore_anchor_id = target.id;
            };
            for (dest.panes.items) |p| if (p.restore_anchor_id == target.id) {
                p.restore_anchor_id = pane.id;
            };
        }
    } else {
        if (source != dest) try dest.panes.ensureUnusedCapacity(dest.allocator, 1);
        const existing = try dest.allocator.create(Node);
        errdefer dest.allocator.destroy(existing);
        const moved = try dest.allocator.create(Node);
        source.detachPane(pane);
        const leaf = layout.findPaneLeafNode(dest.root_split.?, target).?;
        existing.* = leaf.*;
        moved.* = Node.initPane(pane);
        leaf.* = if (zone.first()) Node.initSplit(moved, existing, zone.direction(), 0.5) else Node.initSplit(existing, moved, zone.direction(), 0.5);
        pane.restore_anchor_id = target.id;
        pane.restore_ratio = 0.5;
        pane.restore_split_horizontal = zone.direction() == .horizontal;
        pane.restore_place_first = zone.first();
        pane.placed_edge = null;
        dest.panes.appendAssumeCapacity(pane);
    }
    dest.active_pane = pane;
    return true;
}

fn freeTestTab(tab: *Tab) void {
    if (tab.root_split) |root| {
        root.deinit(tab.allocator);
        tab.allocator.destroy(root);
    }
    tab.panes.deinit(tab.allocator);
}

test "edge drop projects the collapsed split and preserves the dragged pane" {
    const a = std.testing.allocator;
    var tab = Tab.init(a, 1);
    defer freeTestTab(&tab);
    var pane = Pane.init(a);
    pane.id = 11;
    var target = Pane.init(a);
    target.id = 12;
    try tab.appendPane(&target);
    try tab.splitPane(&target, &pane, .vertical, 0.5);
    const b: Bounds = .{ .x = 3, .y = 19, .width = 801, .height = 401 };
    const expected = preview(&tab, &pane, &tab, &target, .top, b, 8, 20).?;
    try std.testing.expectEqual(b.width, expected.width);
    try std.testing.expect(try place(&tab, &pane, &tab, &target, .top));
    var leaves: [2]types.LayoutLeaf = undefined;
    _ = tab.computeLayoutInBounds(b, &leaves, 8, 20);
    try std.testing.expectEqual(&pane, leaves[0].pane);
    try std.testing.expectEqual(expected, leaves[0].bounds);
    try std.testing.expectEqual(&target, leaves[1].pane);
    try std.testing.expectEqual(@as(usize, 2), tab.panes.items.len);
}

test "cross-tab swap exchanges live panes without leaving duplicate membership" {
    const a = std.testing.allocator;
    var source = Tab.init(a, 1);
    defer freeTestTab(&source);
    var dest = Tab.init(a, 2);
    defer freeTestTab(&dest);
    var pane = Pane.init(a);
    var target = Pane.init(a);
    try source.appendPane(&pane);
    try dest.appendPane(&target);
    try std.testing.expect(try place(&source, &pane, &dest, &target, .swap));
    try std.testing.expectEqual(&target, source.panes.items[0]);
    try std.testing.expectEqual(&target, source.activePane().?);
    try std.testing.expectEqual(&pane, dest.panes.items[0]);
    try std.testing.expectEqual(&pane, dest.activePane().?);
    try std.testing.expect(!try place(&source, &pane, &dest, &target, .swap));
}

test "drop zones are relative to the target pane on both axes" {
    const b: Bounds = .{ .x = 100, .y = 100, .width = 500, .height = 200 };
    try std.testing.expectEqual(Zone.left, zoneAt(b, 110, 200));
    try std.testing.expectEqual(Zone.right, zoneAt(b, 590, 200));
    try std.testing.expectEqual(Zone.top, zoneAt(b, 350, 110));
    try std.testing.expectEqual(Zone.bottom, zoneAt(b, 350, 290));
    try std.testing.expectEqual(Zone.swap, zoneAt(b, 350, 200));
}
