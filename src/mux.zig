const std = @import("std");
const Config = @import("config.zig").Config;
const Pane = @import("pane.zig").Pane;
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

    /// Remove `pane` from this tab's split tree and panes list.
    /// The sibling of the removed leaf replaces the parent split node (collapsing
    /// the split). Focus moves to the sibling; if no sibling exists the root is
    /// cleared. Returns true if the tab is now empty (caller should close it).
    pub fn closePane(self: *Tab, runtime: *GhosttyRuntime, pane: *Pane) bool {
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
    name: ?[]u8 = null,
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

        const workspace = try self.createBootstrappedWorkspace(runtime, callbacks, cfg, cell_width_px, cell_height_px, window_width, window_height);
        try self.workspaces.append(self.allocator, workspace);
        self.active_workspace = workspace;
    }

    pub fn newWorkspace(self: *Mux, runtime: *GhosttyRuntime, callbacks: TerminalCallbacks, cfg: Config, cell_width_px: u32, cell_height_px: u32, window_width: u32, window_height: u32) !void {
        const workspace = try self.createBootstrappedWorkspace(runtime, callbacks, cfg, cell_width_px, cell_height_px, window_width, window_height);
        try self.workspaces.append(self.allocator, workspace);
        self.active_workspace = workspace;
    }

    fn createBootstrappedWorkspace(self: *Mux, runtime: *GhosttyRuntime, callbacks: TerminalCallbacks, cfg: Config, cell_width_px: u32, cell_height_px: u32, window_width: u32, window_height: u32) !*Workspace {
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

        const pane = try self.createPane(runtime, callbacks, cfg, cell_width_px, cell_height_px, window_width, window_height);
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

    pub fn createPane(self: *Mux, runtime: *GhosttyRuntime, callbacks: TerminalCallbacks, cfg: Config, cell_width_px: u32, cell_height_px: u32, window_width: u32, window_height: u32) !*Pane {
        const pane = try self.allocator.create(Pane);
        pane.* = Pane.init(self.allocator);
        errdefer self.allocator.destroy(pane);
        errdefer pane.deinit(runtime);
        try pane.bootstrap(runtime, callbacks, cfg, cell_width_px, cell_height_px, window_width, window_height);
        return pane;
    }

    /// Split the active pane, spawning a new pane in the given direction.
    /// The new pane becomes the active pane.
    pub fn newTab(self: *Mux, runtime: *GhosttyRuntime, callbacks: TerminalCallbacks, cfg: Config, cell_width_px: u32, cell_height_px: u32, window_width: u32, window_height: u32) !void {
        const ws = self.activeWorkspace() orelse return error.NoActiveWorkspace;
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
        const pane = try self.createPane(runtime, callbacks, cfg, cell_width_px, cell_height_px, window_width, window_height);
        try tab.appendPane(pane);
    }

    /// Close the active tab. Returns true if no tabs remain (app should quit).
    pub fn closeTab(self: *Mux, runtime: *GhosttyRuntime) bool {
        const ws = self.activeWorkspace() orelse return true;
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

    pub fn splitActivePane(self: *Mux, runtime: *GhosttyRuntime, callbacks: TerminalCallbacks, cfg: Config, cell_width_px: u32, cell_height_px: u32, window_width: u32, window_height: u32, direction: SplitDirection, ratio: f32) !void {
        const tab = self.activeTab() orelse return error.NoActiveTab;
        const new_pane = try self.createPane(runtime, callbacks, cfg, cell_width_px, cell_height_px, window_width, window_height);
        errdefer {
            new_pane.deinit(runtime);
            self.allocator.destroy(new_pane);
        }
        try tab.splitActivePane(new_pane, direction, ratio);
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

        // Collect dead panes from active tab (we can't remove while iterating).
        var dead_buf: [64]*Pane = undefined;
        var dead_count: usize = 0;

        const tab = ws.activeTab() orelse return false;
        for (tab.panes.items) |pane| {
            if (!pane.hasLiveChild() and dead_count < dead_buf.len) {
                dead_buf[dead_count] = pane;
                dead_count += 1;
            }
        }

        if (dead_count == 0) return false;

        for (dead_buf[0..dead_count]) |pane| {
            const tab_empty = tab.closePane(runtime, pane);
            if (tab_empty) {
                // Close the tab itself.
                ws.closeTab(runtime);
                // If workspace has no more tabs, and this is the only workspace,
                // signal quit.
                if (ws.tabs.items.len == 0) return self.removeWorkspace(runtime, ws);
                break; // tab is gone, stop iterating dead_buf for this tab
            }
        }

        // Re-register callbacks for the new active pane (focus may have moved).
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
