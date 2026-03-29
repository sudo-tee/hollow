const std = @import("std");
const Config = @import("config.zig").Config;
const Pane = @import("pane.zig").Pane;
const GhosttyRuntime = @import("term/ghostty.zig").Runtime;

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
                    const first_w = @as(u32, @intFromFloat(@as(f32, @floatFromInt(bounds.width)) * ratio));
                    const second_w = if (bounds.width > first_w) bounds.width - first_w else 0;
                    first_bounds = .{ .x = bounds.x, .y = bounds.y, .width = first_w, .height = bounds.height };
                    second_bounds = .{ .x = bounds.x + first_w, .y = bounds.y, .width = second_w, .height = bounds.height };
                },
                .horizontal => {
                    // Split top/bottom
                    const first_h = @as(u32, @intFromFloat(@as(f32, @floatFromInt(bounds.height)) * ratio));
                    const second_h = if (bounds.height > first_h) bounds.height - first_h else 0;
                    first_bounds = .{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = first_h };
                    second_bounds = .{ .x = bounds.x, .y = bounds.y + first_h, .width = bounds.width, .height = second_h };
                },
            }
            layoutSplitTree(first, first_bounds, out, written);
            layoutSplitTree(second, second_bounds, out, written);
        },
    }
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
    }

    pub fn activeSplitRoot(self: *Tab) ?*SplitNode {
        return self.root_split;
    }

    /// Compute pixel bounds for every leaf pane in this tab's split tree.
    /// Returns a slice into `out` (length = number of panes).
    pub fn computeLayout(self: *Tab, window_width: u32, window_height: u32, out: []LayoutLeaf) []LayoutLeaf {
        const root = self.root_split orelse return out[0..0];
        const full_bounds = PaneBounds{
            .x = 0,
            .y = 0,
            .width = window_width,
            .height = window_height,
        };
        var written: usize = 0;
        layoutSplitTree(root, full_bounds, out, &written);
        return out[0..written];
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
};

pub const Workspace = struct {
    allocator: std.mem.Allocator,
    id: usize,
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

    pub fn activeTab(self: *Workspace) ?*Tab {
        return self.active_tab;
    }

    pub fn paneIterator(self: *Workspace) PaneIterator {
        return .{ .workspace = self };
    }

    pub fn activeSplitRoot(self: *Workspace) ?*SplitNode {
        const tab = self.activeTab() orelse return null;
        return tab.activeSplitRoot();
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

    pub fn bootstrapSingle(self: *Mux, runtime: *GhosttyRuntime, cfg: Config, cell_width_px: u32, cell_height_px: u32, window_width: u32, window_height: u32) !void {
        if (self.workspaces.items.len != 0) return error.MuxAlreadyBootstrapped;

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

        const pane = try self.createPane(runtime, cfg, cell_width_px, cell_height_px, window_width, window_height);
        var pane_owned_by_tab = false;
        defer if (!pane_owned_by_tab) {
            pane.deinit(runtime);
            self.allocator.destroy(pane);
        };

        try tab.appendPane(pane);
        pane_owned_by_tab = true;

        try workspace.appendTab(tab);
        tab_owned_by_workspace = true;

        try self.workspaces.append(self.allocator, workspace);
        workspace_owned_by_mux = true;
        self.active_workspace = workspace;
    }

    pub fn activeWorkspace(self: *Mux) ?*Workspace {
        return self.active_workspace;
    }

    pub fn activeTab(self: *Mux) ?*Tab {
        const workspace = self.activeWorkspace() orelse return null;
        return workspace.activeTab();
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

    pub fn createPane(self: *Mux, runtime: *GhosttyRuntime, cfg: Config, cell_width_px: u32, cell_height_px: u32, window_width: u32, window_height: u32) !*Pane {
        const pane = try self.allocator.create(Pane);
        pane.* = Pane.init(self.allocator);
        errdefer self.allocator.destroy(pane);
        errdefer pane.deinit(runtime);
        try pane.bootstrap(runtime, cfg, cell_width_px, cell_height_px, window_width, window_height);
        return pane;
    }

    /// Split the active pane, spawning a new pane in the given direction.
    /// The new pane becomes the active pane.
    pub fn splitActivePane(self: *Mux, runtime: *GhosttyRuntime, cfg: Config, cell_width_px: u32, cell_height_px: u32, window_width: u32, window_height: u32, direction: SplitDirection) !void {
        const tab = self.activeTab() orelse return error.NoActiveTab;
        const new_pane = try self.createPane(runtime, cfg, cell_width_px, cell_height_px, window_width, window_height);
        errdefer {
            new_pane.deinit(runtime);
            self.allocator.destroy(new_pane);
        }
        try tab.splitActivePane(new_pane, direction, 0.5);
    }

    fn allocId(self: *Mux) usize {
        const id = self.next_id;
        self.next_id += 1;
        return id;
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
