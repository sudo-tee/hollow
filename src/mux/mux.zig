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
const dock_mod = @import("dock.zig");

const SplitNode = types.SplitNode;
const SplitDirection = types.SplitDirection;
const FocusDirection = types.FocusDirection;
const PaneBounds = types.PaneBounds;
const LayoutLeaf = types.LayoutLeaf;
const MAX_LAYOUT_LEAVES = types.MAX_LAYOUT_LEAVES;
const Tab = tab_mod.Tab;
const Workspace = workspace_mod.Workspace;
const Docks = dock_mod.Docks;
const DockScope = dock_mod.DockScope;
const PaneEdge = types.PaneEdge;

pub const Mux = struct {
    pub const PaneSplitInfo = Tab.PaneSplitInfo;

    allocator: std.mem.Allocator,
    workspaces: std.ArrayList(*Workspace),
    active_workspace: ?*Workspace = null,
    session_workspace_count: usize = 0,
    next_id: usize = 1,
    next_pane_id: std.atomic.Value(usize) = .init(1),
    host_context: ?*anyopaque = null,
    host_wake: @import("../pty/wake.zig").Wake = .{},
    pane_created: ?*const fn (*anyopaque, *Pane) void = null,
    pane_closing: ?*const fn (*anyopaque, *Pane) void = null,
    spawn_filter: @import("../pty/spawn_spec.zig").Filter = .{},
    pty_host: @import("../pty/spawn_spec.zig").HostResolver = .{},
    /// Set by removeWorkspace to the name of the workspace that was just removed.
    /// Caller must free and set to null after consuming.
    last_removed_workspace_name: ?[]u8 = null,
    /// Window-scoped docks, shown in every workspace outside the workspace docks.
    global_docks: Docks = .{},
    /// Focused dock pane; overrides the active tab's pane while it is shown.
    focused_dock: ?*Pane = null,

    pub const DockLocation = struct {
        scope: DockScope,
        edge: PaneEdge,
        /// Owning workspace for `workspace` scope.
        workspace: ?*Workspace = null,
        /// The dock's share of its carved region.
        ratio: f32 = 0,
    };

    pub const PaneIterator = struct {
        mux: *Mux,
        workspace_index: usize = 0,
        pane_iter: ?Workspace.PaneIterator = null,
        dock_iter: ?Docks.Iterator = null,
        active_first: ?*Pane = null,
        active_first_yielded: bool = false,

        pub fn next(self: *PaneIterator) ?*Pane {
            if (!self.active_first_yielded) {
                self.active_first_yielded = true;
                if (self.active_first) |pane| return pane;
            }

            while (true) {
                if (self.pane_iter) |*pane_iter| {
                    if (pane_iter.next()) |pane| {
                        if (self.active_first != null and pane == self.active_first.?) continue;
                        return pane;
                    }
                    self.pane_iter = null;
                }

                if (self.workspace_index >= self.mux.workspaces.items.len) {
                    if (self.dock_iter == null) self.dock_iter = self.mux.global_docks.iterator();
                    while (self.dock_iter.?.next()) |pane| {
                        if (self.active_first != null and pane == self.active_first.?) continue;
                        return pane;
                    }
                    return null;
                }
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
        self.global_docks.deinit(self.allocator, runtime);
        if (self.last_removed_workspace_name) |n| self.allocator.free(n);
        self.* = Mux.init(self.allocator);
    }

    fn notifyCreated(self: *Mux, pane: *Pane) void {
        const context = self.host_context orelse return;
        if (self.pane_created) |callback| callback(context, pane);
    }

    fn notifyClosing(self: *Mux, pane: *Pane) void {
        const context = self.host_context orelse return;
        if (self.pane_closing) |callback| callback(context, pane);
    }

    fn notifyTabClosing(self: *Mux, tab: *Tab) void {
        for (tab.panes.items) |pane| self.notifyClosing(pane);
    }

    pub fn bootstrapSingle(self: *Mux, runtime: *GhosttyRuntime, callbacks: TerminalCallbacks, cfg: Config, cell_width_px: u32, cell_height_px: u32, window_width: u32, window_height: u32) !void {
        if (self.workspaces.items.len != 0) return error.MuxAlreadyBootstrapped;

        const workspace = try self.createBootstrappedWorkspace(runtime, callbacks, cfg, cell_width_px, cell_height_px, window_width, window_height, null, null, null, null);
        errdefer {
            workspace.deinit(runtime);
            self.allocator.destroy(workspace);
        }
        try self.workspaces.append(self.allocator, workspace);
        self.active_workspace = workspace;
        self.notifyCreated(self.activePane().?);
    }

    pub fn newWorkspace(self: *Mux, runtime: *GhosttyRuntime, callbacks: TerminalCallbacks, cfg: Config, cell_width_px: u32, cell_height_px: u32, window_width: u32, window_height: u32, inherited_cwd: ?[]const u8, domain_name: ?[]const u8, launch_command: ?LaunchCommand, name: ?[]const u8) !void {
        const workspace = try self.createBootstrappedWorkspace(runtime, callbacks, cfg, cell_width_px, cell_height_px, window_width, window_height, inherited_cwd, domain_name, launch_command, name);
        errdefer {
            workspace.deinit(runtime);
            self.allocator.destroy(workspace);
        }
        try workspace.setDefaultCwd(inherited_cwd);
        try self.workspaces.append(self.allocator, workspace);
        self.active_workspace = workspace;
        self.notifyCreated(self.activePane().?);
    }

    /// Publish views for an attached owner session without running a local
    /// shell. Validate saved geometry before allocating or binding views.
    /// Sessions with no GUI layout get
    /// one tab per owner pane in owner order. No owner state is overwritten.
    pub fn addSessionWorkspace(self: *Mux, runtime: *GhosttyRuntime, callbacks: TerminalCallbacks, cfg: Config, controller: *@import("../session/controller.zig").Controller, info: @import("../agent/session_protocol.zig").SessionInfo, domain: ?[]const u8, before_replace: ?*const fn (*Pane) void) !*Workspace {
        return self.addSessionWorkspaceNamed(runtime, callbacks, cfg, controller, info, domain, before_replace, null);
    }

    pub fn addSessionWorkspaceNamed(self: *Mux, runtime: *GhosttyRuntime, callbacks: TerminalCallbacks, cfg: Config, controller: *@import("../session/controller.zig").Controller, info: @import("../agent/session_protocol.zig").SessionInfo, domain: ?[]const u8, before_replace: ?*const fn (*Pane) void, name: ?[]const u8) !*Workspace {
        const codec = @import("../session/layout.zig");
        const geometry = @import("session_layout.zig");
        if (info.panes.len == 0) return error.EmptySession;
        if (info.panes.len > codec.max_panes) return error.InvalidSessionLayout;
        if (!std.mem.eql(u8, controller.session_id, info.id)) return error.WrongSession;
        var ids: [codec.max_panes]u32 = undefined;
        for (info.panes, 0..) |remote, i| {
            if (remote.id == 0) return error.InvalidSessionLayout;
            for (ids[0..i]) |id| if (id == remote.id) return error.InvalidSessionLayout;
            ids[i] = remote.id;
        }
        const saved = if (info.layout.len != 0) try codec.decode(self.allocator, info.layout, ids[0..info.panes.len]) else null;
        defer if (saved) |value| value.deinit();
        const workspace = try self.createWorkspace();
        errdefer {
            workspace.deinit(runtime);
            self.allocator.destroy(workspace);
        }
        workspace.session_controller = controller;
        if (name) |value| {
            try workspace.setName(value);
        } else if (saved) |value| {
            if (value.value.name) |saved_name| try workspace.setName(saved_name);
        }
        const tab_count = if (saved) |value| value.value.tabs.len else info.panes.len;
        for (0..tab_count) |index| {
            const tab = try self.createTab();
            var tab_owned = false;
            defer if (!tab_owned) {
                tab.deinit(runtime);
                self.allocator.destroy(tab);
            };
            if (saved) |value| {
                const layout_tab = value.value.tabs[index];
                for (layout_tab.nodes) |node| if (node.pane) |id| {
                    for (info.panes) |remote| if (remote.id == id) {
                        try self.appendSessionView(tab, runtime, callbacks, cfg, controller, remote, domain, before_replace);
                        break;
                    };
                };
                for (layout_tab.floating) |floating| {
                    for (info.panes) |remote| if (remote.id == floating.pane) {
                        try self.appendSessionView(tab, runtime, callbacks, cfg, controller, remote, domain, before_replace);
                        break;
                    };
                }
                try geometry.restoreTab(tab, layout_tab);
            } else {
                try self.appendSessionView(tab, runtime, callbacks, cfg, controller, info.panes[index], domain, before_replace);
                const root = try self.allocator.create(SplitNode);
                root.* = SplitNode.initPane(tab.panes.items[0]);
                tab.root_split = root;
                tab.active_pane = tab.panes.items[0];
            }
            try workspace.appendTab(tab);
            tab_owned = true;
        }
        if (saved) |value| workspace.active_tab = workspace.tabs.items[value.value.active_tab];
        try self.workspaces.append(self.allocator, workspace);
        self.active_workspace = workspace;
        var panes = workspace.paneIterator();
        self.session_workspace_count += 1;
        while (panes.next()) |pane| self.notifyCreated(pane);
        return workspace;
    }

    fn appendSessionView(self: *Mux, tab: *Tab, runtime: *GhosttyRuntime, callbacks: TerminalCallbacks, cfg: Config, controller: *@import("../session/controller.zig").Controller, remote: @import("../agent/session_protocol.zig").PaneInfo, domain: ?[]const u8, before_replace: ?*const fn (*Pane) void) !void {
        const pane = try self.allocator.create(Pane);
        pane.* = Pane.init(self.allocator);
        var owned = false;
        defer if (!owned) {
            pane.deinit(runtime);
            self.allocator.destroy(pane);
        };
        pane.id = self.reservePaneId();
        pane.host_context = self.host_context;
        const term = &pane.content.terminal;
        term.host_wake = self.host_wake;
        var pane_cfg = cfg;
        pane_cfg.cols = remote.cols;
        pane_cfg.rows = remote.rows;
        try term.bootstrapSession(pane, runtime, callbacks, pane_cfg, @import("../pty/session.zig").SessionPty.init(self.allocator, controller.connection, remote.id, controller.generation, remote.exit));
        term.session_before_replace = before_replace;
        if (domain) |name| term.domain_name = try self.allocator.dupe(u8, name);
        if (remote.cwd.len > 0) pane.setCwd(remote.cwd);
        try tab.panes.append(self.allocator, pane);
        owned = true;
        try controller.bind(pane);
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

    pub fn controllerForPane(self: *Mux, id: usize) ?*@import("../session/controller.zig").Controller {
        if (self.session_workspace_count == 0) return null;
        for (self.workspaces.items) |workspace| {
            const controller = workspace.session_controller orelse continue;
            var panes = workspace.paneIterator();
            while (panes.next()) |pane| if (pane.id == id) return controller;
        }
        return null;
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
                    if (pane.id != pane_id) continue;
                    if (pane.is_hidden) return false;
                    self.active_workspace = ws;
                    ws.active_tab = tab;
                    tab.active_pane = pane;
                    self.focused_dock = null;
                    return true;
                }
            }
        }
        var docked = self.dockPaneIterator();
        while (docked.next()) |pane| {
            if (pane.id != pane_id) continue;
            if (pane.is_hidden) return false;
            const location = self.paneDock(pane).?;
            if (location.workspace) |ws| self.active_workspace = ws;
            self.focused_dock = pane;
            return true;
        }
        return false;
    }

    pub fn setActivePane(self: *Mux, pane: *Pane) void {
        if (pane.is_hidden) return;
        if (self.paneDock(pane) != null) {
            if (self.dockIsShown(pane)) self.focused_dock = pane;
            return;
        }
        self.focused_dock = null;
        if (self.activeTab()) |tab| {
            tab.active_pane = pane;
        }
    }

    pub fn activePane(self: *Mux) ?*Pane {
        if (self.focusedDockPane()) |pane| return pane;
        const tab = self.activeTab() orelse return null;
        return tab.activePane();
    }

    /// The focused dock pane, only while it is on screen.
    pub fn focusedDockPane(self: *Mux) ?*Pane {
        const pane = self.focused_dock orelse return null;
        return if (self.dockIsShown(pane)) pane else null;
    }

    /// Hand focus back to the active tab's pane.
    pub fn focusTab(self: *Mux) void {
        self.focused_dock = null;
    }

    pub const DockPaneIterator = struct {
        mux: *Mux,
        workspace_index: usize = 0,
        iter: ?Docks.Iterator = null,

        pub fn next(self: *DockPaneIterator) ?*Pane {
            while (true) {
                if (self.iter) |*iter| {
                    if (iter.next()) |pane| return pane;
                }
                if (self.workspace_index > self.mux.workspaces.items.len) return null;
                const docks = if (self.workspace_index == 0)
                    &self.mux.global_docks
                else
                    &self.mux.workspaces.items[self.workspace_index - 1].docks;
                self.workspace_index += 1;
                self.iter = docks.iterator();
            }
        }
    };

    /// Every docked pane: global docks first, then each workspace's docks.
    pub fn dockPaneIterator(self: *Mux) DockPaneIterator {
        return .{ .mux = self };
    }

    pub fn paneDock(self: *Mux, pane: *const Pane) ?DockLocation {
        if (self.global_docks.edgeOf(pane)) |edge| return .{ .scope = .global, .edge = edge, .ratio = self.global_docks.size(edge) };
        for (self.workspaces.items) |ws| {
            if (ws.docks.edgeOf(pane)) |edge| return .{ .scope = .workspace, .edge = edge, .workspace = ws, .ratio = ws.docks.size(edge) };
        }
        return null;
    }

    fn docksFor(self: *Mux, location: DockLocation) *Docks {
        return if (location.workspace) |ws| &ws.docks else &self.global_docks;
    }

    /// Visible, and in a global dock or a dock of the active workspace.
    pub fn dockIsShown(self: *Mux, pane: *const Pane) bool {
        if (pane.is_hidden) return false;
        const location = self.paneDock(pane) orelse return false;
        return location.workspace == null or location.workspace == self.active_workspace;
    }

    /// Carve the visible docks out of `bounds` (global outermost), appending
    /// their leaves to `out`; `bounds` is left holding the tab region.
    pub fn layoutDocks(self: *Mux, bounds: *PaneBounds, out: []LayoutLeaf, written: *usize, cell_w: u32, cell_h: u32) void {
        self.global_docks.carve(bounds, out, written, cell_w, cell_h);
        if (self.active_workspace) |ws| ws.docks.carve(bounds, out, written, cell_w, cell_h);
    }

    pub fn hitTestDockDivider(self: *Mux, bounds: PaneBounds, mx: f32, my: f32, radius: f32, cell_w: u32, cell_h: u32) ?types.DividerHit {
        var region = bounds;
        if (self.global_docks.hitTestDivider(&region, mx, my, radius, cell_w, cell_h)) |hit| return hit;
        const ws = self.active_workspace orelse return null;
        return ws.docks.hitTestDivider(&region, mx, my, radius, cell_w, cell_h);
    }

    /// Ratio nodes of the shown docks are valid drag targets.
    pub fn dockContainsNode(self: *Mux, node: *const SplitNode) bool {
        if (self.global_docks.containsNode(node)) return true;
        const ws = self.active_workspace orelse return false;
        return ws.docks.containsNode(node);
    }

    fn dockTarget(self: *Mux, scope: DockScope, owner: ?*Workspace) !*Docks {
        return switch (scope) {
            .global => &self.global_docks,
            .workspace => &(owner orelse self.active_workspace orelse return error.NoActiveWorkspace).docks,
        };
    }

    /// Move a tab pane (or a docked pane) into a dock slot. The pane keeps its
    /// PTY/session; only its layout owner changes.
    pub fn dockPane(self: *Mux, pane: *Pane, edge: PaneEdge, scope: DockScope, size: f32) !void {
        if (self.paneDock(pane)) |current| {
            const target = try self.dockTarget(scope, current.workspace);
            if (target.slot(edge).pane) |occupant| if (occupant != pane) return error.DockOccupied;
            _ = self.docksFor(current).remove(pane);
            target.place(edge, pane, size) catch unreachable;
        } else {
            var owner: ?*Workspace = null;
            const tab = for (self.workspaces.items) |ws| {
                if (ws.tabContainingPane(pane)) |tab| {
                    owner = ws;
                    break tab;
                }
            } else return error.PaneNotFound;
            if (tab.panes.items.len <= 1) return error.LastPaneInTab;
            const target = try self.dockTarget(scope, owner);
            if (target.slot(edge).pane != null) return error.DockOccupied;
            if (pane.is_floating) _ = tab.setPaneFloating(pane, false);
            tab.detachPane(pane);
            target.place(edge, pane, size) catch unreachable;
        }
        pane.is_floating = false;
        pane.placed_edge = null;
        pane.is_hidden = false;
        if (self.dockIsShown(pane)) self.focused_dock = pane;
    }

    /// The pane holding a dock slot of the active context, if any.
    pub fn dockOccupant(self: *Mux, scope: DockScope, edge: PaneEdge) ?*Pane {
        const docks = self.dockTarget(scope, null) catch return null;
        return docks.slot(edge).pane;
    }

    /// Publish a freshly created pane straight into a dock slot.
    pub fn dockNewPane(self: *Mux, pane: *Pane, edge: PaneEdge, scope: DockScope, size: f32) !void {
        const target = try self.dockTarget(scope, null);
        try target.place(edge, pane, size);
        self.focused_dock = pane;
        self.notifyCreated(pane);
    }

    /// Return a docked pane to the active tab along the same edge and size.
    pub fn undockPane(self: *Mux, pane: *Pane) !void {
        const location = self.paneDock(pane) orelse return error.PaneNotDocked;
        const tab = self.activeTab() orelse return error.NoActiveTab;
        const docks = self.docksFor(location);
        const size = docks.size(location.edge);
        try tab.splitEdge(pane, dock_mod.directionFor(location.edge), size, dock_mod.placesFirst(location.edge));
        _ = docks.remove(pane);
        pane.is_hidden = false;
        if (self.focused_dock == pane) self.focused_dock = null;
    }

    fn destroyDockPane(self: *Mux, runtime: *GhosttyRuntime, pane: *Pane) void {
        const location = self.paneDock(pane) orelse return;
        self.notifyClosing(pane);
        _ = self.docksFor(location).remove(pane);
        if (self.focused_dock == pane) self.focused_dock = null;
        pane.deinit(runtime);
        self.allocator.destroy(pane);
    }

    fn closeDeadDockPanes(self: *Mux, runtime: *GhosttyRuntime, docks: *Docks) void {
        for (&docks.slots) |*entry| {
            const pane = entry.pane orelse continue;
            const term = pane.asTerminal() orelse continue;
            if (!term.retain_on_exit and !term.hasLiveChild()) self.destroyDockPane(runtime, pane);
        }
    }

    pub fn paneIterator(self: *Mux) PaneIterator {
        return .{ .mux = self };
    }

    pub fn paneIteratorActiveFirst(self: *Mux) PaneIterator {
        return .{ .mux = self, .active_first = self.activePane() };
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

    pub fn paneSplitInfo(self: *Mux, pane: *Pane) ?PaneSplitInfo {
        const tab = self.tabContainingPane(pane) orelse return null;
        return tab.splitInfoForPane(pane);
    }

    pub fn paneEdge(self: *Mux, pane: *Pane) ?types.PaneEdge {
        const tab = self.tabContainingPane(pane) orelse return null;
        return tab.paneEdge(pane);
    }

    pub fn togglePaneMaximized(self: *Mux, pane: *Pane, show_background: bool) bool {
        if (pane.is_hidden) return false;
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

    /// Does not detach or destroy the pane, PTY, or session transport.
    pub fn setPaneVisible(self: *Mux, pane: *Pane, visible: bool) bool {
        if (self.paneDock(pane) != null) {
            pane.is_hidden = !visible;
            if (!visible and self.focused_dock == pane) self.focused_dock = null;
            return true;
        }
        const tab = self.tabContainingPane(pane) orelse return false;
        return tab.setPaneVisible(pane, visible);
    }

    pub fn setPaneFloating(self: *Mux, pane: *Pane, floating: bool) bool {
        if (pane.is_hidden) return false;
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
        if (pane.is_hidden) return false;
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
        if (cfg.persistForDomain(domain_name)) return error.PersistentDomainRequiresWorkspace;
        const pane = try self.allocator.create(Pane);
        pane.* = Pane.init(self.allocator);
        pane.id = self.reservePaneId();
        pane.host_context = self.host_context;
        const term = pane.asTerminal().?;
        term.host_wake = self.host_wake;
        term.spawn_filter = self.spawn_filter;
        term.pty_host = self.pty_host;
        errdefer self.allocator.destroy(pane);
        errdefer pane.deinit(runtime);
        try term.bootstrap(pane, runtime, callbacks, cfg, cell_width_px, cell_height_px, window_width, window_height, inherited_cwd, domain_name, launch_command, workspace_id);
        return pane;
    }

    /// Allocate an unpublished GUI pane without terminal, domain, or PTY setup.
    /// The caller owns it until splitActivePaneWith succeeds.
    pub fn createLuaPane(self: *Mux) !*Pane {
        return self.createLuaPaneWithId(self.reservePaneId());
    }

    /// Lua callbacks may reserve IDs before frame-thread layout insertion.
    pub fn reservePaneId(self: *Mux) usize {
        return self.next_pane_id.fetchAdd(1, .monotonic);
    }

    pub fn createLuaPaneWithId(self: *Mux, id: usize) !*Pane {
        std.debug.assert(id != 0);
        const pane = try self.allocator.create(Pane);
        errdefer self.allocator.destroy(pane);
        const surface = try self.allocator.create(@import("../ui/lua_surface.zig").LuaSurface);
        surface.* = .{};
        pane.* = Pane.initLua(self.allocator, surface);
        pane.id = id;
        pane.host_context = self.host_context;
        return pane;
    }

    /// Split the active pane, spawning a new pane in the given direction.
    /// The new pane becomes the active pane.
    pub fn newTab(self: *Mux, runtime: *GhosttyRuntime, callbacks: TerminalCallbacks, cfg: Config, cell_width_px: u32, cell_height_px: u32, window_width: u32, window_height: u32, cwd: ?[]const u8, domain_name: ?[]const u8, launch_command: ?LaunchCommand, insert_at_end: bool) !void {
        _ = try self.newTabWithFocus(runtime, callbacks, cfg, cell_width_px, cell_height_px, window_width, window_height, cwd, domain_name, launch_command, insert_at_end, true);
    }

    /// Nonactivating creation retains the pane and drains output without focus.
    pub fn newTabWithFocus(self: *Mux, runtime: *GhosttyRuntime, callbacks: TerminalCallbacks, cfg: Config, cell_width_px: u32, cell_height_px: u32, window_width: u32, window_height: u32, cwd: ?[]const u8, domain_name: ?[]const u8, launch_command: ?LaunchCommand, insert_at_end: bool, activate: bool) !*Tab {
        const ws = self.activeWorkspace() orelse return error.NoActiveWorkspace;
        if (ws.session_controller != null) return error.UnsupportedSessionMutation;
        const current_pane = self.activePane();
        const resolved_domain = domain_name orelse if (current_pane) |pane|
            if (pane.domainName().len > 0) pane.domainName() else cfg.defaultDomainName()
        else
            cfg.defaultDomainName();
        const inherited_cwd: ?[]const u8 = if (cwd) |value|
            if (value.len > 0) value else null
        else if (current_pane) |pane|
            if (pane.cwd.len > 0 and std.mem.eql(u8, pane.domainName(), resolved_domain orelse "")) pane.cwd else null
        else if (ws.default_cwd) |value|
            value
        else
            null;
        const previous_active = ws.active_tab;
        const tab = try ws.newTab(self.allocId(), insert_at_end);
        // Spawn filters can inspect focus during bootstrap. Do not expose the
        // new empty tab as active even transiently for a background launch.
        if (!activate) ws.active_tab = previous_active;
        errdefer {
            var remove_idx: ?usize = null;
            for (ws.tabs.items, 0..) |t, i| {
                if (t == tab) {
                    remove_idx = i;
                    break;
                }
            }
            if (remove_idx) |idx| _ = ws.tabs.orderedRemove(idx);
            tab.deinit(runtime);
            self.allocator.destroy(tab);
            ws.active_tab = previous_active;
        }
        var workspace_id_buf: [32]u8 = undefined;
        const workspace_id = try std.fmt.bufPrint(&workspace_id_buf, "{d}", .{ws.id});
        const pane = try self.createPane(runtime, callbacks, cfg, cell_width_px, cell_height_px, window_width, window_height, inherited_cwd, resolved_domain, launch_command, workspace_id);
        errdefer {
            pane.deinit(runtime);
            self.allocator.destroy(pane);
        }
        try tab.appendPane(pane);
        if (activate) self.focused_dock = null;
        if (!activate) {
            const term = pane.asTerminal().?;
            term.retain_on_exit = true;
            // Hidden jobs must parse/drain output without waiting for first focus.
            term.terminal_output_ready = true;
            ws.active_tab = previous_active;
        }
        self.notifyCreated(pane);
        return tab;
    }

    /// Publish an owned content node without spawning a seed terminal. Ownership
    /// transfers only after all fallible allocations have succeeded.
    pub fn newTabWithPane(self: *Mux, runtime: *GhosttyRuntime, pane: *Pane) !void {
        const ws = self.activeWorkspace() orelse return error.NoActiveWorkspace;
        if (ws.session_controller != null) return error.UnsupportedSessionMutation;
        const tab = try self.createTab();
        errdefer {
            tab.deinit(runtime);
            self.allocator.destroy(tab);
        }
        try ws.tabs.ensureUnusedCapacity(self.allocator, 1);
        try tab.appendPane(pane);
        ws.insertTab(tab) catch unreachable;
        self.focused_dock = null;
        self.notifyCreated(pane);
    }

    pub fn newWorkspaceWithPane(self: *Mux, runtime: *GhosttyRuntime, pane: *Pane, name: ?[]const u8) !void {
        const ws = try self.createWorkspace();
        errdefer {
            ws.deinit(runtime);
            self.allocator.destroy(ws);
        }
        if (name) |value| try ws.setName(value);
        const tab = try self.createTab();
        errdefer {
            tab.deinit(runtime);
            self.allocator.destroy(tab);
        }
        try self.workspaces.ensureUnusedCapacity(self.allocator, 1);
        try ws.tabs.ensureUnusedCapacity(self.allocator, 1);
        try tab.appendPane(pane);
        ws.tabs.appendAssumeCapacity(tab);
        ws.active_tab = tab;
        self.workspaces.appendAssumeCapacity(ws);
        self.active_workspace = ws;
        self.focused_dock = null;
        self.notifyCreated(pane);
    }

    /// Close the active tab. Returns true if no tabs remain (app should quit).
    pub fn closeTab(self: *Mux, runtime: *GhosttyRuntime) bool {
        const ws = self.activeWorkspace() orelse return true;
        if (ws.activeTab()) |tab| self.notifyTabClosing(tab);
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
        self.notifyTabClosing(ws.tabs.items[index]);
        ws.closeTab(runtime);
        if (ws.tabs.items.len > 0) return false;
        return self.removeWorkspace(runtime, ws);
    }

    /// Close the currently active pane. Kills the associated process.
    /// Returns true if the entire app should quit (no panes remain anywhere).
    pub fn closeActivePane(self: *Mux, runtime: *GhosttyRuntime) bool {
        if (self.focusedDockPane()) |pane| {
            self.destroyDockPane(runtime, pane);
            return false;
        }
        const ws = self.activeWorkspace() orelse return true;
        const tab = ws.activeTab() orelse return true;
        const pane = tab.activePane() orelse return true;

        self.notifyClosing(pane);
        const tab_empty = tab.closePane(runtime, pane);
        if (tab_empty) {
            ws.closeTab(runtime);
            if (ws.tabs.items.len == 0) return self.removeWorkspace(runtime, ws);
        }
        return false;
    }

    pub fn closePaneById(self: *Mux, runtime: *GhosttyRuntime, pane_id: usize) bool {
        return self.closePaneByIdWithFocus(runtime, pane_id, true);
    }

    pub fn closePaneByIdWithFocus(self: *Mux, runtime: *GhosttyRuntime, pane_id: usize, activate: bool) bool {
        var docked = self.dockPaneIterator();
        while (docked.next()) |pane| {
            if (pane.id != pane_id) continue;
            self.destroyDockPane(runtime, pane);
            return false;
        }
        for (self.workspaces.items) |ws| {
            for (ws.tabs.items) |tab| {
                for (tab.panes.items) |pane| {
                    if (pane.id != pane_id) continue;

                    if (activate) {
                        self.active_workspace = ws;
                        ws.active_tab = tab;
                    }

                    self.notifyClosing(pane);
                    const tab_empty = tab.closePane(runtime, pane);
                    if (tab_empty) {
                        const previous = ws.active_tab;
                        ws.active_tab = tab;
                        ws.closeTab(runtime);
                        if (previous != tab) ws.active_tab = previous;
                        if (ws.tabs.items.len == 0) return self.removeWorkspace(runtime, ws);
                    }
                    return false;
                }
            }
        }
        return false;
    }

    pub fn nextTab(self: *Mux) void {
        self.focused_dock = null;
        if (self.activeWorkspace()) |ws| ws.nextTab();
    }

    pub fn prevTab(self: *Mux) void {
        self.focused_dock = null;
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
        self.focused_dock = null;
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
        if (self.activeWorkspace()) |ws| if (ws.session_controller != null) return error.UnsupportedSessionMutation;
        return self.splitActivePanePlaced(runtime, callbacks, cfg, cell_width_px, cell_height_px, window_width, window_height, direction, ratio, domain_name, cwd, floating, launch_command, null);
    }

    /// Edge placement reuses the terminal constructor and session ownership path.
    pub fn splitActivePanePlaced(self: *Mux, runtime: *GhosttyRuntime, callbacks: TerminalCallbacks, cfg: Config, cell_width_px: u32, cell_height_px: u32, window_width: u32, window_height: u32, direction: SplitDirection, ratio: f32, domain_name: ?[]const u8, cwd: ?[]const u8, floating: bool, launch_command: ?LaunchCommand, edge: ?types.PaneEdge) !*Pane {
        const tab = self.activeTab() orelse return error.NoActiveTab;
        const source_pane = tab.activePane() orelse return error.NoActivePane;
        if (!floating and source_pane.is_floating) {
            if (!tab.setPaneFloating(source_pane, false)) return error.ActivePaneMissingFromLayout;
        }
        const resolved_domain = domain_name orelse if (source_pane.domainName().len > 0)
            source_pane.domainName()
        else
            cfg.defaultDomainName();
        const same_domain = if (domain_name) |dn|
            std.mem.eql(u8, source_pane.domainName(), dn)
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
        if (edge) |placement| {
            if (floating) return error.FloatingPaneCannotUseEdge;
            const edge_direction: SplitDirection = switch (placement) {
                .left, .right => .vertical,
                .top, .bottom => .horizontal,
            };
            try self.splitEdgeWith(new_pane, edge_direction, ratio, placement == .left or placement == .top);
        } else {
            try self.splitActivePaneWith(new_pane, direction, ratio, floating);
        }
        return new_pane;
    }

    /// Insert any content kind using the same split/floating layout path.
    /// Ownership transfers to the tab only on success.
    pub fn splitActivePaneWith(self: *Mux, new_pane: *Pane, direction: SplitDirection, ratio: f32, floating: bool) !void {
        if (self.activeWorkspace()) |ws| if (ws.session_controller != null) return error.UnsupportedSessionMutation;
        const tab = self.activeTab() orelse return error.NoActiveTab;
        self.focused_dock = null;
        const source_pane = tab.activePane() orelse return error.NoActivePane;
        if (!floating and source_pane.is_floating) {
            if (!tab.setPaneFloating(source_pane, false)) return error.ActivePaneMissingFromLayout;
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
            if (restore_anchor) |anchor| new_pane.restore_anchor_id = anchor.id;
            new_pane.restore_ratio = std.math.clamp(ratio, 0.05, 0.95);
            new_pane.restore_split_horizontal = direction == .horizontal;
            new_pane.restore_place_first = false;
            tab.active_pane = new_pane;
            self.notifyCreated(new_pane);
            return;
        }
        try tab.splitActivePane(new_pane, direction, ratio);
        self.notifyCreated(new_pane);
    }

    /// Insert `new_pane` along a window edge of the active tab's tiled layout.
    pub fn splitEdgeWith(self: *Mux, new_pane: *Pane, direction: SplitDirection, ratio: f32, place_first: bool) !void {
        if (self.activeWorkspace()) |ws| if (ws.session_controller != null) return error.UnsupportedSessionMutation;
        const tab = self.activeTab() orelse return error.NoActiveTab;
        try tab.splitEdge(new_pane, direction, ratio, place_first);
        self.focused_dock = null;
        self.notifyCreated(new_pane);
    }

    /// Resize the active pane by adjusting the ratio of the nearest enclosing
    /// split node along the given axis. `delta` is a fraction in (-1, 1) —
    /// positive means "grow the first child" (i.e. push the divider right/down).
    pub fn resizeActivePane(self: *Mux, direction: SplitDirection, delta: f32) void {
        if (self.focusedDockPane()) |pane| {
            const location = self.paneDock(pane).?;
            if (dock_mod.directionFor(location.edge) != direction) return;
            const node = &self.docksFor(location).slot(location.edge).node;
            node.ratio = std.math.clamp(node.ratio + delta, 0.05, 0.95);
            return;
        }
        const tab = self.activeTab() orelse return;
        const current = tab.activePane() orelse return;
        if (current.is_hidden or current.is_floating) return;
        const root = tab.root_split orelse return;
        if (layout.findSplitContaining(root, current, direction)) |node| {
            node.ratio = std.math.clamp(node.ratio + delta, 0.05, 0.95);
        }
    }

    /// Focus the adjacent pane in the given direction from the currently active pane.
    /// Navigation follows the split tree rather than global pane centers, so nested
    /// layouts move into the sibling subtree of the nearest matching split.
    pub fn focusPaneInDirection(self: *Mux, direction: FocusDirection, window_width: u32, window_height: u32) void {
        const edge = edgeForDirection(direction);
        if (self.focusedDockPane()) |pane| {
            const location = self.paneDock(pane).?;
            // Toward the centre: the inner workspace dock on that side, else the tab.
            if (location.edge == oppositeEdge(edge)) {
                if (location.scope == .global) {
                    if (self.active_workspace) |ws| if (ws.docks.slot(location.edge).pane) |inner| if (!inner.is_hidden) {
                        self.focused_dock = inner;
                        return;
                    };
                }
                self.focused_dock = null;
            } else if (location.scope == .workspace and location.edge == edge) {
                if (self.global_docks.slot(edge).pane) |outer| if (!outer.is_hidden) {
                    self.focused_dock = outer;
                };
            }
            return;
        }
        const tab = self.activeTab() orelse return;
        const current = tab.activePane() orelse return;
        if (current.is_hidden) return;

        var layout_buf: [MAX_LAYOUT_LEAVES]LayoutLeaf = undefined;
        const leaves = tab.computeLayout(window_width, window_height, &layout_buf);
        const target_subtree = (if (leaves.len < 2) null else layout.findFocusTargetSubtree(tab.root_split orelse return, current, direction)) orelse {
            self.focusDockAtEdge(edge);
            return;
        };

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

    /// From the tab region, the workspace dock is nearer than the global one.
    fn focusDockAtEdge(self: *Mux, edge: PaneEdge) void {
        if (self.active_workspace) |ws| if (ws.docks.slot(edge).pane) |pane| if (!pane.is_hidden) {
            self.focused_dock = pane;
            return;
        };
        if (self.global_docks.slot(edge).pane) |pane| if (!pane.is_hidden) {
            self.focused_dock = pane;
        };
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
        if (src.session_controller != null or target.session_controller != null) return false;
        if (target == src) return false;
        const insert_at = if (target.active_tab) |_| target.activeTabIndex() + 1 else target.tabs.items.len;
        target.tabs.ensureUnusedCapacity(self.allocator, 1) catch return false;
        src.detachTab(t);
        target.tabs.insertAssumeCapacity(insert_at, t);
        target.active_tab = t;
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
                    if (p.id == pane_id) {
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
        if (src_ws.session_controller != null or target_ws.session_controller != null) return false;
        if (target_ws == src_ws) return false;
        const insert_at = if (target_ws.active_tab) |_| target_ws.activeTabIndex() + 1 else target_ws.tabs.items.len;
        target_ws.tabs.ensureUnusedCapacity(self.allocator, 1) catch return false;
        const new_tab = self.allocator.create(Tab) catch {
            return false;
        };
        new_tab.* = Tab.init(self.allocator, self.allocId());
        var new_tab_published = false;
        defer if (!new_tab_published) {
            if (new_tab.root_split) |root| {
                root.deinit(self.allocator);
                self.allocator.destroy(root);
            }
            new_tab.panes.deinit(self.allocator);
            self.allocator.destroy(new_tab);
        };
        new_tab.appendPane(p) catch {
            return false;
        };
        src_tab.detachPane(p);
        const tab_empty = src_tab.panes.items.len == 0;
        target_ws.tabs.insertAssumeCapacity(insert_at, new_tab);
        target_ws.active_tab = new_tab;
        new_tab_published = true;
        if (tab_empty) {
            src_ws.detachTab(src_tab);
            src_tab.deinit(runtime);
            self.allocator.destroy(src_tab);
            if (src_ws.tabs.items.len == 0) _ = self.removeWorkspace(runtime, src_ws);
        }
        self.active_workspace = target_ws;
        return true;
    }

    fn edgeForDirection(direction: FocusDirection) PaneEdge {
        return switch (direction) {
            .left => .left,
            .right => .right,
            .up => .top,
            .down => .bottom,
        };
    }

    fn oppositeEdge(edge: PaneEdge) PaneEdge {
        return switch (edge) {
            .left => .right,
            .right => .left,
            .top => .bottom,
            .bottom => .top,
        };
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
        self.closeDeadDockPanes(runtime, &self.global_docks);
        self.closeDeadDockPanes(runtime, &ws.docks);

        var tab_index: usize = 0;
        while (tab_index < ws.tabs.items.len) {
            const tab = ws.tabs.items[tab_index];
            var dead_buf: [64]*Pane = undefined;
            var dead_count: usize = 0;
            for (tab.panes.items) |pane| {
                const term = pane.asTerminal() orelse continue;
                if (!term.retain_on_exit and !term.hasLiveChild() and dead_count < dead_buf.len) {
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
                self.notifyClosing(pane);
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

        for (workspace.tabs.items) |tab| self.notifyTabClosing(tab);
        var docked = workspace.docks.iterator();
        while (docked.next()) |pane| {
            self.notifyClosing(pane);
            if (self.focused_dock == pane) self.focused_dock = null;
        }
        _ = self.workspaces.orderedRemove(remove_idx);
        if (workspace.session_controller != null) self.session_workspace_count -= 1;
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
