const std = @import("std");
const Pane = @import("../pane.zig").Pane;
const types = @import("types.zig");
const tab_mod = @import("tab.zig");
const workspace_mod = @import("workspace.zig");
const mux_mod = @import("mux.zig");

const PaneBounds = types.PaneBounds;
const LayoutLeaf = types.LayoutLeaf;
const MAX_LAYOUT_LEAVES = types.MAX_LAYOUT_LEAVES;
const Tab = tab_mod.Tab;
const Workspace = workspace_mod.Workspace;
const Mux = mux_mod.Mux;

test "pane focus follows nearest matching split subtree" {
    const allocator = std.testing.allocator;

    var mux = Mux.init(allocator);
    defer mux.workspaces.deinit(allocator);

    const workspace = try allocator.create(Workspace);
    defer allocator.destroy(workspace);
    workspace.* = Workspace.init(allocator, 1);
    defer workspace.tabs.deinit(allocator);

    const tab = try allocator.create(Tab);
    defer allocator.destroy(tab);
    tab.* = Tab.init(allocator, 2);
    defer {
        if (tab.root_split) |root| {
            root.deinit(allocator);
            allocator.destroy(root);
        }
        for (tab.panes.items) |pane| allocator.destroy(pane);
        tab.panes.deinit(allocator);
    }

    try workspace.appendTab(tab);
    try mux.workspaces.append(allocator, workspace);
    mux.active_workspace = workspace;

    const top = try allocator.create(Pane);
    top.* = Pane.init(allocator);
    try tab.appendPane(top);

    const bottom_left = try allocator.create(Pane);
    bottom_left.* = Pane.init(allocator);
    try tab.splitActivePane(bottom_left, .horizontal, 0.5);

    tab.active_pane = bottom_left;

    const bottom_right = try allocator.create(Pane);
    bottom_right.* = Pane.init(allocator);
    try tab.splitActivePane(bottom_right, .vertical, 0.5);

    mux.focusPaneInDirection(.left, 1200, 800);
    try std.testing.expect(tab.active_pane == bottom_left);

    mux.focusPaneInDirection(.up, 1200, 800);
    try std.testing.expect(tab.active_pane == top);
}

test "split pane ratio applies to new pane" {
    const allocator = std.testing.allocator;

    const tab = try allocator.create(Tab);
    defer allocator.destroy(tab);
    tab.* = Tab.init(allocator, 1);
    defer {
        if (tab.root_split) |root| {
            root.deinit(allocator);
            allocator.destroy(root);
        }
        for (tab.panes.items) |pane| allocator.destroy(pane);
        tab.panes.deinit(allocator);
    }

    const first = try allocator.create(Pane);
    first.* = Pane.init(allocator);
    try tab.appendPane(first);

    const second = try allocator.create(Pane);
    second.* = Pane.init(allocator);
    try tab.splitActivePane(second, .vertical, 0.3);

    var layout_buf: [MAX_LAYOUT_LEAVES]LayoutLeaf = undefined;
    const bounds = PaneBounds{ .x = 0, .y = 0, .width = 1000, .height = 100 };
    const leaves = tab.computeLayoutInBounds(bounds, &layout_buf, 0, 0);

    try std.testing.expectEqual(@as(usize, 2), leaves.len);
    try std.testing.expectEqual(@as(u32, 299), leaves[1].bounds.width);
    try std.testing.expectEqual(@as(u32, 700), leaves[0].bounds.width);
}

test "horizontal split rounds to nearest whole row" {
    const allocator = std.testing.allocator;

    const tab = try allocator.create(Tab);
    defer allocator.destroy(tab);
    tab.* = Tab.init(allocator, 1);
    defer {
        if (tab.root_split) |root| {
            root.deinit(allocator);
            allocator.destroy(root);
        }
        for (tab.panes.items) |pane| allocator.destroy(pane);
        tab.panes.deinit(allocator);
    }

    const first = try allocator.create(Pane);
    first.* = Pane.init(allocator);
    try tab.appendPane(first);

    const second = try allocator.create(Pane);
    second.* = Pane.init(allocator);
    try tab.splitActivePane(second, .horizontal, @as(f32, 16.0 / 34.0));

    var layout_buf: [MAX_LAYOUT_LEAVES]LayoutLeaf = undefined;
    const bounds = PaneBounds{ .x = 0, .y = 0, .width = 1000, .height = 34 * 20 + 1 };
    const leaves = tab.computeLayoutInBounds(bounds, &layout_buf, 10, 20);

    try std.testing.expectEqual(@as(usize, 2), leaves.len);
    try std.testing.expectEqual(@as(u32, 18 * 20), leaves[0].bounds.height);
    try std.testing.expectEqual(@as(u32, 16 * 20 + 1), leaves[1].bounds.height);
}

test "maximized pane takes full tab bounds" {
    const allocator = std.testing.allocator;

    const tab = try allocator.create(Tab);
    defer allocator.destroy(tab);
    tab.* = Tab.init(allocator, 1);
    defer {
        if (tab.root_split) |root| {
            root.deinit(allocator);
            allocator.destroy(root);
        }
        for (tab.panes.items) |pane| allocator.destroy(pane);
        tab.panes.deinit(allocator);
    }

    const first = try allocator.create(Pane);
    first.* = Pane.init(allocator);
    try tab.appendPane(first);

    const second = try allocator.create(Pane);
    second.* = Pane.init(allocator);
    try tab.splitActivePane(second, .vertical, 0.5);

    var layout_buf: [MAX_LAYOUT_LEAVES]LayoutLeaf = undefined;
    const bounds = PaneBounds{ .x = 10, .y = 20, .width = 1200, .height = 800 };

    _ = tab.setPaneMaximized(second, true, false);
    const leaves = tab.computeLayoutInBounds(bounds, &layout_buf, 0, 0);

    try std.testing.expectEqual(@as(usize, 1), leaves.len);
    try std.testing.expect(leaves[0].pane == second);
    try std.testing.expectEqualDeep(bounds, leaves[0].bounds);
}

test "maximized pane background keeps tiled panes visible" {
    const allocator = std.testing.allocator;

    const tab = try allocator.create(Tab);
    defer allocator.destroy(tab);
    tab.* = Tab.init(allocator, 1);
    defer {
        if (tab.root_split) |root| {
            root.deinit(allocator);
            allocator.destroy(root);
        }
        for (tab.panes.items) |pane| allocator.destroy(pane);
        tab.panes.deinit(allocator);
    }

    const left = try allocator.create(Pane);
    left.* = Pane.init(allocator);
    try tab.appendPane(left);

    const right = try allocator.create(Pane);
    right.* = Pane.init(allocator);
    try tab.splitActivePane(right, .vertical, 0.5);

    var layout_buf: [MAX_LAYOUT_LEAVES]LayoutLeaf = undefined;
    const bounds = PaneBounds{ .x = 0, .y = 0, .width = 1000, .height = 700 };

    _ = tab.setPaneMaximized(right, true, true);
    const leaves = tab.computeLayoutInBounds(bounds, &layout_buf, 0, 0);

    try std.testing.expectEqual(@as(usize, 3), leaves.len);
    try std.testing.expect(leaves[0].pane == left);
    try std.testing.expect(leaves[1].pane == right);
    try std.testing.expect(leaves[2].pane == right);
    try std.testing.expectEqualDeep(bounds, leaves[2].bounds);
}
