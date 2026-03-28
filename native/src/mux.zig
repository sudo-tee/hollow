const std = @import("std");
const Config = @import("config.zig").Config;
const Pane = @import("pane.zig").Pane;
const GhosttyRuntime = @import("term/ghostty.zig").Runtime;

pub const Tab = struct {
    allocator: std.mem.Allocator,
    id: usize,
    panes: std.ArrayList(*Pane),
    active_pane: ?*Pane = null,

    pub fn init(allocator: std.mem.Allocator, id: usize) Tab {
        return .{
            .allocator = allocator,
            .id = id,
            .panes = .empty,
        };
    }

    pub fn deinit(self: *Tab, runtime: *GhosttyRuntime) void {
        for (self.panes.items) |pane| {
            pane.deinit(runtime);
            self.allocator.destroy(pane);
        }
        self.panes.deinit(self.allocator);
        self.* = Tab.init(self.allocator, self.id);
    }

    pub fn appendPane(self: *Tab, pane: *Pane) !void {
        try self.panes.append(self.allocator, pane);
        if (self.active_pane == null) self.active_pane = pane;
    }

    pub fn activePane(self: *Tab) ?*Pane {
        return self.active_pane;
    }
};

pub const Workspace = struct {
    allocator: std.mem.Allocator,
    id: usize,
    tabs: std.ArrayList(*Tab),
    active_tab: ?*Tab = null,

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
};

pub const Mux = struct {
    allocator: std.mem.Allocator,
    workspaces: std.ArrayList(*Workspace),
    active_workspace: ?*Workspace = null,
    next_id: usize = 1,

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

    pub fn activePane(self: *Mux) ?*Pane {
        const tab = self.activeTab() orelse return null;
        return tab.activePane();
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

    fn createPane(self: *Mux, runtime: *GhosttyRuntime, cfg: Config, cell_width_px: u32, cell_height_px: u32, window_width: u32, window_height: u32) !*Pane {
        const pane = try self.allocator.create(Pane);
        pane.* = Pane.init(self.allocator);
        errdefer self.allocator.destroy(pane);
        errdefer pane.deinit(runtime);
        try pane.bootstrap(runtime, cfg, cell_width_px, cell_height_px, window_width, window_height);
        return pane;
    }

    fn allocId(self: *Mux) usize {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }
};
