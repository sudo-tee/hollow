const std = @import("std");
const fixture = @import("session_pane_test.zig");
const ghostty = @import("term/ghostty.zig");
const Config = @import("config.zig").Config;
const transport = @import("session/transport.zig");
const Controller = @import("session/controller.zig").Controller;
const Mux = @import("mux/mux.zig").Mux;
const Workspace = @import("mux/workspace.zig").Workspace;
const Pane = @import("pane.zig").Pane;
const a = std.testing.allocator;

const Harness = struct {
    connection: transport.Connection,
    controller: Controller,
    runtime: ghostty.Runtime,
    cfg: Config,
    mux: Mux,
    ws: *Workspace,

    fn init(self: *Harness) !void {
        return self.initAllocated(a);
    }

    fn initAllocated(self: *Harness, allocator: std.mem.Allocator) !void {
        self.connection = try fixture.mockConnection();
        errdefer fixture.freeMock(&self.connection);
        self.controller = Controller.init(a, &self.connection);
        errdefer self.controller.deinit();
        self.controller.session_id = try a.dupe(u8, "mock");
        self.controller.generation = self.connection.client.generation;
        self.runtime = try ghostty.Runtime.init(a, null);
        errdefer self.runtime.deinit();
        self.cfg = Config.init(a);
        errdefer self.cfg.deinit();
        self.cfg.shell = try a.dupe(u8, "/must-never-spawn");
        self.mux = Mux.init(allocator);
        errdefer self.mux.deinit(&self.runtime);
        self.ws = try self.mux.addSessionWorkspace(&self.runtime, fixture.callbacks(), self.cfg, &self.controller, .{
            .id = "mock",
            .attached = true,
            .revision = 0,
            .panes = &.{.{ .id = 1, .cols = 80, .rows = 24 }},
        }, null, null);
    }

    fn deinit(self: *Harness) void {
        self.mux.deinit(&self.runtime);
        self.cfg.deinit();
        self.runtime.deinit();
        self.controller.deinit();
        fixture.freeMock(&self.connection);
    }

    fn add(self: *Harness, id: u32, placement: Mux.SessionPlacement) !*Pane {
        return self.mux.addSessionPane(&self.runtime, fixture.callbacks(), self.cfg, &self.controller, self.ws.id, .{
            .id = id,
            .cols = 101,
            .rows = 37,
            .cwd = "/owner/cwd",
        }, "persistent", null, placement);
    }

    fn makeFloatingOnly(self: *Harness) void {
        const tab = self.ws.active_tab.?;
        const root = tab.root_split.?;
        root.deinit(tab.allocator);
        tab.allocator.destroy(root);
        tab.root_split = null;
        const source = tab.active_pane.?;
        source.is_floating = true;
        source.floating_x = 0.23;
        source.floating_width = 0.6;
    }
};

test "session pane spawn mux new tab binds live view without local spawn" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const first = h.ws.active_tab.?;
    const pane = try h.add(2, .{ .tab = .{ .after_tab_id = first.id } });
    try std.testing.expectEqual(@as(usize, 2), h.ws.tabs.items.len);
    try std.testing.expectEqual(pane, h.mux.activePane().?);
    try std.testing.expectEqual(@as(u32, 101), pane.cols);
    try std.testing.expectEqual(@as(u32, 37), pane.rows);
    try std.testing.expectEqualStrings("persistent", pane.domainName());
    try std.testing.expectEqualStrings("/owner/cwd", pane.cwd);
    const term = &pane.content.terminal;
    try std.testing.expect(term.terminal_output_ready and term.session_view != null);
    try std.testing.expectEqual(@as(usize, 0), term.childPid());
    try std.testing.expectEqual(@as(u32, 2), term.pty.?.session.pane);
    try std.testing.expect(h.connection.client.nextWrite() == null);
}

test "session pane spawn mux captured tab insertion preserves switched tab and workspace" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const first = h.ws.active_tab.?;
    _ = try h.add(2, .{ .tab = .{ .after_tab_id = first.id } });
    const second = h.ws.active_tab.?;
    const active = second.active_pane;
    const first_active = first.active_pane;
    _ = try h.add(6, .{ .split = .{ .tab_id = first.id, .source_id = first_active.?.id, .direction = .vertical, .ratio = 0.5 } });
    try std.testing.expectEqual(first_active, first.active_pane);
    try std.testing.expectEqual(second, h.ws.active_tab.?);
    _ = try h.add(3, .{ .tab = .{ .after_tab_id = first.id } });
    try std.testing.expectEqual(second, h.ws.active_tab.?);
    try std.testing.expectEqual(active, h.mux.activePane());
    try std.testing.expectEqual(second, h.ws.tabs.items[2]);
    _ = try h.add(4, .{ .tab = .{ .after_tab_id = first.id, .insert_at_end = true } });
    try std.testing.expectEqual(@as(u32, 4), h.ws.tabs.items[3].active_pane.?.content.terminal.pty.?.session.pane);
    // A separate empty workspace models switching away while RPC is pending.
    const other = try a.create(Workspace);
    other.* = Workspace.init(a, 9999);
    h.mux.workspaces.append(a, other) catch |err| {
        a.destroy(other);
        return err;
    };
    h.mux.active_workspace = other;
    _ = try h.add(5, .{ .tab = .{ .after_tab_id = second.id } });
    try std.testing.expectEqual(other, h.mux.active_workspace.?);
    try std.testing.expectEqual(second, h.ws.active_tab.?);
}

test "session pane spawn mux split floating bounds fullscreen and captured focus" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const tab = h.ws.active_tab.?;
    const source = tab.active_pane.?;
    const split = try h.add(2, .{ .split = .{ .tab_id = tab.id, .source_id = source.id, .direction = .horizontal, .ratio = 0.3 } });
    try std.testing.expectEqual(split, tab.active_pane.?);
    try std.testing.expectEqual(source.id, split.restore_anchor_id);
    const floating = try h.add(3, .{ .split = .{
        .tab_id = tab.id,
        .source_id = source.id,
        .direction = .vertical,
        .ratio = 0.4,
        .floating = true,
        .x = 0.99,
        .y = -0.5,
        .width = 0.1,
        .height = 2,
        .fullscreen = true,
    } });
    try std.testing.expect(floating.is_floating);
    try std.testing.expectEqual(@as(f32, 0.8), floating.floating_x);
    try std.testing.expectEqual(@as(f32, 0), floating.floating_y);
    try std.testing.expectEqual(@as(f32, 0.2), floating.floating_width);
    try std.testing.expectEqual(@as(f32, 1), floating.floating_height);
    try std.testing.expectEqual(split, tab.active_pane.?);
    try std.testing.expect(tab.maximized_pane == null);
    // A tiled spawn from a floating source reinserts that source atomically.
    tab.active_pane = floating;
    const tiled = try h.add(4, .{ .split = .{ .tab_id = tab.id, .source_id = floating.id, .direction = .vertical, .ratio = 0.5, .fullscreen = true } });
    try std.testing.expect(!floating.is_floating);
    try std.testing.expectEqual(tiled, tab.active_pane.?);
    try std.testing.expectEqual(tiled, tab.maximized_pane.?);
}

test "session pane spawn mux missing split target falls back in same workspace" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const tab = h.ws.active_tab.?;
    const active = tab.active_pane;
    const missing_source = try h.add(2, .{ .split = .{ .tab_id = tab.id, .source_id = 99999, .direction = .vertical, .ratio = 0.5 } });
    const missing_tab = try h.add(3, .{ .split = .{ .tab_id = 99999, .source_id = active.?.id, .direction = .horizontal, .ratio = 0.5 } });
    try std.testing.expectEqual(@as(usize, 3), h.ws.tabs.items.len);
    try std.testing.expectEqual(missing_source, h.ws.tabs.items[1].active_pane.?);
    try std.testing.expectEqual(missing_tab, h.ws.tabs.items[2].active_pane.?);
    try std.testing.expectEqual(tab, h.ws.active_tab.?);
    try std.testing.expectEqual(active, h.mux.activePane());
}

test "session pane spawn mux floating-only tab builds tiled split transactionally" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.makeFloatingOnly();
    const tab = h.ws.active_tab.?;
    const source = tab.active_pane.?;
    const pane = try h.add(2, .{ .split = .{ .tab_id = tab.id, .source_id = source.id, .direction = .horizontal, .ratio = 0.4 } });
    try std.testing.expectEqual(@as(usize, 1), h.ws.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 2), tab.panes.items.len);
    try std.testing.expect(!source.is_floating and !pane.is_floating);
    const root = tab.root_split.?;
    try std.testing.expectEqual(source, root.first.?.pane.?);
    try std.testing.expectEqual(pane, root.second.?.pane.?);
    try std.testing.expectEqual(@as(f32, 0.6), root.ratio);
    try std.testing.expectEqual(pane, h.mux.activePane().?);
    try std.testing.expect(pane.content.terminal.session_view != null);
}

test "session pane spawn mux duplicate binding rolls back and tab limit rejects mutation" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const tab = h.ws.active_tab.?;
    const source = tab.active_pane.?;
    try std.testing.expectError(error.DuplicatePane, h.add(1, .{ .tab = .{} }));
    try std.testing.expectError(error.DuplicatePane, h.add(1, .{ .split = .{ .tab_id = tab.id, .source_id = source.id, .direction = .horizontal, .ratio = 0.5 } }));
    try std.testing.expectEqual(@as(usize, 1), h.ws.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), tab.panes.items.len);
    for (2..65) |id| _ = try h.add(@intCast(id), .{ .split = .{ .tab_id = tab.id, .source_id = source.id, .direction = .vertical, .ratio = 0.5, .floating = true } });
    try std.testing.expectError(error.ResourceExhausted, h.add(65, .{ .split = .{ .tab_id = tab.id, .source_id = source.id, .direction = .vertical, .ratio = 0.5 } }));
    try std.testing.expectEqual(@as(usize, 64), tab.panes.items.len);
    _ = try h.add(65, .{ .tab = .{} });
}

test "session pane spawn mux owner bound and controller identity reject before publication" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try std.testing.expect(!h.ws.session_close_desired);
    var other = Controller.init(a, &h.connection);
    defer other.deinit();
    try std.testing.expectError(error.WrongSession, h.mux.addSessionPane(&h.runtime, fixture.callbacks(), h.cfg, &other, h.ws.id, .{ .id = 2, .cols = 80, .rows = 24 }, null, null, .{ .tab = .{} }));
    const tab = h.ws.active_tab.?;
    const source = tab.active_pane.?;
    try std.testing.expectError(error.UnsupportedSessionMutation, h.mux.splitActivePaneWith(source, .vertical, 0.5, false));
    // Repeated binding metadata models owner-count saturation (including
    // global docks) without allocating 1024 VT instances. Restore it before
    // teardown so the real view is unbound only once.
    const bindings = h.controller.bindings;
    defer h.controller.bindings = bindings;
    for (&h.controller.bindings) |*slot| slot.* = bindings[0];
    try std.testing.expectError(error.ResourceExhausted, h.add(2, .{ .tab = .{} }));
    try std.testing.expectEqual(@as(usize, 1), tab.panes.items.len);
    try std.testing.expectEqual(source, tab.active_pane.?);
}

fn reclaimAllocationCase(allocator: std.mem.Allocator) !void {
    var connection = try fixture.mockConnection();
    defer fixture.freeMock(&connection);
    var controller = Controller.init(a, &connection);
    defer controller.deinit();
    controller.session_id = try a.dupe(u8, "mock");
    controller.generation = connection.client.generation;
    var h: Harness = undefined;
    try h.initAllocated(allocator);
    defer h.deinit();
    const workspace_id = h.ws.id;
    const original = h.mux.activePane().?;
    const global = try h.add(2, .{ .dock = .{ .edge = .bottom, .scope = .global, .ratio = 0.25 } });
    h.controller.detached = true;
    h.controller.taken = true;
    const bytes = try @import("mux/session_layout.zig").capture(a, h.ws, &h.mux.global_docks);
    defer a.free(bytes);
    const info: transport.p.SessionInfo = .{
        .id = "mock",
        .attached = true,
        .revision = 4,
        .layout = bytes,
        .panes = &.{ .{ .id = 1, .cols = 80, .rows = 24 }, .{ .id = 2, .cols = 80, .rows = 24 }, .{ .id = 3, .cols = 80, .rows = 24 } },
    };
    const restored = h.mux.replaceSessionWorkspace(&h.runtime, fixture.callbacks(), h.cfg, &controller, info, "persistent", null, workspace_id) catch |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
        try std.testing.expectEqual(h.ws, h.mux.workspaceById(workspace_id).?);
        try std.testing.expectEqual(@as(usize, 1), h.mux.workspaces.items.len);
        try std.testing.expectEqual(global, h.mux.dockOccupant(.global, .bottom).?);
        try std.testing.expectEqual(global, h.mux.activePane().?);
        try std.testing.expectEqual(@as(f32, 0.25), h.mux.global_docks.size(.bottom));
        try std.testing.expectEqual(original, h.ws.active_tab.?.active_pane.?);
        try std.testing.expect(h.controller.hasBindings());
        try std.testing.expect(!controller.hasBindings());
        return err;
    };
    try std.testing.expectEqual(workspace_id, restored.id);
    try std.testing.expectEqual(@as(usize, 1), h.mux.workspaces.items.len);
    try std.testing.expectEqual(@as(usize, 1), h.mux.session_workspace_count);
    try std.testing.expectEqual(@as(usize, 2), restored.tabs.items.len); // New owner pane was reconciled.
    try std.testing.expect(!h.controller.hasBindings());
    try std.testing.expectEqual(@as(u32, 2), h.mux.dockOccupant(.global, .bottom).?.content.terminal.pty.?.session.pane);
    try std.testing.expect(h.mux.activePane().? != global);
}

test "session pane reclaim atomically replaces frozen tabs and owned global docks under allocation failure" {
    try std.testing.checkAllAllocationFailures(a, reclaimAllocationCase, .{});
}

fn allocationCase(allocator: std.mem.Allocator, mode: u8) !void {
    var h: Harness = undefined;
    try h.initAllocated(allocator);
    defer h.deinit();
    const tab = h.ws.active_tab.?;
    if (mode == 4) h.makeFloatingOnly();
    const source = if (mode == 3)
        try h.add(2, .{ .split = .{ .tab_id = tab.id, .source_id = tab.active_pane.?.id, .direction = .vertical, .ratio = 0.5, .floating = true } })
    else
        tab.active_pane.?;
    const initial_panes = tab.panes.items.len;
    const original_root = if (tab.root_split) |root| root.* else null;
    const original_x = source.floating_x;
    const original_width = source.floating_width;
    const placement: Mux.SessionPlacement = if (mode == 0) .{ .tab = .{ .after_tab_id = tab.id } } else .{ .split = .{
        .tab_id = tab.id,
        .source_id = source.id,
        .direction = .vertical,
        .ratio = 0.5,
        .floating = mode == 2,
    } };
    _ = h.add(3, placement) catch |err| {
        try std.testing.expectEqual(source, h.mux.activePane().?);
        try std.testing.expectEqual(initial_panes, tab.panes.items.len);
        try std.testing.expectEqual(@as(usize, 1), h.ws.tabs.items.len);
        var bindings: usize = 0;
        for (h.controller.bindings) |binding| if (binding != null) {
            bindings += 1;
        };
        try std.testing.expectEqual(initial_panes, bindings);
        if (original_root) |root| {
            try std.testing.expectEqual(root.kind, tab.root_split.?.kind);
            try std.testing.expectEqual(root.first, tab.root_split.?.first);
            try std.testing.expectEqual(root.second, tab.root_split.?.second);
        } else try std.testing.expect(tab.root_split == null);
        if (mode >= 3) try std.testing.expect(source.is_floating);
        try std.testing.expectEqual(original_x, source.floating_x);
        try std.testing.expectEqual(original_width, source.floating_width);
        return err;
    };
}

test "session pane spawn mux allocation failures leave layout focus and bindings intact" {
    for (0..5) |mode| try std.testing.checkAllAllocationFailures(a, allocationCase, .{@as(u8, @intCast(mode))});
}
