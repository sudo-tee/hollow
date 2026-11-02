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
const ghostty = @import("../term/ghostty.zig");

const LifecycleTestCallbacks = struct {
    fn write(_: ?*anyopaque, _: ?*anyopaque, _: [*]const u8, _: usize) callconv(.c) void {}
    fn notify(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {}
    fn string(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) ghostty.String {
        return .{ .ptr = null, .len = 0 };
    }
    fn size(_: ?*anyopaque, _: ?*anyopaque, _: *ghostty.SizeReportSize) callconv(.c) bool {
        return false;
    }
    fn color(_: ?*anyopaque, _: ?*anyopaque, _: *ghostty.ColorScheme) callconv(.c) bool {
        return false;
    }
    fn attributes(_: ?*anyopaque, _: ?*anyopaque, _: *ghostty.DeviceAttributes) callconv(.c) bool {
        return false;
    }
    const callbacks: ghostty.TerminalCallbacks = .{
        .write_pty = write,
        .bell = notify,
        .enquiry = string,
        .xtversion = string,
        .size = size,
        .color_scheme = color,
        .device_attributes = attributes,
        .title_changed = notify,
    };
};

const PaneLifecycleRecorder = struct {
    mux: *Mux,
    created: usize = 0,
    closed: usize = 0,
    all_panes_resolved: bool = true,
    last_created_id: usize = 0,

    fn recordCreated(context: *anyopaque, pane: *Pane) void {
        const self: *PaneLifecycleRecorder = @ptrCast(@alignCast(context));
        self.created += 1;
        if (pane.id == 0 or pane.id <= self.last_created_id) self.all_panes_resolved = false;
        self.last_created_id = pane.id;
        self.checkPublished(pane);
    }

    fn recordClosing(context: *anyopaque, pane: *Pane) void {
        const self: *PaneLifecycleRecorder = @ptrCast(@alignCast(context));
        self.closed += 1;
        self.checkPublished(pane);
    }

    fn checkPublished(self: *PaneLifecycleRecorder, pane: *Pane) void {
        var panes = self.mux.paneIterator();
        var found = false;
        while (panes.next()) |candidate| {
            if (candidate == pane) {
                found = true;
            } else if (candidate.id == pane.id) {
                self.all_panes_resolved = false;
            }
        }
        if (!found) self.all_panes_resolved = false;
    }
};

test "pane lifecycle callbacks cover creation closure and moves without duplicates" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var runtime = try ghostty.Runtime.init(allocator, null);
    defer runtime.deinit();
    var cfg = @import("../config.zig").Config.init(allocator);
    defer cfg.deinit();
    cfg.shell = try allocator.dupe(u8, "/bin/sh");
    var mux = Mux.init(allocator);
    defer mux.deinit(&runtime);
    var recorder: PaneLifecycleRecorder = .{ .mux = &mux };
    mux.host_context = &recorder;
    mux.pane_created = PaneLifecycleRecorder.recordCreated;
    mux.pane_closing = PaneLifecycleRecorder.recordClosing;
    const callbacks = LifecycleTestCallbacks.callbacks;

    try std.testing.expectError(error.NoActiveWorkspace, mux.newTab(&runtime, callbacks, cfg, 8, 16, 800, 600, null, null, null, false));
    try std.testing.expectEqual(@as(usize, 0), recorder.created);
    try mux.bootstrapSingle(&runtime, callbacks, cfg, 8, 16, 800, 600);
    try std.testing.expectError(error.MuxAlreadyBootstrapped, mux.bootstrapSingle(&runtime, callbacks, cfg, 8, 16, 800, 600));
    const first = mux.activePane().?;
    try mux.newTab(&runtime, callbacks, cfg, 8, 16, 800, 600, null, null, null, false);
    _ = try mux.splitActivePane(&runtime, callbacks, cfg, 8, 16, 800, 600, .vertical, 0.5, null, null, false, null);
    _ = try mux.splitActivePane(&runtime, callbacks, cfg, 8, 16, 800, 600, .horizontal, 0.5, null, null, true, null);
    try mux.newWorkspace(&runtime, callbacks, cfg, 8, 16, 800, 600, null, null, null, null);
    try std.testing.expectEqual(@as(usize, 5), recorder.created);
    try std.testing.expectEqual(@as(usize, 0), recorder.closed);

    try std.testing.expect(mux.movePaneToWorkspace(&runtime, first.id, 1));
    try std.testing.expectEqual(@as(usize, 5), recorder.created);
    try std.testing.expectEqual(@as(usize, 0), recorder.closed);
    _ = mux.closePaneById(&runtime, first.id);
    try std.testing.expectEqual(@as(usize, 1), recorder.closed);
    _ = mux.closeTabAt(&runtime, 0);
    try std.testing.expectEqual(@as(usize, 2), recorder.closed);
    _ = mux.closeActivePane(&runtime);
    try std.testing.expectEqual(@as(usize, 3), recorder.closed);
    try std.testing.expect(mux.closeTab(&runtime));
    try std.testing.expectEqual(@as(usize, 5), recorder.closed);

    try mux.newWorkspace(&runtime, callbacks, cfg, 8, 16, 800, 600, null, null, null, null);
    _ = try mux.splitActivePane(&runtime, callbacks, cfg, 8, 16, 800, 600, .vertical, 0.5, null, null, false, null);
    try std.testing.expect(mux.closeWorkspace(&runtime, null));
    try std.testing.expectEqual(@as(usize, 7), recorder.created);
    try std.testing.expectEqual(@as(usize, 7), recorder.closed);
    _ = mux.closePaneById(&runtime, 0);
    try std.testing.expectEqual(@as(usize, 7), recorder.closed);
    try std.testing.expect(recorder.all_panes_resolved);
}

test "pane IDs survive moves and floating restore and are never reused after close" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var runtime = try ghostty.Runtime.init(allocator, null);
    defer runtime.deinit();
    var cfg = @import("../config.zig").Config.init(allocator);
    defer cfg.deinit();
    cfg.shell = try allocator.dupe(u8, "/bin/sh");
    var mux = Mux.init(allocator);
    defer mux.deinit(&runtime);
    const callbacks = LifecycleTestCallbacks.callbacks;

    try mux.bootstrapSingle(&runtime, callbacks, cfg, 8, 16, 800, 600);
    const first = mux.activePane().?;
    const first_id = first.id;
    try std.testing.expect(first_id != 0);
    // Input-resource transfer during bootstrap must retain the borrowed runtime
    // used by parser callbacks after construction returns.
    try std.testing.expectEqual(&runtime, first.term.terminal_runtime.?);
    try std.testing.expectEqual(@as(usize, 1), mux.activeWorkspace().?.id);
    try std.testing.expectEqual(@as(usize, 2), mux.activeTab().?.id);
    const second = try mux.splitActivePane(&runtime, callbacks, cfg, 8, 16, 800, 600, .vertical, 0.4, null, null, false, null);
    const closed_id = second.id;
    try std.testing.expectEqual(&runtime, second.term.terminal_runtime.?);
    try std.testing.expect(closed_id > first_id);
    try std.testing.expectEqual(first_id, second.restore_anchor_id);
    try std.testing.expect(mux.setPaneFloating(second, true));
    try std.testing.expect(mux.setPaneFloating(second, false));
    try std.testing.expectEqual(closed_id, second.id);
    try std.testing.expectEqual(first_id, second.restore_anchor_id);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), mux.paneSplitInfo(second).?.size, 1e-6);
    _ = mux.closePaneById(&runtime, closed_id);
    try std.testing.expect(!mux.focusPaneById(closed_id));

    const replacement = try mux.splitActivePane(&runtime, callbacks, cfg, 8, 16, 800, 600, .vertical, 0.5, null, null, false, null);
    const replacement_id = replacement.id;
    try std.testing.expect(replacement_id > closed_id);
    try std.testing.expect(!mux.focusPaneById(closed_id));
    try std.testing.expect(!mux.focusPaneById(0));
    try mux.newWorkspace(&runtime, callbacks, cfg, 8, 16, 800, 600, null, null, null, null);
    try std.testing.expectEqual(@as(usize, 3), mux.activeWorkspace().?.id);
    try std.testing.expect(mux.movePaneToWorkspace(&runtime, replacement_id, 1));
    try std.testing.expectEqual(replacement_id, replacement.id);
    try std.testing.expect(mux.focusPaneById(first_id));
    try std.testing.expectEqual(first, mux.activePane().?);
    try std.testing.expect(mux.focusPaneById(replacement_id));
    try std.testing.expectEqual(replacement, mux.activePane().?);
}

test "new tabs inherit the active pane domain and cwd unless explicitly overridden" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var runtime = try ghostty.Runtime.init(allocator, null);
    defer runtime.deinit();
    var cfg = @import("../config.zig").Config.init(allocator);
    defer cfg.deinit();
    try cfg.setDomainShell("default", "/bin/sh");
    try cfg.setDomainShell("container", "/bin/sh");
    try cfg.setDefaultDomain("default");
    try cfg.setDomainDefaultCwd("default", "/");
    var mux = Mux.init(allocator);
    defer mux.deinit(&runtime);
    const callbacks = LifecycleTestCallbacks.callbacks;

    try mux.newWorkspace(&runtime, callbacks, cfg, 8, 16, 800, 600, "/tmp", "container", null, null);
    try mux.newTab(&runtime, callbacks, cfg, 8, 16, 800, 600, null, null, null, false);
    try std.testing.expectEqualStrings("container", mux.activePane().?.term.domain_name);
    try std.testing.expectEqualStrings("/tmp", mux.activePane().?.cwd);

    try mux.newTab(&runtime, callbacks, cfg, 8, 16, 800, 600, "/var", null, null, false);
    try std.testing.expectEqualStrings("container", mux.activePane().?.term.domain_name);
    try std.testing.expectEqualStrings("/var", mux.activePane().?.cwd);

    try mux.newTab(&runtime, callbacks, cfg, 8, 16, 800, 600, null, "default", null, false);
    try std.testing.expectEqualStrings("default", mux.activePane().?.term.domain_name);
    try std.testing.expectEqualStrings("/", mux.activePane().?.cwd);
}

test "spawn filters reach initial panes tabs workspaces and splits before PTY launch" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = @import("../io.zig");
    const allocator = std.testing.allocator;
    var runtime = try ghostty.Runtime.init(allocator, null);
    defer runtime.deinit();
    var cfg = @import("../config.zig").Config.init(allocator);
    defer cfg.deinit();
    cfg.shell = try allocator.dupe(u8, "/bin/sh");
    var lua = try @import("../lua_bridge.zig").Runtime.init(allocator, &cfg);
    defer lua.deinit();
    try lua.runString(
        \\hollow = {events = {}}
        \\local state = {events = {handles = {}, listeners = {}, next_handle = 1, builtin_names = {}},
        \\  host_api = {now_ms = function() return 1 end}}
        \\require('hollow.events').setup(hollow, state, {})
        \\spawn_count = 0
        \\hollow.events.filter('term:spawn', function(spec)
        \\  spawn_count = spawn_count + 1
        \\  assert(spec.env.HOLLOW_PANE_ID == tostring(spawn_count))
        \\  spec.cwd = '/'
        \\  spec.env.FILTER_VALUE = 'filtered'
        \\  return spec
        \\end)
    );
    const Bridge = struct {
        fn filter(context: *anyopaque, arena: std.mem.Allocator, spec: *@import("../pty/spawn_spec.zig").SpawnSpec) !void {
            const bridge: *@import("../lua_bridge.zig").Runtime = @ptrCast(@alignCast(context));
            try bridge.filterSpawn(arena, spec);
        }
    };
    var mux = Mux.init(allocator);
    defer mux.deinit(&runtime);
    mux.spawn_filter = .{ .context = &lua, .callback = Bridge.filter };
    const callbacks = LifecycleTestCallbacks.callbacks;
    try mux.bootstrapSingle(&runtime, callbacks, cfg, 8, 16, 800, 600);
    try std.testing.expectEqualStrings("/", mux.activePane().?.cwd);
    try mux.newTab(&runtime, callbacks, cfg, 8, 16, 800, 600, null, null, .{
        .command = "printf 'filter:%s:%s:%s' \"$PWD\" \"$FILTER_VALUE\" \"$HOLLOW_PANE_ID\"",
    }, false);
    const pane = mux.activePane().?;
    const deadline = io.nanoTimestamp() + 5 * std.time.ns_per_s;
    var expected_buf: [64]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf, "filter:/:filtered:{d}", .{pane.id});
    while (std.mem.indexOf(u8, pane.term.boot_output.items, expected) == null) {
        if (io.nanoTimestamp() >= deadline) return error.TestUnexpectedResult;
        _ = try pane.pollPty(&runtime, 8, 64 * 1024, 10 * std.time.ns_per_ms, 4096, false);
        try std.Io.sleep(io.get(), .fromMilliseconds(5), .awake);
    }
    _ = try mux.splitActivePane(&runtime, callbacks, cfg, 8, 16, 800, 600, .vertical, 0.5, null, null, false, null);
    _ = try mux.splitActivePane(&runtime, callbacks, cfg, 8, 16, 800, 600, .horizontal, 0.5, null, null, true, null);
    try mux.newWorkspace(&runtime, callbacks, cfg, 8, 16, 800, 600, null, null, null, null);
    try lua.runString("assert(spawn_count == 5)");
}

test "pane lifecycle closing callback covers automatic dead pane cleanup" {
    const allocator = std.testing.allocator;
    var runtime = try @import("../term/ghostty.zig").Runtime.init(allocator, null);
    defer runtime.deinit();
    var mux = Mux.init(allocator);
    defer mux.deinit(&runtime);
    var recorder: PaneLifecycleRecorder = .{ .mux = &mux };
    mux.host_context = &recorder;
    mux.pane_closing = PaneLifecycleRecorder.recordClosing;
    const workspace = try allocator.create(Workspace);
    workspace.* = Workspace.init(allocator, 1);
    try mux.workspaces.append(allocator, workspace);
    mux.active_workspace = workspace;
    const tab = try workspace.newTab(2, false);
    const pane = try allocator.create(Pane);
    pane.* = Pane.init(allocator);
    pane.id = 3;
    try tab.appendPane(pane);
    try std.testing.expect(mux.closeDeadPanes(&runtime));
    try std.testing.expectEqual(@as(usize, 1), recorder.closed);
    try std.testing.expect(recorder.all_panes_resolved);
    try std.testing.expect(mux.closeDeadPanes(&runtime));
    try std.testing.expectEqual(@as(usize, 1), recorder.closed);
}

test "Lua pane allocation has no terminal resources and rolls back on allocation failure" {
    const Check = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var mux = Mux.init(allocator);
            // Deliberately unusable: allocating/freeing Lua panes must not call
            // any Ghostty function, including null-handle cleanup wrappers.
            var runtime: ghostty.Runtime = undefined;
            const pane = try mux.createLuaPane();
            defer allocator.destroy(pane);
            defer pane.deinit(&runtime);
            try std.testing.expect(!pane.isTerminal());
            try std.testing.expect(pane.id != 0);
            try std.testing.expect(pane.term.pty == null and pane.term.terminal == null);
            try std.testing.expect(pane.term.key_encoder == null and pane.term.mouse_encoder == null);
            try std.testing.expect(!pane.hasRenderHelpers());
            try std.testing.expectEqual(@as(usize, 0), pane.term.domain_name.len);
            try std.testing.expect(pane.lua_surface.?.dirty);
            try std.testing.expectError(error.NotATerminal, pane.queueStartupInput("input"));
            try std.testing.expectError(error.NoActiveTab, mux.splitActivePaneWith(pane, .vertical, 0.5, false));
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

test "mixed Lua and terminal panes split float zoom move and close without reaping Lua panes" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var runtime = try ghostty.Runtime.init(allocator, null);
    defer runtime.deinit();
    var cfg = @import("../config.zig").Config.init(allocator);
    defer cfg.deinit();
    cfg.shell = try allocator.dupe(u8, "/bin/sh");
    var mux = Mux.init(allocator);
    defer mux.deinit(&runtime);
    var recorder: PaneLifecycleRecorder = .{ .mux = &mux };
    mux.host_context = &recorder;
    mux.pane_created = PaneLifecycleRecorder.recordCreated;
    mux.pane_closing = PaneLifecycleRecorder.recordClosing;
    const callbacks = LifecycleTestCallbacks.callbacks;
    try mux.bootstrapSingle(&runtime, callbacks, cfg, 8, 16, 800, 600);
    const terminal = mux.activePane().?;
    terminal.term.retain_on_exit = true;
    const pane = try mux.createLuaPane();
    try mux.splitActivePaneWith(pane, .vertical, 0.4, false);
    const id = pane.id;
    try std.testing.expectEqual(@as(usize, 2), recorder.created);
    try std.testing.expectEqual(pane, mux.activePane().?);
    try std.testing.expect(!pane.term.retain_on_exit);
    try std.testing.expect(!mux.closeDeadPanes(&runtime));
    try std.testing.expect(mux.focusPaneById(id));
    try std.testing.expect(mux.setPaneFloating(pane, true));
    try std.testing.expect(mux.setPaneFloating(pane, false));
    _ = mux.activeTab().?.setPaneMaximized(pane, true, false);
    try std.testing.expect(mux.paneIsMaximized(pane));
    _ = mux.activeTab().?.setPaneMaximized(pane, false, false);
    try std.testing.expect(!mux.paneIsMaximized(pane));
    const floating = try mux.createLuaPane();
    try mux.splitActivePaneWith(floating, .horizontal, 0.3, true);
    try std.testing.expect(floating.is_floating);
    try mux.newWorkspace(&runtime, callbacks, cfg, 8, 16, 800, 600, null, null, null, null);
    try std.testing.expect(mux.movePaneToWorkspace(&runtime, id, 1));
    try std.testing.expect(mux.focusPaneById(id));
    try std.testing.expectEqual(pane, mux.activePane().?);
    _ = mux.closePaneById(&runtime, id);
    try std.testing.expect(!mux.focusPaneById(id));
    try std.testing.expectEqual(@as(usize, 1), recorder.closed);
    try std.testing.expect(recorder.all_panes_resolved);
}

test "workspace new tab can append after active tab" {
    const allocator = std.testing.allocator;
    var workspace = Workspace.init(allocator, 1);
    defer workspace.tabs.deinit(allocator);

    const first = try allocator.create(Tab);
    defer allocator.destroy(first);
    first.* = Tab.init(allocator, 2);

    const second = try allocator.create(Tab);
    defer allocator.destroy(second);
    second.* = Tab.init(allocator, 3);

    try workspace.appendTab(first);
    try workspace.appendTab(second);
    workspace.active_tab = first;

    const appended = try workspace.newTab(4, true);
    defer allocator.destroy(appended);

    try std.testing.expect(workspace.tabs.items[0] == first);
    try std.testing.expect(workspace.tabs.items[1] == second);
    try std.testing.expect(workspace.tabs.items[2] == appended);
    try std.testing.expect(workspace.active_tab == appended);
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
    top.id = 3;
    try tab.appendPane(top);

    const bottom_left = try allocator.create(Pane);
    bottom_left.* = Pane.init(allocator);
    bottom_left.id = 4;
    try tab.splitActivePane(bottom_left, .horizontal, 0.3);

    tab.active_pane = bottom_left;

    const bottom_right = try allocator.create(Pane);
    bottom_right.* = Pane.init(allocator);
    bottom_right.id = 5;
    try tab.splitActivePane(bottom_right, .vertical, 0.6);

    const bottom_left_info = tab.splitInfoForPane(bottom_left).?;
    try std.testing.expectEqual(types.SplitDirection.horizontal, bottom_left_info.direction);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), bottom_left_info.size, 1e-6);
    const bottom_right_info = tab.splitInfoForPane(bottom_right).?;
    try std.testing.expectEqual(types.SplitDirection.vertical, bottom_right_info.direction);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), bottom_right_info.size, 1e-6);

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
    first.id = 2;
    try tab.appendPane(first);

    const second = try allocator.create(Pane);
    second.* = Pane.init(allocator);
    second.id = 3;
    try tab.splitActivePane(second, .vertical, 0.3);

    const split_info = tab.splitInfoForPane(second).?;
    try std.testing.expectEqual(types.SplitDirection.vertical, split_info.direction);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), split_info.size, 1e-6);

    var layout_buf: [MAX_LAYOUT_LEAVES]LayoutLeaf = undefined;
    const bounds = PaneBounds{ .x = 0, .y = 0, .width = 1000, .height = 100 };
    const leaves = tab.computeLayoutInBounds(bounds, &layout_buf, 0, 0);

    try std.testing.expectEqual(@as(usize, 2), leaves.len);
    // The ratio applies to the 999 pixels remaining after the divider.
    try std.testing.expectEqual(@as(u32, 300), leaves[1].bounds.width);
    try std.testing.expectEqual(@as(u32, 699), leaves[0].bounds.width);
    try std.testing.expectEqual(leaves[0].bounds.x + leaves[0].bounds.width + 1, leaves[1].bounds.x);
    try std.testing.expectEqual(bounds.x + bounds.width, leaves[1].bounds.x + leaves[1].bounds.width);
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
    first.id = 2;
    try tab.appendPane(first);

    const second = try allocator.create(Pane);
    second.* = Pane.init(allocator);
    second.id = 3;
    const split_size = @as(f32, 16.0 / 34.0);
    try tab.splitActivePane(second, .horizontal, split_size);

    const split_info = tab.splitInfoForPane(second).?;
    try std.testing.expectEqual(types.SplitDirection.horizontal, split_info.direction);
    try std.testing.expectApproxEqAbs(split_size, split_info.size, 1e-6);

    var layout_buf: [MAX_LAYOUT_LEAVES]LayoutLeaf = undefined;
    const bounds = PaneBounds{ .x = 0, .y = 0, .width = 1000, .height = 34 * 20 + 1 };
    const leaves = tab.computeLayoutInBounds(bounds, &layout_buf, 10, 20);

    try std.testing.expectEqual(@as(usize, 2), leaves.len);
    try std.testing.expectEqual(@as(u32, 18 * 20), leaves[0].bounds.height);
    // The extra pixel belongs to the divider, not the second pane.
    try std.testing.expectEqual(@as(u32, 16 * 20), leaves[1].bounds.height);
    try std.testing.expectEqual(leaves[0].bounds.y + leaves[0].bounds.height + 1, leaves[1].bounds.y);
    try std.testing.expectEqual(bounds.y + bounds.height, leaves[1].bounds.y + leaves[1].bounds.height);
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
    first.id = 2;
    try tab.appendPane(first);

    const second = try allocator.create(Pane);
    second.* = Pane.init(allocator);
    second.id = 3;
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
    left.id = 2;
    try tab.appendPane(left);

    const right = try allocator.create(Pane);
    right.* = Pane.init(allocator);
    right.id = 3;
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
