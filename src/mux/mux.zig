const std = @import("std");
const Config = @import("../config.zig").Config;
const Pane = @import("../pane.zig").Pane;
const LaunchCommand = @import("../pty/launch_command.zig").LaunchCommand;
const GhosttyRuntime = @import("../term/ghostty.zig").Runtime;
const TerminalCallbacks = @import("../term/ghostty.zig").TerminalCallbacks;

const types = @import("types.zig");
const layout = @import("layout.zig");
const tab_mod = @import("tab.zig");
const workspace_mod = @import("workspace.zig");

const SplitNode = types.SplitNode;
const SplitDirection = types.SplitDirection;
const FocusDirection = types.FocusDirection;
const PaneBounds = types.PaneBounds;
const LayoutLeaf = types.LayoutLeaf;
const MAX_LAYOUT_LEAVES = types.MAX_LAYOUT_LEAVES;
const Tab = tab_mod.Tab;
const Workspace = workspace_mod.Workspace;

pub const Mux = struct {
    allocator: std.mem.Allocator,
    workspaces: std.ArrayList(*Workspace),
    active_workspace: ?*Workspace = null,
    next_id: usize = 1,
    /// Set by removeWorkspace to the name of the workspace that was just removed.
    /// Caller must free and set to null after consuming.
    last_removed_workspace_name: ?[]u8 = null,

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
        if (self.last_removed_workspace_name) |n| self.allocator.free(n);
        self.* = Mux.init(self.allocator);
    }

    pub fn bootstrapSingle(self: *Mux, runtime: *GhosttyRuntime, callbacks: TerminalCallbacks, cfg: Config, cell_width_px: u32, cell_height_px: u32, window_width: u32, window_height: u32) !void {
        if (self.workspaces.items.len != 0) return error.MuxAlreadyBootstrapped;

        const workspace = try self.createBootstrappedWorkspace(runtime, callbacks, cfg, cell_width_px, cell_height_px, window_width, window_height, null, null, null, null);
        try self.workspaces.append(self.allocator, workspace);
        self.active_workspace = workspace;
    }

    pub fn newWorkspace(self: *Mux, runtime: *GhosttyRuntime, callbacks: TerminalCallbacks, cfg: Config, cell_width_px: u32, cell_height_px: u32, window_width: u32, window_height: u32, inherited_cwd: ?[]const u8, domain_name: ?[]const u8, launch_command: ?LaunchCommand, name: ?[]const u8) !void {
        const workspace = try self.createBootstrappedWorkspace(runtime, callbacks, cfg, cell_width_px, cell_height_px, window_width, window_height, inherited_cwd, domain_name, launch_command, name);
        try workspace.setDefaultCwd(inherited_cwd);
        try self.workspaces.append(self.allocator, workspace);
        self.active_workspace = workspace;
    }

    fn createBootstrappedWorkspace(self: *Mux, runtime: *GhosttyRuntime, callbacks: TerminalCallbacks, cfg: Config, cell_width_px: u32, cell_height_px: u32, window_width: u32, window_height: u32, inherited_cwd: ?[]const u8, domain_name: ?[]const u8, launch_command: ?LaunchCommand, name: ?[]const u8) !*Workspace {
        const workspace = try self.createWorkspace();
        var workspace_owned_by_mux = false;
        defer if (!workspace_owned_by_mux) {
            workspace.deinit(runtime);
            self.allocator.destroy(workspace);
        };

        if (name) |value| {
            try workspace.setName(value);
        }

        const tab = try self.createTab();
        var tab_owned_by_workspace = false;
        defer if (!tab_owned_by_workspace) {
            tab.deinit(runtime);
            self.allocator.destroy(tab);
        };

        const resolved_domain = domain_name orelse cfg.defaultDomainName();
        var workspace_id_buf: [32]u8 = undefined;
        const workspace_id = try std.fmt.bufPrint(&workspace_id_buf, "{d}", .{workspace.id});
        const pane = try self.createPane(runtime, callbacks, cfg, cell_width_px, cell_height_px, window_width, window_height, inherited_cwd, resolved_domain, launch_command, workspace_id);
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
        for (self.workspaces.items) |ws| {
            if (ws.tabById(id)) |tab| return tab;
        }
        return null;
    }

    fn tabContainingPane(self: *Mux, needle: *Pane) ?*Tab {
        for (self.workspaces.items) |ws| {
            for (ws.tabs.items) |tab| {
                for (tab.panes.items) |pane| {
                    if (pane == needle) return tab;
                }
            }
        }
        return null;
    }

    pub fn focusPaneById(self: *Mux, pane_id: usize) bool {
        for (self.workspaces.items) |ws| {
            for (ws.tabs.items) |tab| {
                for (tab.panes.items) |pane| {
                    if (@intFromPtr(pane) != pane_id) continue;
                    self.active_workspace = ws;
                    ws.active_tab = tab;
                    tab.active_pane = pane;
                    return true;
                }
            }
        }
        return false;
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

    pub fn splitContainingPane(self: *Mux, pane: *Pane, direction: SplitDirection) ?*SplitNode {
        const tab = self.activeTab() orelse return null;
        const root = tab.root_split orelse return null;
        return layout.findSplitContaining(root, pane, direction);
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
        const tab = self.tabContainingPane(pane) orelse return false;
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

    pub fn createPane(self: *Mux, runtime: *GhosttyRuntime, callbacks: TerminalCallbacks, cfg: Config, cell_width_px: u32, cell_height_px: u32, window_width: u32, window_height: u32, inherited_cwd: ?[]const u8, domain_name: ?[]const u8, launch_command: ?LaunchCommand, workspace_id: ?[]const u8) !*Pane {
        const pane = try self.allocator.create(Pane);
        pane.* = Pane.init(self.allocator);
        errdefer self.allocator.destroy(pane);
        errdefer pane.deinit(runtime);
        try pane.bootstrap(runtime, callbacks, cfg, cell_width_px, cell_height_px, window_width, window_height, inherited_cwd, domain_name, launch_command, workspace_id);
        return pane;
    }

    /// Split the active pane, spawning a new pane in the given direction.
    /// The new pane becomes the active pane.
    pub fn newTab(self: *Mux, runtime: *GhosttyRuntime, callbacks: TerminalCallbacks, cfg: Config, cell_width_px: u32, cell_height_px: u32, window_width: u32, window_height: u32, domain_name: ?[]const u8, launch_command: ?LaunchCommand) !void {
        const ws = self.activeWorkspace() orelse return error.NoActiveWorkspace;
        const current_pane = self.activePane();
        const resolved_domain = domain_name orelse cfg.defaultDomainName();
        const inherited_cwd: ?[]const u8 = if (current_pane) |pane|
            if (pane.cwd.len > 0 and std.mem.eql(u8, pane.domain_name, resolved_domain orelse "")) pane.cwd else null
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
        var workspace_id_buf: [32]u8 = undefined;
        const workspace_id = try std.fmt.bufPrint(&workspace_id_buf, "{d}", .{ws.id});
        const pane = try self.createPane(runtime, callbacks, cfg, cell_width_px, cell_height_px, window_width, window_height, inherited_cwd, resolved_domain, launch_command, workspace_id);
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

    pub fn closePaneById(self: *Mux, runtime: *GhosttyRuntime, pane_id: usize) bool {
        for (self.workspaces.items) |ws| {
            for (ws.tabs.items) |tab| {
                for (tab.panes.items) |pane| {
                    if (@intFromPtr(pane) != pane_id) continue;

                    self.active_workspace = ws;
                    ws.active_tab = tab;

                    const tab_empty = tab.closePane(runtime, pane);
                    if (tab_empty) {
                        ws.closeTab(runtime);
                        if (ws.tabs.items.len == 0) return self.removeWorkspace(runtime, ws);
                    }
                    return false;
                }
            }
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

    pub fn closeWorkspace(self: *Mux, runtime: *GhosttyRuntime, workspace_id: ?usize) bool {
        const workspace = if (workspace_id) |target_id|
            self.workspaceById(target_id)
        else
            self.activeWorkspace() orelse return true;
        if (workspace == null) return false;
        return self.removeWorkspace(runtime, workspace.?);
    }

    pub fn workspaceById(self: *Mux, id: usize) ?*Workspace {
        for (self.workspaces.items) |workspace| {
            if (workspace.id == id) return workspace;
        }
        return null;
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
        const resolved_domain = domain_name orelse if (source_pane.domain_name.len > 0)
            source_pane.domain_name
        else
            cfg.defaultDomainName();
        const same_domain = if (domain_name) |dn|
            std.mem.eql(u8, source_pane.domain_name, dn)
        else
            true;
        const inherited_cwd: ?[]const u8 = if (cwd) |value|
            value
        else if (source_pane.cwd.len > 0 and same_domain)
            source_pane.cwd
        else
            null;
        const ws = self.activeWorkspace().?;
        var workspace_id_buf: [32]u8 = undefined;
        const workspace_id = try std.fmt.bufPrint(&workspace_id_buf, "{d}", .{ws.id});
        const new_pane = try self.createPane(runtime, callbacks, cfg, cell_width_px, cell_height_px, window_width, window_height, inherited_cwd, resolved_domain, launch_command, workspace_id);
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
            new_pane.restore_ratio = std.math.clamp(ratio, 0.05, 0.95);
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
        if (layout.findSplitContaining(root, current, direction)) |node| {
            node.ratio = std.math.clamp(node.ratio + delta, 0.05, 0.95);
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

        const target_subtree = layout.findFocusTargetSubtree(tab.root_split orelse return, current, direction) orelse return;

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
            if (!layout.subtreeContainsPane(target_subtree, leaf.pane)) continue;

            const overlap = switch (direction) {
                .left, .right => layout.intervalOverlap(cb.y, cb.height, leaf.bounds.y, leaf.bounds.height),
                .up, .down => layout.intervalOverlap(cb.x, cb.width, leaf.bounds.x, leaf.bounds.width),
            };
            const primary_gap = layout.primaryAxisGap(cb, leaf.bounds, direction);
            const secondary_gap = layout.secondaryAxisGap(cb, leaf.bounds, direction);

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

    /// Move a tab to a different workspace by index (0-based).
    pub fn moveTabToWorkspace(self: *Mux, runtime: *GhosttyRuntime, tab_id: usize, target_workspace_index: usize) bool {
        var source_ws: ?*Workspace = null;
        var tab: ?*Tab = null;
        for (self.workspaces.items) |ws| {
            if (ws.tabById(tab_id)) |t| {
                source_ws = ws;
                tab = t;
                break;
            }
        }
        const src = source_ws orelse return false;
        const t = tab orelse return false;
        if (target_workspace_index >= self.workspaces.items.len) return false;
        const target = self.workspaces.items[target_workspace_index];
        if (target == src) return false;
        src.detachTab(t);
        target.insertTab(t) catch {
            src.appendTab(t) catch {};
            return false;
        };
        self.active_workspace = target;
        if (src.tabs.items.len == 0) _ = self.removeWorkspace(runtime, src);
        return true;
    }

    /// Move a pane to a different workspace by index (0-based).
    /// The pane is placed in a new tab in the target workspace.
    pub fn movePaneToWorkspace(self: *Mux, runtime: *GhosttyRuntime, pane_id: usize, target_workspace_index: usize) bool {
        var source_tab: ?*Tab = null;
        var source_ws: ?*Workspace = null;
        var pane: ?*Pane = null;
        for (self.workspaces.items) |ws| {
            for (ws.tabs.items) |tab| {
                for (tab.panes.items) |p| {
                    if (@intFromPtr(p) == pane_id) {
                        pane = p;
                        source_tab = tab;
                        source_ws = ws;
                        break;
                    }
                } else continue;
                break;
            } else continue;
            break;
        }
        const p = pane orelse return false;
        const src_tab = source_tab orelse return false;
        const src_ws = source_ws orelse return false;
        if (target_workspace_index >= self.workspaces.items.len) return false;
        const target_ws = self.workspaces.items[target_workspace_index];
        if (target_ws == src_ws) return false;
        src_tab.detachPane(p);
        const tab_empty = src_tab.panes.items.len == 0;
        const new_tab = self.allocator.create(Tab) catch {
            src_tab.appendPane(p) catch {};
            return false;
        };
        new_tab.* = Tab.init(self.allocator, self.allocId());
        new_tab.appendPane(p) catch {
            self.allocator.destroy(new_tab);
            src_tab.appendPane(p) catch {};
            return false;
        };
        target_ws.insertTab(new_tab) catch {
            self.allocator.destroy(new_tab);
            src_tab.appendPane(p) catch {};
            return false;
        };
        if (tab_empty) {
            src_ws.detachTab(src_tab);
            src_tab.deinit(runtime);
            self.allocator.destroy(src_tab);
            if (src_ws.tabs.items.len == 0) _ = self.removeWorkspace(runtime, src_ws);
        }
        self.active_workspace = target_ws;
        return true;
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
                if (!pane.hasLiveChildForCleanup() and dead_count < dead_buf.len) {
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
        const removed_was_active = self.active_workspace == workspace;

        if (self.last_removed_workspace_name) |n| self.allocator.free(n);
        self.last_removed_workspace_name = if (workspace.name) |n| self.allocator.dupe(u8, n) catch null else null;

        _ = self.workspaces.orderedRemove(remove_idx);
        workspace.deinit(runtime);
        self.allocator.destroy(workspace);

        if (self.workspaces.items.len == 0) {
            self.active_workspace = null;
            return true;
        }

        if (!removed_was_active) {
            return false;
        }

        const next_idx = if (remove_idx >= self.workspaces.items.len) self.workspaces.items.len - 1 else remove_idx;
        self.active_workspace = self.workspaces.items[next_idx];
        return false;
    }
};
