const std = @import("std");
const Pane = @import("../pane.zig").Pane;
const GhosttyRuntime = @import("../term/ghostty.zig").Runtime;
const types = @import("types.zig");
const layout = @import("layout.zig");

const SplitNode = types.SplitNode;
const SplitDirection = types.SplitDirection;
const FocusDirection = types.FocusDirection;
const PaneBounds = types.PaneBounds;
const LayoutLeaf = types.LayoutLeaf;
const MAX_LAYOUT_LEAVES = types.MAX_LAYOUT_LEAVES;

pub const Tab = struct {
    allocator: std.mem.Allocator,
    id: usize,
    panes: std.ArrayList(*Pane),
    active_pane: ?*Pane = null,
    root_split: ?*SplitNode = null,
    maximized_pane: ?*Pane = null,
    maximized_show_background: bool = false,

    pub const PaneIterator = struct {
        tab: *Tab,
        index: usize = 0,

        pub fn next(self: *PaneIterator) ?*Pane {
            if (self.index >= self.tab.panes.items.len) return null;
            const pane = self.tab.panes.items[self.index];
            self.index += 1;
            return pane;
        }
    };

    pub const Leaf = struct {
        node: *SplitNode,
        pane: *Pane,
    };

    pub const LeafIterator = struct {
        stack: [64]*SplitNode = undefined,
        len: usize = 0,

        pub fn init(root: ?*SplitNode) LeafIterator {
            var iter = LeafIterator{};
            if (root) |node| {
                iter.stack[0] = node;
                iter.len = 1;
            }
            return iter;
        }

        pub fn next(self: *LeafIterator) ?Leaf {
            while (self.len > 0) {
                self.len -= 1;
                const node = self.stack[self.len];
                switch (node.kind) {
                    .pane => {
                        const pane = node.pane orelse continue;
                        return .{ .node = node, .pane = pane };
                    },
                    .split => {
                        if (node.second) |second| {
                            self.stack[self.len] = second;
                            self.len += 1;
                        }
                        if (node.first) |first| {
                            self.stack[self.len] = first;
                            self.len += 1;
                        }
                    },
                }
            }
            return null;
        }
    };

    pub fn init(allocator: std.mem.Allocator, id: usize) Tab {
        return .{
            .allocator = allocator,
            .id = id,
            .panes = .empty,
        };
    }

    pub fn deinit(self: *Tab, runtime: *GhosttyRuntime) void {
        if (self.root_split) |root| {
            root.deinit(self.allocator);
            self.allocator.destroy(root);
        }
        for (self.panes.items) |pane| {
            pane.deinit(runtime);
            self.allocator.destroy(pane);
        }
        self.panes.deinit(self.allocator);
        self.* = Tab.init(self.allocator, self.id);
    }

    pub fn appendPane(self: *Tab, pane: *Pane) !void {
        try self.panes.append(self.allocator, pane);
        if (self.active_pane == null) {
            self.active_pane = pane;
            try self.initRootSplitForPane(pane);
        }
    }

    pub fn activePane(self: *Tab) ?*Pane {
        return self.active_pane;
    }

    pub fn paneIterator(self: *Tab) PaneIterator {
        return .{ .tab = self };
    }

    pub fn leafIterator(self: *Tab) LeafIterator {
        return LeafIterator.init(self.root_split);
    }

    pub fn splitActivePane(self: *Tab, new_pane: *Pane, direction: SplitDirection, ratio: f32) !void {
        const current_pane = self.active_pane orelse return error.NoActivePane;
        current_pane.is_floating = false;
        const target = self.findPaneLeaf(current_pane) orelse return error.ActivePaneMissingFromLayout;

        const existing_leaf = try self.allocator.create(SplitNode);
        errdefer self.allocator.destroy(existing_leaf);
        existing_leaf.* = SplitNode.initPane(current_pane);

        const new_leaf = try self.allocator.create(SplitNode);
        errdefer self.allocator.destroy(new_leaf);
        new_leaf.* = SplitNode.initPane(new_pane);

        target.* = SplitNode.initSplit(existing_leaf, new_leaf, direction, 1.0 - ratio);
        try self.panes.append(self.allocator, new_pane);
        self.active_pane = new_pane;
        self.maximized_pane = null;
    }

    pub fn activeSplitRoot(self: *Tab) ?*SplitNode {
        return self.root_split;
    }

    /// Remove `pane` from this tab's split tree and panes list.
    /// The sibling of the removed leaf replaces the parent split node (collapsing
    /// the split). Focus moves to the sibling; if no sibling exists the root is
    /// cleared. Returns true if the tab is now empty (caller should close it).
    pub fn closePane(self: *Tab, runtime: *GhosttyRuntime, pane: *Pane) bool {
        if (self.maximized_pane == pane) self.maximized_pane = null;
        // Collapse the split tree.
        if (self.root_split) |root| {
            if (root.kind == .pane and root.pane == pane) {
                // Last pane — clear root.
                root.deinit(self.allocator);
                self.allocator.destroy(root);
                self.root_split = null;
            } else {
                // Find and replace the parent split with the sibling.
                const sibling = layout.removePaneFromTree(self.allocator, root, pane);
                // `sibling` is the new focus candidate (may be null if not found).
                if (sibling) |s| {
                    if (self.active_pane == pane) {
                        self.active_pane = s;
                    }
                }
            }
        }

        // Remove from panes list and free.
        for (self.panes.items, 0..) |p, i| {
            if (p == pane) {
                _ = self.panes.orderedRemove(i);
                break;
            }
        }
        pane.deinit(runtime);
        self.allocator.destroy(pane);

        // If active_pane pointed at the dead pane, pick any survivor.
        if (self.active_pane == pane or self.active_pane == null) {
            self.active_pane = if (self.panes.items.len > 0) self.panes.items[self.panes.items.len - 1] else null;
        }

        return self.panes.items.len == 0;
    }

    /// Remove `pane` from this tab's split tree and panes list without freeing.
    /// The pane is returned intact for reuse elsewhere (e.g. moving to another tab).
    pub fn detachPane(self: *Tab, pane: *Pane) void {
        if (self.maximized_pane == pane) self.maximized_pane = null;
        if (self.root_split) |root| {
            if (root.kind == .pane and root.pane == pane) {
                root.deinit(self.allocator);
                self.allocator.destroy(root);
                self.root_split = null;
            } else {
                const sibling = layout.removePaneFromTree(self.allocator, root, pane);
                if (sibling) |s| {
                    if (self.active_pane == pane) self.active_pane = s;
                }
            }
        }
        for (self.panes.items, 0..) |p, i| {
            if (p == pane) {
                _ = self.panes.orderedRemove(i);
                break;
            }
        }
        if (self.active_pane == pane or self.active_pane == null) {
            self.active_pane = if (self.panes.items.len > 0) self.panes.items[self.panes.items.len - 1] else null;
        }
    }

    /// Compute pixel bounds for every leaf pane in this tab's split tree.
    /// Returns a slice into `out` (length = number of panes).
    pub fn computeLayout(self: *Tab, window_width: u32, window_height: u32, out: []LayoutLeaf) []LayoutLeaf {
        return self.computeLayoutInBounds(.{
            .x = 0,
            .y = 0,
            .width = window_width,
            .height = window_height,
        }, out, 0, 0);
    }

    pub fn computeLayoutInBounds(self: *Tab, bounds: PaneBounds, out: []LayoutLeaf, cell_w: u32, cell_h: u32) []LayoutLeaf {
        var written: usize = 0;
        if (self.maximized_pane) |pane| {
            if (self.maximized_show_background) {
                if (self.root_split) |root| {
                    layout.layoutVisibleTree(root, bounds, out, &written, null, cell_w, cell_h);
                }
            }
            if (written < out.len) {
                out[written] = .{ .pane = pane, .bounds = bounds };
                written += 1;
            }
        } else if (self.root_split) |root| {
            layout.layoutVisibleTree(root, bounds, out, &written, null, cell_w, cell_h);
        }

        for (self.panes.items) |pane| {
            if (!pane.is_floating) continue;
            if (self.maximized_pane == pane) continue;
            if (written >= out.len) break;
            out[written] = .{ .pane = pane, .bounds = layout.floatingPaneBounds(bounds, pane) };
            written += 1;
        }

        return out[0..written];
    }

    pub fn isPaneMaximized(self: *const Tab, pane: *const Pane) bool {
        return self.maximized_pane == pane;
    }

    pub fn setPaneMaximized(self: *Tab, pane: *Pane, enabled: bool, show_background: bool) bool {
        if (!enabled) {
            self.maximized_pane = null;
            self.maximized_show_background = false;
            return false;
        }
        self.maximized_pane = pane;
        self.maximized_show_background = show_background;
        self.active_pane = pane;
        return true;
    }

    pub fn togglePaneMaximized(self: *Tab, pane: *Pane, show_background: bool) bool {
        if (self.maximized_pane == pane) {
            if (self.maximized_show_background != show_background) {
                self.maximized_show_background = show_background;
                return true;
            }
            return self.setPaneMaximized(pane, false, false);
        }
        return self.setPaneMaximized(pane, true, show_background);
    }

    pub fn setPaneFloating(self: *Tab, pane: *Pane, floating: bool) bool {
        if (pane.is_floating == floating) return floating;
        if (floating) {
            if (self.active_pane) |active| {
                if (active != pane and !active.is_floating) {
                    pane.restore_anchor_id = @intFromPtr(active);
                }
            }
            pane.is_floating = true;
        } else {
            if (self.findPaneLeaf(pane) == null) {
                if (!self.reinsertFloatingPane(pane)) return false;
            }
            pane.is_floating = false;
            pane.floating_x = 0.15;
            pane.floating_y = 0.1;
            pane.floating_width = 0.7;
            pane.floating_height = 0.75;
            self.active_pane = pane;
            return true;
        }
        if (self.maximized_pane == pane and floating) self.maximized_pane = null;
        if (floating) self.active_pane = pane;
        return pane.is_floating;
    }

    pub fn setFloatingPaneBounds(self: *Tab, pane: *Pane, x: f32, y: f32, width: f32, height: f32) bool {
        _ = self;
        pane.floating_x = std.math.clamp(x, 0.0, 1.0);
        pane.floating_y = std.math.clamp(y, 0.0, 1.0);
        pane.floating_width = std.math.clamp(width, 0.2, 1.0);
        pane.floating_height = std.math.clamp(height, 0.15, 1.0);
        if (pane.floating_x + pane.floating_width > 1.0) pane.floating_x = 1.0 - pane.floating_width;
        if (pane.floating_y + pane.floating_height > 1.0) pane.floating_y = 1.0 - pane.floating_height;
        if (pane.floating_x < 0.0) pane.floating_x = 0.0;
        if (pane.floating_y < 0.0) pane.floating_y = 0.0;
        return true;
    }

    pub fn movePane(self: *Tab, pane: *Pane, direction: FocusDirection, window_width: u32, window_height: u32, amount: f32) bool {
        if (pane.is_floating) {
            const delta = std.math.clamp(amount, 0.01, 0.5);
            switch (direction) {
                .left => pane.floating_x -= delta,
                .right => pane.floating_x += delta,
                .up => pane.floating_y -= delta,
                .down => pane.floating_y += delta,
            }
            _ = self.setFloatingPaneBounds(pane, pane.floating_x, pane.floating_y, pane.floating_width, pane.floating_height);
            return true;
        }

        var layout_buf: [MAX_LAYOUT_LEAVES]LayoutLeaf = undefined;
        const leaves = self.computeLayout(window_width, window_height, &layout_buf);
        if (leaves.len < 2) return false;

        const target = layout.findAdjacentPane(leaves, pane, direction) orelse return false;
        return self.swapPanePositions(pane, target);
    }

    pub fn swapPanePositions(self: *Tab, first_pane: *Pane, second_pane: *Pane) bool {
        if (first_pane == second_pane) return true;
        const first_leaf = self.findPaneLeaf(first_pane) orelse return false;
        const second_leaf = self.findPaneLeaf(second_pane) orelse return false;
        first_leaf.pane = second_pane;
        second_leaf.pane = first_pane;
        return true;
    }

    fn initRootSplitForPane(self: *Tab, pane: *Pane) !void {
        if (self.root_split != null) return;
        const root = try self.allocator.create(SplitNode);
        root.* = SplitNode.initPane(pane);
        self.root_split = root;
    }

    fn findPaneLeaf(self: *Tab, pane: *Pane) ?*SplitNode {
        const root = self.root_split orelse return null;
        return layout.findPaneLeafNode(root, pane);
    }

    fn reinsertFloatingPane(self: *Tab, pane: *Pane) bool {
        const root = self.root_split orelse return false;

        var anchor: ?*Pane = null;
        if (pane.restore_anchor_id != 0) {
            for (self.panes.items) |candidate| {
                if (@intFromPtr(candidate) == pane.restore_anchor_id and candidate != pane and !candidate.is_floating) {
                    anchor = candidate;
                    break;
                }
            }
        }
        if (anchor == null) {
            for (self.panes.items) |candidate| {
                if (candidate != pane and !candidate.is_floating) {
                    anchor = candidate;
                    break;
                }
            }
        }

        const anchor_pane = anchor orelse return false;
        const target = layout.findPaneLeafNode(root, anchor_pane) orelse return false;

        const existing_leaf = self.allocator.create(SplitNode) catch return false;
        errdefer self.allocator.destroy(existing_leaf);
        existing_leaf.* = SplitNode.initPane(anchor_pane);

        const new_leaf = self.allocator.create(SplitNode) catch return false;
        errdefer self.allocator.destroy(new_leaf);
        new_leaf.* = SplitNode.initPane(pane);

        const direction: SplitDirection = if (pane.restore_split_horizontal) .horizontal else .vertical;
        const ratio = std.math.clamp(pane.restore_ratio, 0.05, 0.95);
        if (pane.restore_place_first) {
            target.* = SplitNode.initSplit(new_leaf, existing_leaf, direction, ratio);
        } else {
        target.* = SplitNode.initSplit(existing_leaf, new_leaf, direction, 1.0 - ratio);
        }
        pane.restore_anchor_id = @intFromPtr(anchor_pane);
        return true;
    }
};
