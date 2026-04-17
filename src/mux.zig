const std = @import("std");
const Config = @import("config.zig").Config;
const Pane = @import("pane.zig").Pane;
const LaunchCommand = @import("pty/launch_command.zig").LaunchCommand;
const GhosttyRuntime = @import("term/ghostty.zig").Runtime;
const TerminalCallbacks = @import("term/ghostty.zig").TerminalCallbacks;

pub const FocusDirection = enum {
    left,
    right,
    up,
    down,
};

pub const SplitDirection = enum {
    horizontal,
    vertical,
};

/// Axis-aligned pixel rectangle for a single pane.
pub const PaneBounds = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

/// A single entry produced by layout traversal.
pub const LayoutLeaf = struct {
    pane: *Pane,
    bounds: PaneBounds,
};

/// Maximum number of panes that layout supports in one pass.
pub const MAX_LAYOUT_LEAVES = 64;

/// Result of a divider hit-test: the split node whose seam was hit, plus the
/// total bounds of that split node (needed to convert mouse position → ratio).
pub const DividerHit = struct {
    node: *SplitNode,
    /// Pixel rect that the split node occupies.
    bounds: PaneBounds,
};

/// Walk the split tree rooted at `node` with the given pixel `bounds` and
/// return the first split seam within `radius` pixels of (`mx`, `my`).
/// Returns null when the cursor is not near any divider.
pub fn hitTestDivider(
    node: *SplitNode,
    bounds: PaneBounds,
    mx: f32,
    my: f32,
    radius: f32,
) ?DividerHit {
    if (node.kind != .split) return null;

    const first = node.first orelse return null;
    const second = node.second orelse return null;
    const ratio = std.math.clamp(node.ratio, 0.0, 1.0);

    var first_bounds: PaneBounds = undefined;
    var second_bounds: PaneBounds = undefined;

    switch (node.direction) {
        .vertical => {
            const first_w = @as(u32, @intFromFloat(@as(f32, @floatFromInt(bounds.width)) * ratio));
            const second_w = if (bounds.width > first_w) bounds.width - first_w else 0;
            first_bounds = .{ .x = bounds.x, .y = bounds.y, .width = first_w, .height = bounds.height };
            second_bounds = .{ .x = bounds.x + first_w, .y = bounds.y, .width = second_w, .height = bounds.height };
            // Divider is the vertical seam at x = bounds.x + first_w.
            const seam_x: f32 = @floatFromInt(bounds.x + first_w);
            const in_y = my >= @as(f32, @floatFromInt(bounds.y)) and
                my < @as(f32, @floatFromInt(bounds.y + bounds.height));
            if (in_y and @abs(mx - seam_x) <= radius) {
                return .{ .node = node, .bounds = bounds };
            }
        },
        .horizontal => {
            const first_h = @as(u32, @intFromFloat(@as(f32, @floatFromInt(bounds.height)) * ratio));
            const second_h = if (bounds.height > first_h) bounds.height - first_h else 0;
            first_bounds = .{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = first_h };
            second_bounds = .{ .x = bounds.x, .y = bounds.y + first_h, .width = bounds.width, .height = second_h };
            // Divider is the horizontal seam at y = bounds.y + first_h.
            const seam_y: f32 = @floatFromInt(bounds.y + first_h);
            const in_x = mx >= @as(f32, @floatFromInt(bounds.x)) and
                mx < @as(f32, @floatFromInt(bounds.x + bounds.width));
            if (in_x and @abs(my - seam_y) <= radius) {
                return .{ .node = node, .bounds = bounds };
            }
        },
    }

    // Recurse into children (innermost split wins).
    if (hitTestDivider(first, first_bounds, mx, my, radius)) |hit| return hit;
    if (hitTestDivider(second, second_bounds, mx, my, radius)) |hit| return hit;
    return null;
}

/// Walk a SplitNode tree and fill `out` with one LayoutLeaf per pane leaf.
/// Returns the number of entries written.
/// `bounds` is the pixel rectangle available to `node`.
pub fn layoutSplitTree(
    node: *SplitNode,
    bounds: PaneBounds,
    out: []LayoutLeaf,
    written: *usize,
) void {
    switch (node.kind) {
        .pane => {
            const pane = node.pane orelse return;
            if (written.* >= out.len) return;
            out[written.*] = .{ .pane = pane, .bounds = bounds };
            written.* += 1;
        },
        .split => {
            const first = node.first orelse return;
            const second = node.second orelse return;
            const ratio = std.math.clamp(node.ratio, 0.0, 1.0);
            var first_bounds: PaneBounds = undefined;
            var second_bounds: PaneBounds = undefined;
            switch (node.direction) {
                .vertical => {
                    // Split left/right
                    const divider: u32 = if (bounds.width > 1) 1 else 0;
                    const usable_w = if (bounds.width > divider) bounds.width - divider else bounds.width;
                    const first_w = @as(u32, @intFromFloat(@as(f32, @floatFromInt(usable_w)) * ratio));
                    const second_w = if (usable_w > first_w) usable_w - first_w else 0;
                    first_bounds = .{ .x = bounds.x, .y = bounds.y, .width = first_w, .height = bounds.height };
                    second_bounds = .{ .x = bounds.x + first_w + divider, .y = bounds.y, .width = second_w, .height = bounds.height };
                },
                .horizontal => {
                    // Split top/bottom
                    const divider: u32 = if (bounds.height > 1) 1 else 0;
                    const usable_h = if (bounds.height > divider) bounds.height - divider else bounds.height;
                    const first_h = @as(u32, @intFromFloat(@as(f32, @floatFromInt(usable_h)) * ratio));
                    const second_h = if (usable_h > first_h) usable_h - first_h else 0;
                    first_bounds = .{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = first_h };
                    second_bounds = .{ .x = bounds.x, .y = bounds.y + first_h + divider, .width = bounds.width, .height = second_h };
                },
            }
            layoutSplitTree(first, first_bounds, out, written);
            layoutSplitTree(second, second_bounds, out, written);
        },
    }
}

fn layoutVisibleTree(
    node: *SplitNode,
    bounds: PaneBounds,
    out: []LayoutLeaf,
    written: *usize,
    skip_pane: ?*Pane,
) void {
    switch (node.kind) {
        .pane => {
            const pane = node.pane orelse return;
            if (skip_pane == pane or pane.is_floating) return;
            if (written.* >= out.len) return;
            out[written.*] = .{ .pane = pane, .bounds = bounds };
            written.* += 1;
        },
        .split => {
            const first = node.first orelse return;
            const second = node.second orelse return;
            const ratio = std.math.clamp(node.ratio, 0.0, 1.0);
            var first_bounds: PaneBounds = undefined;
            var second_bounds: PaneBounds = undefined;
            switch (node.direction) {
                .vertical => {
                    const divider: u32 = if (bounds.width > 1) 1 else 0;
                    const usable_w = if (bounds.width > divider) bounds.width - divider else bounds.width;
                    const first_w = @as(u32, @intFromFloat(@as(f32, @floatFromInt(usable_w)) * ratio));
                    const second_w = if (usable_w > first_w) usable_w - first_w else 0;
                    first_bounds = .{ .x = bounds.x, .y = bounds.y, .width = first_w, .height = bounds.height };
                    second_bounds = .{ .x = bounds.x + first_w + divider, .y = bounds.y, .width = second_w, .height = bounds.height };
                },
                .horizontal => {
                    const divider: u32 = if (bounds.height > 1) 1 else 0;
                    const usable_h = if (bounds.height > divider) bounds.height - divider else bounds.height;
                    const first_h = @as(u32, @intFromFloat(@as(f32, @floatFromInt(usable_h)) * ratio));
                    const second_h = if (usable_h > first_h) usable_h - first_h else 0;
                    first_bounds = .{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = first_h };
                    second_bounds = .{ .x = bounds.x, .y = bounds.y + first_h + divider, .width = bounds.width, .height = second_h };
                },
            }
            layoutVisibleTree(first, first_bounds, out, written, skip_pane);
            layoutVisibleTree(second, second_bounds, out, written, skip_pane);
        },
    }
}

fn floatingPaneBounds(bounds: PaneBounds, pane: *const Pane) PaneBounds {
    const max_w: f32 = @floatFromInt(bounds.width);
    const max_h: f32 = @floatFromInt(bounds.height);
    const width = std.math.clamp(pane.floating_width, 0.2, 1.0);
    const height = std.math.clamp(pane.floating_height, 0.15, 1.0);
    const x = std.math.clamp(pane.floating_x, 0.0, 1.0 - width);
    const y = std.math.clamp(pane.floating_y, 0.0, 1.0 - height);
    const pane_w = @max(@as(u32, 1), @as(u32, @intFromFloat(max_w * width)));
    const pane_h = @max(@as(u32, 1), @as(u32, @intFromFloat(max_h * height)));
    const pane_x = bounds.x + @as(u32, @intFromFloat(max_w * x));
    const pane_y = bounds.y + @as(u32, @intFromFloat(max_h * y));
    return .{
        .x = pane_x,
        .y = pane_y,
        .width = @min(bounds.width, pane_w),
        .height = @min(bounds.height, pane_h),
    };
}

pub const SplitNode = struct {
    kind: Kind,
    pane: ?*Pane = null,
    first: ?*SplitNode = null,
    second: ?*SplitNode = null,
    direction: SplitDirection = .vertical,
    ratio: f32 = 0.5,

    pub const Kind = enum {
        pane,
        split,
    };

    pub fn initPane(pane: *Pane) SplitNode {
        return .{
            .kind = .pane,
            .pane = pane,
        };
    }

    pub fn initSplit(first: *SplitNode, second: *SplitNode, direction: SplitDirection, ratio: f32) SplitNode {
        return .{
            .kind = .split,
            .first = first,
            .second = second,
            .direction = direction,
            .ratio = std.math.clamp(ratio, 0.1, 0.9),
        };
    }

    pub fn deinit(self: *SplitNode, allocator: std.mem.Allocator) void {
        if (self.first) |first| {
            first.deinit(allocator);
            allocator.destroy(first);
        }
        if (self.second) |second| {
            second.deinit(allocator);
            allocator.destroy(second);
        }
        self.* = undefined;
    }
};

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

        target.* = SplitNode.initSplit(existing_leaf, new_leaf, direction, ratio);
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
                const sibling = removePaneFromTree(self.allocator, root, pane);
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

    /// Compute pixel bounds for every leaf pane in this tab's split tree.
    /// Returns a slice into `out` (length = number of panes).
    pub fn computeLayout(self: *Tab, window_width: u32, window_height: u32, out: []LayoutLeaf) []LayoutLeaf {
        return self.computeLayoutInBounds(.{
            .x = 0,
            .y = 0,
            .width = window_width,
            .height = window_height,
        }, out);
    }

    pub fn computeLayoutInBounds(self: *Tab, bounds: PaneBounds, out: []LayoutLeaf) []LayoutLeaf {
        var written: usize = 0;
        if (self.maximized_pane) |pane| {
            if (self.maximized_show_background) {
                if (self.root_split) |root| {
                    layoutVisibleTree(root, bounds, out, &written, null);
                }
            }
            if (written < out.len) {
                out[written] = .{ .pane = pane, .bounds = bounds };
                written += 1;
            }
        } else if (self.root_split) |root| {
            layoutVisibleTree(root, bounds, out, &written, null);
        }

        for (self.panes.items) |pane| {
            if (!pane.is_floating) continue;
            if (self.maximized_pane == pane) continue;
            if (written >= out.len) break;
            out[written] = .{ .pane = pane, .bounds = floatingPaneBounds(bounds, pane) };
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

        const target = findAdjacentPane(leaves, pane, direction) orelse return false;
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
        return findPaneLeafNode(root, pane);
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
        const target = findPaneLeafNode(root, anchor_pane) orelse return false;

        const existing_leaf = self.allocator.create(SplitNode) catch return false;
        errdefer self.allocator.destroy(existing_leaf);
        existing_leaf.* = SplitNode.initPane(anchor_pane);

        const new_leaf = self.allocator.create(SplitNode) catch return false;
        errdefer self.allocator.destroy(new_leaf);
        new_leaf.* = SplitNode.initPane(pane);

        const direction: SplitDirection = if (pane.restore_split_horizontal) .horizontal else .vertical;
        const ratio = std.math.clamp(pane.restore_ratio, 0.1, 0.9);
        if (pane.restore_place_first) {
            target.* = SplitNode.initSplit(new_leaf, existing_leaf, direction, ratio);
        } else {
            target.* = SplitNode.initSplit(existing_leaf, new_leaf, direction, ratio);
        }
        pane.restore_anchor_id = @intFromPtr(anchor_pane);
        return true;
    }
};

pub const Workspace = struct {
    allocator: std.mem.Allocator,
    id: usize,
    name: ?[]u8 = null,
    default_cwd: ?[]u8 = null,
    tabs: std.ArrayList(*Tab),
    active_tab: ?*Tab = null,

    pub const PaneIterator = struct {
        workspace: *Workspace,
        tab_index: usize = 0,
        pane_iter: ?Tab.PaneIterator = null,

        pub fn next(self: *PaneIterator) ?*Pane {
            while (true) {
                if (self.pane_iter) |*pane_iter| {
                    if (pane_iter.next()) |pane| return pane;
                    self.pane_iter = null;
                }

                if (self.tab_index >= self.workspace.tabs.items.len) return null;
                const tab = self.workspace.tabs.items[self.tab_index];
                self.tab_index += 1;
                self.pane_iter = tab.paneIterator();
            }
        }
    };

    pub fn init(allocator: std.mem.Allocator, id: usize) Workspace {
        return .{
            .allocator = allocator,
            .id = id,
            .tabs = .empty,
        };
    }

    pub fn deinit(self: *Workspace, runtime: *GhosttyRuntime) void {
        if (self.name) |name| self.allocator.free(name);
        if (self.default_cwd) |cwd| self.allocator.free(cwd);
        for (self.tabs.items) |tab| {
            tab.deinit(runtime);
            self.allocator.destroy(tab);
        }
        self.tabs.deinit(self.allocator);
        self.* = Workspace.init(self.allocator, self.id);
    }

    pub fn appendTab(self: *Workspace, tab: *Tab) !void {
        try self.tabs.append(self.allocator, tab);
        if (self.active_tab == null) self.active_tab = tab;
    }

    pub fn newTab(self: *Workspace, id: usize) !*Tab {
        const tab = try self.allocator.create(Tab);
        tab.* = Tab.init(self.allocator, id);
        const insert_at = if (self.active_tab) |_| self.activeTabIndex() + 1 else self.tabs.items.len;
        try self.tabs.insert(self.allocator, insert_at, tab);
        self.active_tab = tab;
        return tab;
    }

    pub fn closeTab(self: *Workspace, runtime: *GhosttyRuntime) void {
        const active = self.active_tab orelse return;
        var idx: usize = 0;
        for (self.tabs.items, 0..) |t, i| {
            if (t == active) idx = i;
        }
        _ = self.tabs.orderedRemove(idx);
        active.deinit(runtime);
        self.allocator.destroy(active);
        if (self.tabs.items.len == 0) {
            self.active_tab = null;
        } else {
            self.active_tab = self.tabs.items[if (idx >= self.tabs.items.len) self.tabs.items.len - 1 else idx];
        }
    }

    pub fn nextTab(self: *Workspace) void {
        if (self.tabs.items.len < 2) return;
        var idx: usize = 0;
        for (self.tabs.items, 0..) |t, i| {
            if (t == self.active_tab) idx = i;
        }
        idx = (idx + 1) % self.tabs.items.len;
        self.active_tab = self.tabs.items[idx];
    }

    pub fn prevTab(self: *Workspace) void {
        if (self.tabs.items.len < 2) return;
        var idx: usize = 0;
        for (self.tabs.items, 0..) |t, i| {
            if (t == self.active_tab) idx = i;
        }
        idx = if (idx == 0) self.tabs.items.len - 1 else idx - 1;
        self.active_tab = self.tabs.items[idx];
    }

    pub fn switchTab(self: *Workspace, index: usize) void {
        if (index >= self.tabs.items.len) return;
        self.active_tab = self.tabs.items[index];
    }

    pub fn activeTabIndex(self: *Workspace) usize {
        for (self.tabs.items, 0..) |t, i| {
            if (t == self.active_tab) return i;
        }
        return 0;
    }

    pub fn activeTab(self: *Workspace) ?*Tab {
        return self.active_tab;
    }

    pub fn tabById(self: *Workspace, id: usize) ?*Tab {
        for (self.tabs.items) |tab| {
            if (tab.id == id) return tab;
        }
        return null;
    }

    pub fn paneIterator(self: *Workspace) PaneIterator {
        return .{ .workspace = self };
    }

    pub fn activeSplitRoot(self: *Workspace) ?*SplitNode {
        const tab = self.activeTab() orelse return null;
        return tab.activeSplitRoot();
    }

    pub fn title(self: *Workspace, out_buf: []u8) []const u8 {
        if (self.name) |name| return name;
        return std.fmt.bufPrint(out_buf, "ws {d}", .{self.id}) catch "ws";
    }

    pub fn setName(self: *Workspace, value: []const u8) !void {
        if (self.name) |name| self.allocator.free(name);
        self.name = if (value.len > 0) try self.allocator.dupe(u8, value) else null;
    }

    pub fn setDefaultCwd(self: *Workspace, value: ?[]const u8) !void {
        if (self.default_cwd) |cwd| self.allocator.free(cwd);
        if (value) |cwd| {
            self.default_cwd = if (cwd.len > 0) try self.allocator.dupe(u8, cwd) else null;
        } else {
            self.default_cwd = null;
        }
    }
};

pub const Mux = struct {
    allocator: std.mem.Allocator,
    workspaces: std.ArrayList(*Workspace),
    active_workspace: ?*Workspace = null,
    next_id: usize = 1,

    pub const PaneIterator = struct {
        mux: *Mux,
        workspace_index: usize = 0,
        pane_iter: ?Workspace.PaneIterator = null,

        pub fn next(self: *PaneIterator) ?*Pane {
            while (true) {
                if (self.pane_iter) |*pane_iter| {
                    if (pane_iter.next()) |pane| return pane;
                    self.pane_iter = null;
                }

                if (self.workspace_index >= self.mux.workspaces.items.len) return null;
                const workspace = self.mux.workspaces.items[self.workspace_index];
                self.workspace_index += 1;
                self.pane_iter = workspace.paneIterator();
            }
        }
    };

    pub fn init(allocator: std.mem.Allocator) Mux {
        return .{
            .allocator = allocator,
            .workspaces = .empty,
        };
    }

    pub fn deinit(self: *Mux, runtime: *GhosttyRuntime) void {
        for (self.workspaces.items) |workspace| {
            workspace.deinit(runtime);
            self.allocator.destroy(workspace);
        }
        self.workspaces.deinit(self.allocator);
        self.* = Mux.init(self.allocator);
    }

    pub fn bootstrapSingle(self: *Mux, runtime: *GhosttyRuntime, callbacks: TerminalCallbacks, cfg: Config, cell_width_px: u32, cell_height_px: u32, window_width: u32, window_height: u32) !void {
        if (self.workspaces.items.len != 0) return error.MuxAlreadyBootstrapped;

        const workspace = try self.createBootstrappedWorkspace(runtime, callbacks, cfg, cell_width_px, cell_height_px, window_width, window_height, null, null);
        try self.workspaces.append(self.allocator, workspace);
        self.active_workspace = workspace;
    }

    pub fn newWorkspace(self: *Mux, runtime: *GhosttyRuntime, callbacks: TerminalCallbacks, cfg: Config, cell_width_px: u32, cell_height_px: u32, window_width: u32, window_height: u32, inherited_cwd: ?[]const u8, domain_name: ?[]const u8) !void {
        const workspace = try self.createBootstrappedWorkspace(runtime, callbacks, cfg, cell_width_px, cell_height_px, window_width, window_height, inherited_cwd, domain_name);
        try workspace.setDefaultCwd(inherited_cwd);
        try self.workspaces.append(self.allocator, workspace);
        self.active_workspace = workspace;
    }

    fn createBootstrappedWorkspace(self: *Mux, runtime: *GhosttyRuntime, callbacks: TerminalCallbacks, cfg: Config, cell_width_px: u32, cell_height_px: u32, window_width: u32, window_height: u32, inherited_cwd: ?[]const u8, domain_name: ?[]const u8) !*Workspace {
        const workspace = try self.createWorkspace();
        var workspace_owned_by_mux = false;
        defer if (!workspace_owned_by_mux) {
            workspace.deinit(runtime);
            self.allocator.destroy(workspace);
        };

        const tab = try self.createTab();
        var tab_owned_by_workspace = false;
        defer if (!tab_owned_by_workspace) {
            tab.deinit(runtime);
            self.allocator.destroy(tab);
        };

        const resolved_domain = domain_name orelse cfg.defaultDomainName();
        const pane = try self.createPane(runtime, callbacks, cfg, cell_width_px, cell_height_px, window_width, window_height, inherited_cwd, resolved_domain, null);
        var pane_owned_by_tab = false;
        defer if (!pane_owned_by_tab) {
            pane.deinit(runtime);
            self.allocator.destroy(pane);
        };

        try tab.appendPane(pane);
        pane_owned_by_tab = true;

        try workspace.appendTab(tab);
        tab_owned_by_workspace = true;

        workspace_owned_by_mux = true;
        return workspace;
    }

    pub fn activeWorkspace(self: *Mux) ?*Workspace {
        return self.active_workspace;
    }

    pub fn activeTab(self: *Mux) ?*Tab {
        const workspace = self.activeWorkspace() orelse return null;
        return workspace.activeTab();
    }

    pub fn tabById(self: *Mux, id: usize) ?*Tab {
        if (self.activeWorkspace()) |ws| return ws.tabById(id);
        return null;
    }

    pub fn setActivePane(self: *Mux, pane: *Pane) void {
        if (self.activeTab()) |tab| {
            tab.active_pane = pane;
        }
    }

    pub fn activePane(self: *Mux) ?*Pane {
        const tab = self.activeTab() orelse return null;
        return tab.activePane();
    }

    pub fn paneIterator(self: *Mux) PaneIterator {
        return .{ .mux = self };
    }

    pub fn activeSplitRoot(self: *Mux) ?*SplitNode {
        const tab = self.activeTab() orelse return null;
        return tab.activeSplitRoot();
    }

    /// Compute pixel bounds for every pane in the active tab.
    pub fn computeActiveLayout(self: *Mux, window_width: u32, window_height: u32, out: []LayoutLeaf) []LayoutLeaf {
        const tab = self.activeTab() orelse return out[0..0];
        return tab.computeLayout(window_width, window_height, out);
    }

    pub fn activeTabContainsPane(self: *Mux, pane: *Pane) bool {
        const tab = self.activeTab() orelse return false;
        var panes = tab.paneIterator();
        while (panes.next()) |item| {
            if (item == pane) return true;
        }
        return false;
    }

    pub fn togglePaneMaximized(self: *Mux, pane: *Pane, show_background: bool) bool {
        const tab = self.activeTab() orelse return false;
        if (!self.activeTabContainsPane(pane)) return false;
        _ = tab.togglePaneMaximized(pane, show_background);
        tab.active_pane = pane;
        return true;
    }

    pub fn paneIsMaximized(self: *Mux, pane: *Pane) bool {
        const tab = self.activeTab() orelse return false;
        return tab.isPaneMaximized(pane);
    }

    pub fn setPaneFloating(self: *Mux, pane: *Pane, floating: bool) bool {
        const tab = self.activeTab() orelse return false;
        if (!self.activeTabContainsPane(pane)) return false;
        _ = tab.setPaneFloating(pane, floating);
        if (floating) tab.active_pane = pane;
        return true;
    }

    pub fn setFloatingPaneBounds(self: *Mux, pane: *Pane, x: f32, y: f32, width: f32, height: f32) bool {
        const tab = self.activeTab() orelse return false;
        if (!self.activeTabContainsPane(pane) or !pane.is_floating) return false;
        return tab.setFloatingPaneBounds(pane, x, y, width, height);
    }

    pub fn movePane(self: *Mux, pane: *Pane, direction: FocusDirection, window_width: u32, window_height: u32, amount: f32) bool {
        const tab = self.activeTab() orelse return false;
        if (!self.activeTabContainsPane(pane)) return false;
        const moved = tab.movePane(pane, direction, window_width, window_height, amount);
        if (moved) tab.active_pane = pane;
        return moved;
    }

    fn createWorkspace(self: *Mux) !*Workspace {
        const workspace = try self.allocator.create(Workspace);
        workspace.* = Workspace.init(self.allocator, self.allocId());
        return workspace;
    }

    fn createTab(self: *Mux) !*Tab {
        const tab = try self.allocator.create(Tab);
        tab.* = Tab.init(self.allocator, self.allocId());
        return tab;
    }

    pub fn createPane(self: *Mux, runtime: *GhosttyRuntime, callbacks: TerminalCallbacks, cfg: Config, cell_width_px: u32, cell_height_px: u32, window_width: u32, window_height: u32, inherited_cwd: ?[]const u8, domain_name: ?[]const u8, launch_command: ?LaunchCommand) !*Pane {
        const pane = try self.allocator.create(Pane);
        pane.* = Pane.init(self.allocator);
        errdefer self.allocator.destroy(pane);
        errdefer pane.deinit(runtime);
        try pane.bootstrap(runtime, callbacks, cfg, cell_width_px, cell_height_px, window_width, window_height, inherited_cwd, domain_name, launch_command);
        return pane;
    }

    /// Split the active pane, spawning a new pane in the given direction.
    /// The new pane becomes the active pane.
    pub fn newTab(self: *Mux, runtime: *GhosttyRuntime, callbacks: TerminalCallbacks, cfg: Config, cell_width_px: u32, cell_height_px: u32, window_width: u32, window_height: u32, domain_name: ?[]const u8) !void {
        const ws = self.activeWorkspace() orelse return error.NoActiveWorkspace;
        const current_pane = self.activePane();
        const inherited_cwd: ?[]const u8 = if (current_pane) |pane|
            if (pane.cwd.len > 0) pane.cwd else null
        else if (ws.default_cwd) |cwd|
            cwd
        else
            null;
        const previous_active = ws.active_tab;
        const tab = try ws.newTab(self.allocId());
        errdefer {
            var remove_idx: ?usize = null;
            for (ws.tabs.items, 0..) |t, i| {
                if (t == tab) {
                    remove_idx = i;
                    break;
                }
            }
            if (remove_idx) |idx| _ = ws.tabs.orderedRemove(idx);
            self.allocator.destroy(tab);
            ws.active_tab = previous_active;
        }
        const resolved_domain = domain_name orelse cfg.defaultDomainName();
        const pane = try self.createPane(runtime, callbacks, cfg, cell_width_px, cell_height_px, window_width, window_height, inherited_cwd, resolved_domain, null);
        try tab.appendPane(pane);
    }

    /// Close the active tab. Returns true if no tabs remain (app should quit).
    pub fn closeTab(self: *Mux, runtime: *GhosttyRuntime) bool {
        const ws = self.activeWorkspace() orelse return true;
        ws.closeTab(runtime);
        if (ws.tabs.items.len > 0) return false;
        return self.removeWorkspace(runtime, ws);
    }

    pub fn tabAt(self: *Mux, index: usize) ?*Tab {
        const ws = self.activeWorkspace() orelse return null;
        if (index >= ws.tabs.items.len) return null;
        return ws.tabs.items[index];
    }

    pub fn closeTabAt(self: *Mux, runtime: *GhosttyRuntime, index: usize) bool {
        const ws = self.activeWorkspace() orelse return true;
        if (index >= ws.tabs.items.len) return false;
        ws.active_tab = ws.tabs.items[index];
        ws.closeTab(runtime);
        if (ws.tabs.items.len > 0) return false;
        return self.removeWorkspace(runtime, ws);
    }

    /// Close the currently active pane. Kills the associated process.
    /// Returns true if the entire app should quit (no panes remain anywhere).
    pub fn closeActivePane(self: *Mux, runtime: *GhosttyRuntime) bool {
        const ws = self.activeWorkspace() orelse return true;
        const tab = ws.activeTab() orelse return true;
        const pane = tab.activePane() orelse return true;

        const tab_empty = tab.closePane(runtime, pane);
        if (tab_empty) {
            ws.closeTab(runtime);
            if (ws.tabs.items.len == 0) return self.removeWorkspace(runtime, ws);
        }
        return false;
    }

    pub fn nextTab(self: *Mux) void {
        if (self.activeWorkspace()) |ws| ws.nextTab();
    }

    pub fn prevTab(self: *Mux) void {
        if (self.activeWorkspace()) |ws| ws.prevTab();
    }

    pub fn nextWorkspace(self: *Mux) void {
        if (self.workspaces.items.len < 2) return;
        const idx = self.activeWorkspaceIndex();
        self.active_workspace = self.workspaces.items[(idx + 1) % self.workspaces.items.len];
    }

    pub fn prevWorkspace(self: *Mux) void {
        if (self.workspaces.items.len < 2) return;
        const idx = self.activeWorkspaceIndex();
        self.active_workspace = self.workspaces.items[if (idx == 0) self.workspaces.items.len - 1 else idx - 1];
    }

    pub fn switchWorkspace(self: *Mux, index: usize) void {
        if (index >= self.workspaces.items.len) return;
        self.active_workspace = self.workspaces.items[index];
    }

    pub fn closeWorkspace(self: *Mux, runtime: *GhosttyRuntime) bool {
        const workspace = self.activeWorkspace() orelse return true;
        return self.removeWorkspace(runtime, workspace);
    }

    pub fn activeWorkspaceIndex(self: *Mux) usize {
        for (self.workspaces.items, 0..) |ws, i| {
            if (ws == self.active_workspace) return i;
        }
        return 0;
    }

    pub fn workspaceCount(self: *Mux) usize {
        return self.workspaces.items.len;
    }

    pub fn switchTab(self: *Mux, index: usize) void {
        if (self.activeWorkspace()) |ws| ws.switchTab(index);
    }

    pub fn activeTabIndex(self: *Mux) usize {
        if (self.activeWorkspace()) |ws| return ws.activeTabIndex();
        return 0;
    }

    pub fn tabCount(self: *Mux) usize {
        if (self.activeWorkspace()) |ws| return ws.tabs.items.len;
        return 0;
    }

    pub fn splitActivePane(self: *Mux, runtime: *GhosttyRuntime, callbacks: TerminalCallbacks, cfg: Config, cell_width_px: u32, cell_height_px: u32, window_width: u32, window_height: u32, direction: SplitDirection, ratio: f32, domain_name: ?[]const u8, cwd: ?[]const u8, floating: bool, launch_command: ?LaunchCommand) !*Pane {
        const tab = self.activeTab() orelse return error.NoActiveTab;
        const source_pane = tab.activePane() orelse return error.NoActivePane;
        if (!floating and source_pane.is_floating) {
            if (!tab.setPaneFloating(source_pane, false)) return error.ActivePaneMissingFromLayout;
        }
        const inherited_cwd: ?[]const u8 = if (cwd) |value|
            value
        else if (source_pane.cwd.len > 0)
            source_pane.cwd
        else
            null;
        const resolved_domain = domain_name orelse cfg.defaultDomainName();
        const new_pane = try self.createPane(runtime, callbacks, cfg, cell_width_px, cell_height_px, window_width, window_height, inherited_cwd, resolved_domain, launch_command);
        errdefer {
            new_pane.deinit(runtime);
            self.allocator.destroy(new_pane);
        }
        if (floating) {
            try tab.appendPane(new_pane);
            _ = tab.setPaneFloating(new_pane, true);
            const restore_anchor = if (!source_pane.is_floating)
                source_pane
            else blk: {
                for (tab.panes.items) |candidate| {
                    if (candidate != new_pane and !candidate.is_floating) break :blk candidate;
                }
                break :blk null;
            };
            if (restore_anchor) |anchor| new_pane.restore_anchor_id = @intFromPtr(anchor);
            new_pane.restore_ratio = std.math.clamp(ratio, 0.1, 0.9);
            new_pane.restore_split_horizontal = direction == .horizontal;
            new_pane.restore_place_first = false;
            tab.active_pane = new_pane;
            return new_pane;
        }
        try tab.splitActivePane(new_pane, direction, ratio);
        return new_pane;
    }

    /// Resize the active pane by adjusting the ratio of the nearest enclosing
    /// split node along the given axis. `delta` is a fraction in (-1, 1) —
    /// positive means "grow the first child" (i.e. push the divider right/down).
    pub fn resizeActivePane(self: *Mux, direction: SplitDirection, delta: f32) void {
        const tab = self.activeTab() orelse return;
        const current = tab.activePane() orelse return;
        const root = tab.root_split orelse return;
        // Find the innermost split node along `direction` that contains `current`.
        if (findSplitContaining(root, current, direction)) |node| {
            node.ratio = std.math.clamp(node.ratio + delta, 0.1, 0.9);
        }
    }

    /// Focus the adjacent pane in the given direction from the currently active pane.
    /// Navigation follows the split tree rather than global pane centers, so nested
    /// layouts move into the sibling subtree of the nearest matching split.
    pub fn focusPaneInDirection(self: *Mux, direction: FocusDirection, window_width: u32, window_height: u32) void {
        const tab = self.activeTab() orelse return;
        const current = tab.activePane() orelse return;

        var layout_buf: [MAX_LAYOUT_LEAVES]LayoutLeaf = undefined;
        const leaves = tab.computeLayout(window_width, window_height, &layout_buf);
        if (leaves.len < 2) return;

        const target_subtree = findFocusTargetSubtree(tab.root_split orelse return, current, direction) orelse return;

        var cur_bounds: ?PaneBounds = null;
        for (leaves) |leaf| {
            if (leaf.pane == current) {
                cur_bounds = leaf.bounds;
                break;
            }
        }
        const cb = cur_bounds orelse return;

        var best_pane: ?*Pane = null;
        var best_overlap: u32 = 0;
        var best_primary_gap: u32 = std.math.maxInt(u32);
        var best_secondary_gap: u32 = std.math.maxInt(u32);

        for (leaves) |leaf| {
            if (!subtreeContainsPane(target_subtree, leaf.pane)) continue;

            const overlap = switch (direction) {
                .left, .right => intervalOverlap(cb.y, cb.height, leaf.bounds.y, leaf.bounds.height),
                .up, .down => intervalOverlap(cb.x, cb.width, leaf.bounds.x, leaf.bounds.width),
            };
            const primary_gap = primaryAxisGap(cb, leaf.bounds, direction);
            const secondary_gap = secondaryAxisGap(cb, leaf.bounds, direction);

            if (best_pane == null or
                overlap > best_overlap or
                (overlap == best_overlap and primary_gap < best_primary_gap) or
                (overlap == best_overlap and primary_gap == best_primary_gap and secondary_gap < best_secondary_gap))
            {
                best_overlap = overlap;
                best_primary_gap = primary_gap;
                best_secondary_gap = secondary_gap;
                best_pane = leaf.pane;
            }
        }

        if (best_pane) |p| tab.active_pane = p;
    }

    fn allocId(self: *Mux) usize {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    /// Close all panes in the active tab whose PTY has exited.
    /// Returns true if the entire app should quit (no tabs remain anywhere).
    pub fn closeDeadPanes(self: *Mux, runtime: *GhosttyRuntime) bool {
        const ws = self.activeWorkspace() orelse return true;

        var tab_index: usize = 0;
        while (tab_index < ws.tabs.items.len) {
            const tab = ws.tabs.items[tab_index];
            var dead_buf: [64]*Pane = undefined;
            var dead_count: usize = 0;
            for (tab.panes.items) |pane| {
                if (!pane.hasLiveChild() and dead_count < dead_buf.len) {
                    dead_buf[dead_count] = pane;
                    dead_count += 1;
                }
            }

            if (dead_count == 0) {
                tab_index += 1;
                continue;
            }

            const was_active = ws.active_tab == tab;
            for (dead_buf[0..dead_count]) |pane| {
                const tab_empty = tab.closePane(runtime, pane);
                if (tab_empty) {
                    ws.active_tab = tab;
                    ws.closeTab(runtime);
                    if (ws.tabs.items.len == 0) return self.removeWorkspace(runtime, ws);
                    if (!was_active and tab_index > 0) tab_index -= 1;
                    break;
                }
            }

            if (tab_index < ws.tabs.items.len and ws.tabs.items[tab_index] == tab) {
                tab_index += 1;
            }
        }

        return false;
    }

    fn removeWorkspace(self: *Mux, runtime: *GhosttyRuntime, workspace: *Workspace) bool {
        var idx: ?usize = null;
        for (self.workspaces.items, 0..) |ws, i| {
            if (ws == workspace) {
                idx = i;
                break;
            }
        }
        const remove_idx = idx orelse return self.workspaces.items.len == 0;

        _ = self.workspaces.orderedRemove(remove_idx);
        workspace.deinit(runtime);
        self.allocator.destroy(workspace);

        if (self.workspaces.items.len == 0) {
            self.active_workspace = null;
            return true;
        }

        const next_idx = if (remove_idx >= self.workspaces.items.len) self.workspaces.items.len - 1 else remove_idx;
        self.active_workspace = self.workspaces.items[next_idx];
        return false;
    }
};

fn findPaneLeafNode(node: *SplitNode, pane: *Pane) ?*SplitNode {
    switch (node.kind) {
        .pane => {
            if (node.pane == pane) return node;
            return null;
        },
        .split => {
            if (node.first) |first| {
                if (findPaneLeafNode(first, pane)) |match| return match;
            }
            if (node.second) |second| {
                if (findPaneLeafNode(second, pane)) |match| return match;
            }
            return null;
        },
    }
}

fn subtreeContainsPane(node: *SplitNode, pane: *Pane) bool {
    return findPaneLeafNode(node, pane) != null;
}

/// Returns true if `target` is reachable from `root` (i.e. `target` is a node
/// in the split tree rooted at `root`).  Used to validate cached node pointers
/// (`g_drag_node`, `pending_split_ratio_node`) that may become dangling after
/// tree mutations like `removePaneFromTree`.
pub fn nodeIsInTree(root: *SplitNode, target: *const SplitNode) bool {
    if (root == target) return true;
    if (root.kind != .split) return false;
    if (root.first) |first| {
        if (nodeIsInTree(first, target)) return true;
    }
    if (root.second) |second| {
        if (nodeIsInTree(second, target)) return true;
    }
    return false;
}

fn splitDirectionForFocus(direction: FocusDirection) SplitDirection {
    return switch (direction) {
        .left, .right => .vertical,
        .up, .down => .horizontal,
    };
}

fn findFocusTargetSubtree(node: *SplitNode, pane: *Pane, direction: FocusDirection) ?*SplitNode {
    if (node.kind != .split) return null;

    const first = node.first orelse return null;
    const second = node.second orelse return null;
    const wants_first = direction == .left or direction == .up;
    const wants_second = direction == .right or direction == .down;
    const matching_axis = node.direction == splitDirectionForFocus(direction);

    if (subtreeContainsPane(first, pane)) {
        if (findFocusTargetSubtree(first, pane, direction)) |target| return target;
        if (matching_axis and wants_second) return second;
        return null;
    }

    if (subtreeContainsPane(second, pane)) {
        if (findFocusTargetSubtree(second, pane, direction)) |target| return target;
        if (matching_axis and wants_first) return first;
        return null;
    }

    return null;
}

fn intervalOverlap(a_start: u32, a_len: u32, b_start: u32, b_len: u32) u32 {
    const a_end = a_start + a_len;
    const b_end = b_start + b_len;
    const start = @max(a_start, b_start);
    const end = @min(a_end, b_end);
    return if (end > start) end - start else 0;
}

fn intervalGap(a_start: u32, a_len: u32, b_start: u32, b_len: u32) u32 {
    const a_end = a_start + a_len;
    const b_end = b_start + b_len;
    if (a_end < b_start) return b_start - a_end;
    if (b_end < a_start) return a_start - b_end;
    return 0;
}

fn primaryAxisGap(current: PaneBounds, candidate: PaneBounds, direction: FocusDirection) u32 {
    return switch (direction) {
        .left => intervalGap(candidate.x, candidate.width, current.x, current.width),
        .right => intervalGap(current.x, current.width, candidate.x, candidate.width),
        .up => intervalGap(candidate.y, candidate.height, current.y, current.height),
        .down => intervalGap(current.y, current.height, candidate.y, candidate.height),
    };
}

fn secondaryAxisGap(current: PaneBounds, candidate: PaneBounds, direction: FocusDirection) u32 {
    return switch (direction) {
        .left, .right => intervalGap(current.y, current.height, candidate.y, candidate.height),
        .up, .down => intervalGap(current.x, current.width, candidate.x, candidate.width),
    };
}

fn findAdjacentPane(leaves: []const LayoutLeaf, pane: *Pane, direction: FocusDirection) ?*Pane {
    var current_bounds: ?PaneBounds = null;
    for (leaves) |leaf| {
        if (leaf.pane == pane) {
            current_bounds = leaf.bounds;
            break;
        }
    }
    const cb = current_bounds orelse return null;

    var best_pane: ?*Pane = null;
    var best_overlap: u32 = 0;
    var best_primary_gap: u32 = std.math.maxInt(u32);
    var best_secondary_gap: u32 = std.math.maxInt(u32);

    for (leaves) |leaf| {
        if (leaf.pane == pane) continue;
        if (pane.is_floating != leaf.pane.is_floating) continue;

        const is_in_direction = switch (direction) {
            .left => leaf.bounds.x + leaf.bounds.width <= cb.x,
            .right => leaf.bounds.x >= cb.x + cb.width,
            .up => leaf.bounds.y + leaf.bounds.height <= cb.y,
            .down => leaf.bounds.y >= cb.y + cb.height,
        };
        if (!is_in_direction) continue;

        const overlap = switch (direction) {
            .left, .right => intervalOverlap(cb.y, cb.height, leaf.bounds.y, leaf.bounds.height),
            .up, .down => intervalOverlap(cb.x, cb.width, leaf.bounds.x, leaf.bounds.width),
        };
        const primary_gap = primaryAxisGap(cb, leaf.bounds, direction);
        const secondary_gap = secondaryAxisGap(cb, leaf.bounds, direction);

        if (best_pane == null or
            overlap > best_overlap or
            (overlap == best_overlap and primary_gap < best_primary_gap) or
            (overlap == best_overlap and primary_gap == best_primary_gap and secondary_gap < best_secondary_gap))
        {
            best_overlap = overlap;
            best_primary_gap = primary_gap;
            best_secondary_gap = secondary_gap;
            best_pane = leaf.pane;
        }
    }

    return best_pane;
}

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
    const leaves = tab.computeLayoutInBounds(bounds, &layout_buf);

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
    const leaves = tab.computeLayoutInBounds(bounds, &layout_buf);

    try std.testing.expectEqual(@as(usize, 3), leaves.len);
    try std.testing.expect(leaves[0].pane == left);
    try std.testing.expect(leaves[1].pane == right);
    try std.testing.expect(leaves[2].pane == right);
    try std.testing.expectEqualDeep(bounds, leaves[2].bounds);
}

/// Returns the innermost split node with the given direction that contains `pane`
/// somewhere in its subtree.
fn findSplitContaining(node: *SplitNode, pane: *Pane, direction: SplitDirection) ?*SplitNode {
    if (node.kind != .split) return null;
    // Only consider this node if it has `pane` in its subtree.
    if (findPaneLeafNode(node, pane) == null) return null;

    // Try children first (innermost wins).
    if (node.first) |first| {
        if (findSplitContaining(first, pane, direction)) |found| return found;
    }
    if (node.second) |second| {
        if (findSplitContaining(second, pane, direction)) |found| return found;
    }

    // This node contains `pane` and no child does — use it if direction matches.
    if (node.direction == direction) return node;
    return null;
}

/// Walk the split tree rooted at `node` looking for the split that directly
/// contains a leaf for `pane`. When found, replace that split node in-place
/// with the sibling subtree (collapsing the split) and free the dead leaf
/// and the split node shell.
///
/// Returns the *Pane pointer from the sibling leaf if the sibling is a plain
/// pane leaf, otherwise null (the caller falls back to pane-list iteration).
fn removePaneFromTree(allocator: std.mem.Allocator, node: *SplitNode, pane: *Pane) ?*Pane {
    if (node.kind != .split) return null;

    const first = node.first orelse return null;
    const second = node.second orelse return null;

    // Check if first child is the target leaf.
    if (first.kind == .pane and first.pane == pane) {
        // Replace *node in-place with the contents of `second`, then free
        // the now-detached first leaf and the old second node shell.
        const sibling_pane: ?*Pane = if (second.kind == .pane) second.pane else null;
        allocator.destroy(first); // dead leaf (pane itself freed by caller)
        const second_copy = second.*;
        allocator.destroy(second); // free the shell; its children live on via copy
        node.* = second_copy;
        return sibling_pane;
    }

    // Check if second child is the target leaf.
    if (second.kind == .pane and second.pane == pane) {
        const sibling_pane: ?*Pane = if (first.kind == .pane) first.pane else null;
        allocator.destroy(second);
        const first_copy = first.*;
        allocator.destroy(first);
        node.* = first_copy;
        return sibling_pane;
    }

    // Recurse into children.
    if (removePaneFromTree(allocator, first, pane)) |p| return p;
    if (removePaneFromTree(allocator, second, pane)) |p| return p;
    return null;
}
