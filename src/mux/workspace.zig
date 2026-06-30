const std = @import("std");
const Pane = @import("../pane.zig").Pane;
const GhosttyRuntime = @import("../term/ghostty.zig").Runtime;
const types = @import("types.zig");
const tab_mod = @import("tab.zig");

const SplitNode = types.SplitNode;
const Tab = tab_mod.Tab;

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

    pub fn detachTab(self: *Workspace, tab: *Tab) void {
        var idx: usize = 0;
        var found = false;
        for (self.tabs.items, 0..) |t, i| {
            if (t == tab) {
                idx = i;
                found = true;
                break;
            }
        }
        if (!found) return;
        _ = self.tabs.orderedRemove(idx);
        if (self.active_tab == tab) {
            if (self.tabs.items.len == 0) {
                self.active_tab = null;
            } else {
                self.active_tab = self.tabs.items[if (idx >= self.tabs.items.len) self.tabs.items.len - 1 else idx];
            }
        }
    }

    pub fn insertTab(self: *Workspace, tab: *Tab) !void {
        const insert_at = if (self.active_tab) |_| self.activeTabIndex() + 1 else self.tabs.items.len;
        try self.tabs.insert(self.allocator, insert_at, tab);
        self.active_tab = tab;
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

    pub fn title(self: *Workspace) []const u8 {
        if (self.name) |name| return name;
        return "default";
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
