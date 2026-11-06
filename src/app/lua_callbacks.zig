const std = @import("std");
const io = @import("../io.zig");
const mux_mod = @import("../mux.zig");
const SplitDirection = mux_mod.SplitDirection;
const FocusDirection = mux_mod.FocusDirection;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const SplitCommandMode = app_mod.SplitCommandMode;
const CopyModeMoveKind = app_mod.CopyModeMoveKind;
const PromptJumpDir = app_mod.PromptJumpDir;
const BarSurface = app_mod.BarSurface;
const cmd_ipc = @import("command_dispatcher.zig");
const mux_ops = @import("session_controller.zig");
const input = @import("input.zig");
const quick_select = @import("quick_select.zig");

pub fn luaJobRequestCallback(app_ptr: *anyopaque, request: @import("../command.zig").Request, callback_ref: c_int) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const owned = request.clone(app.allocator) catch return false;
    var event: input.PendingInputEvent = .{ .lua_job_request = .{ .request = owned, .callback_ref = callback_ref } };
    const queued = app.enqueueMouse(event);
    if (!queued) input.deinitPendingInputEvent(app.allocator, &event);
    return queued;
}

pub fn luaSplitPaneCallback(app_ptr: *anyopaque, direction: []const u8, ratio: f32, domain_name: ?[]const u8, cwd: ?[]const u8, command: ?[]const u8, command_mode: []const u8, close_on_exit: bool, floating: bool, fullscreen: bool, x: f32, y: f32, width: f32, height: f32, has_bounds: bool, callback_ref: c_int, edge: ?[]const u8, dock: ?[]const u8) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const edge_value = if (edge) |value| std.meta.stringToEnum(mux_mod.PaneEdge, value) else null;
    const dock_value = if (dock) |value| std.meta.stringToEnum(mux_mod.DockScope, value) else null;
    const dir: SplitDirection = if (std.mem.eql(u8, direction, "horizontal")) .horizontal else .vertical;
    const mode: SplitCommandMode = if (std.mem.eql(u8, command_mode, "spawn")) .spawn else .send;
    var queued = false;
    var event: input.PendingInputEvent = .{ .split_pane = .{
        .direction = dir,
        .edge = edge_value,
        .dock = dock_value,
        .ratio = ratio,
        .domain_name = null,
        .cwd = null,
        .command = null,
        .command_mode = mode,
        .close_on_exit = close_on_exit,
        .floating = floating,
        .fullscreen = fullscreen,
        .x = if (has_bounds) x else null,
        .y = if (has_bounds) y else null,
        .width = if (has_bounds) width else null,
        .height = if (has_bounds) height else null,
        .callback_ref = callback_ref,
        .lua_generation = if (app.lua) |*lua| lua.generation else null,
    } };
    defer if (!queued) input.deinitPendingInputEvent(app.allocator, &event);
    // Preserve the requested target even when only some copies would succeed.
    if (domain_name) |value| event.split_pane.domain_name = app.allocator.dupe(u8, value) catch return false;
    if (cwd) |value| event.split_pane.cwd = app.allocator.dupe(u8, value) catch return false;
    if (command) |value| event.split_pane.command = app.allocator.dupe(u8, value) catch return false;
    queued = app.enqueueMouse(event);
    return queued;
}

pub fn luaTogglePaneMaximizedCallback(app_ptr: *anyopaque, pane_id: usize, show_background: bool) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.{ .toggle_pane_maximized = .{ .pane_id = pane_id, .show_background = show_background } });
}

pub fn luaSetPaneVisibleCallback(app_ptr: *anyopaque, pane_id: usize, visible: bool) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.{ .set_pane_visible = .{ .pane_id = pane_id, .visible = visible } });
}

pub fn luaDockPaneCallback(app_ptr: *anyopaque, pane_id: usize, edge: []const u8, scope: []const u8, ratio: f32) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const edge_value = std.meta.stringToEnum(mux_mod.PaneEdge, edge) orelse return;
    const scope_value = std.meta.stringToEnum(mux_mod.DockScope, scope) orelse return;
    _ = app.enqueueMouse(.{ .dock_pane = .{ .pane_id = pane_id, .edge = edge_value, .scope = scope_value, .ratio = ratio } });
}

pub fn luaUndockPaneCallback(app_ptr: *anyopaque, pane_id: usize) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.{ .undock_pane = pane_id });
}

pub fn luaGetDockPaneCountCallback(app_ptr: *anyopaque) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const mux = if (app.mux) |*m| m else return 0;
    var count: usize = 0;
    var panes = mux.dockPaneIterator();
    while (panes.next()) |_| count += 1;
    return count;
}

pub fn luaGetDockPaneIdAtCallback(app_ptr: *anyopaque, index: usize) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const mux = if (app.mux) |*m| m else return 0;
    var panes = mux.dockPaneIterator();
    var current: usize = 0;
    while (panes.next()) |pane| : (current += 1) {
        if (current == index) return pane.id;
    }
    return 0;
}

pub fn luaSetPaneFloatingCallback(app_ptr: *anyopaque, pane_id: usize, floating: bool) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.{ .set_pane_floating = .{ .pane_id = pane_id, .floating = floating } });
}

pub fn luaSetFloatingPaneBoundsCallback(app_ptr: *anyopaque, pane_id: usize, x: f32, y: f32, width: f32, height: f32) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.{ .set_floating_pane_bounds = .{ .pane_id = pane_id, .x = x, .y = y, .width = width, .height = height } });
}

pub fn luaMovePaneCallback(app_ptr: *anyopaque, pane_id: usize, direction: []const u8, amount: f32) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const dir: FocusDirection = if (std.mem.eql(u8, direction, "left")) .left else if (std.mem.eql(u8, direction, "right")) .right else if (std.mem.eql(u8, direction, "up")) .up else .down;
    _ = app.enqueueMouse(.{ .move_pane = .{ .pane_id = pane_id, .direction = dir, .amount = amount } });
}

pub fn luaSetPaneForegroundProcessCallback(app_ptr: *anyopaque, pane_id: usize, process: []const u8) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    app.setPaneForegroundProcess(pane_id, process);
}

pub fn luaGetPaneForegroundProcessCallback(app_ptr: *anyopaque, pane_id: usize, out_buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return app.getPaneForegroundProcess(pane_id, out_buf);
}

pub fn luaGetPaneProgramStatusCallback(app_ptr: *anyopaque, pane_id: usize) ?*const @import("../term/program_status.zig").State {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const pane = app.findPaneById(pane_id) orelse return null;
    return &pane.program_status;
}

pub fn luaNewTabCallback(app_ptr: *anyopaque, cwd: ?[]const u8, domain_name: ?[]const u8, command: ?[]const u8, callback_ref: c_int, insert_at_end: bool) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    var queued = false;
    var event: input.PendingInputEvent = .{ .new_tab = .{ .cwd = null, .domain_name = null, .command = null, .callback_ref = callback_ref, .insert_at_end = insert_at_end, .lua_generation = if (app.lua) |*lua| lua.generation else null } };
    defer if (!queued) input.deinitPendingInputEvent(app.allocator, &event);
    // Losing an explicit domain under OOM could silently route to another host.
    if (cwd) |value| event.new_tab.cwd = app.allocator.dupe(u8, value) catch return false;
    if (domain_name) |value| event.new_tab.domain_name = app.allocator.dupe(u8, value) catch return false;
    if (command) |value| event.new_tab.command = app.allocator.dupe(u8, value) catch return false;
    queued = app.enqueueMouse(event);
    return queued;
}

pub fn luaCloseTabCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.close_tab);
}

pub fn luaClosePaneCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.close_pane);
}

pub fn luaClosePaneByIdCallback(app_ptr: *anyopaque, pane_id: usize) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return app.enqueueMouse(.{ .close_pane_by_id = pane_id });
}

pub fn luaNextTabCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.next_tab);
}

pub fn luaPrevTabCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.prev_tab);
}

pub fn luaNewWorkspaceCallback(app_ptr: *anyopaque, cwd: ?[]const u8, domain_name: ?[]const u8, command: ?[]const u8, name: ?[]const u8, callback_ref: c_int) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    var queued = false;
    var event: input.PendingInputEvent = .{ .new_workspace = .{ .cwd = null, .domain_name = null, .command = null, .name = null, .callback_ref = callback_ref, .queued_at_ms = io.milliTimestamp(), .lua_generation = if (app.lua) |*lua| lua.generation else null } };
    defer if (!queued) input.deinitPendingInputEvent(app.allocator, &event);
    // Losing an explicit domain under OOM could silently route to another host.
    // Admit all original arguments, or none of them.
    if (cwd) |value| event.new_workspace.cwd = app.allocator.dupe(u8, value) catch return false;
    if (domain_name) |value| event.new_workspace.domain_name = app.allocator.dupe(u8, value) catch return false;
    if (command) |value| event.new_workspace.command = app.allocator.dupe(u8, value) catch return false;
    if (name) |value| event.new_workspace.name = app.allocator.dupe(u8, value) catch return false;
    queued = app.enqueueMouse(event);
    return queued;
}

test "session borrowers workspace callback never drops explicit host arguments on allocation failure" {
    const a = std.testing.allocator;
    const app = try a.create(App);
    defer a.destroy(app);
    app.* = App.init(a);
    defer app.deinit();
    for (0..4) |index| {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = index });
        app.allocator = failing.allocator();
        defer app.allocator = a;
        try std.testing.expect(!luaNewWorkspaceCallback(app, "/work", "persistent-host", "pwd", "name", -1));
        try std.testing.expect(app.action_queue.pop() == null);
    }
}

test "session borrowers tab and split callbacks never drop explicit host arguments on allocation failure" {
    const a = std.testing.allocator;
    const app = try a.create(App);
    defer a.destroy(app);
    app.* = App.init(a);
    defer app.deinit();
    for (0..3) |index| {
        var failing_tab = std.testing.FailingAllocator.init(a, .{ .fail_index = index });
        app.allocator = failing_tab.allocator();
        defer app.allocator = a;
        try std.testing.expect(!luaNewTabCallback(app, "/work", "persistent-host", "pwd", -1, false));
        try std.testing.expect(app.action_queue.pop() == null);
        try std.testing.expectEqual(failing_tab.allocated_bytes, failing_tab.freed_bytes);

        var failing_split = std.testing.FailingAllocator.init(a, .{ .fail_index = index });
        app.allocator = failing_split.allocator();
        try std.testing.expect(!luaSplitPaneCallback(app, "horizontal", 0.5, "persistent-host", "/work", "pwd", "spawn", false, false, false, 0, 0, 0, 0, false, -1));
        try std.testing.expect(app.action_queue.pop() == null);
        try std.testing.expectEqual(failing_split.allocated_bytes, failing_split.freed_bytes);
    }
}

test "session borrowers tab and split callbacks free copied arguments when queue is full" {
    const a = std.testing.allocator;
    const app = try a.create(App);
    defer a.destroy(app);
    app.* = App.init(a);
    defer app.deinit();
    while (app.action_queue.push(.none)) {}
    try std.testing.expect(!luaNewTabCallback(app, "/work", "persistent-host", "pwd", -1, false));
    try std.testing.expect(!luaSplitPaneCallback(app, "horizontal", 0.5, "persistent-host", "/work", "pwd", "spawn", false, false, false, 0, 0, 0, 0, false, -1));
    while (app.action_queue.pop()) |event| try std.testing.expect(event == .none);
}

test "session borrowers workspace tab and split callbacks fence inherited persistent domain generation" {
    const a = std.testing.allocator;
    const app = try a.create(App);
    defer a.destroy(app);
    app.* = App.init(a);
    defer app.deinit();
    app.ghostty = try @import("../term/ghostty.zig").Runtime.init(a, null);
    app.mux = mux_mod.Mux.init(a);
    try app.config.setDomainShell("ordinary", "/bin/sh");
    try app.config.setDefaultDomain("ordinary");
    try app.config.setDomainPersist("persistent-host", true);
    const pane = try a.create(@import("../pane.zig").Pane);
    pane.* = @import("../pane.zig").Pane.init(a);
    pane.id = app.mux.?.reservePaneId();
    pane.content.terminal.domain_name = try a.dupe(u8, "persistent-host");
    try app.mux.?.newWorkspaceWithPane(&app.ghostty.?, pane, null);
    app.lua = try @import("../lua_bridge.zig").Runtime.initForTests(a, &app.config);
    try std.testing.expect(!app.config.persistForDomain(null));
    try std.testing.expect(luaNewWorkspaceCallback(app, null, null, null, null, -1));
    var event = app.action_queue.pop().?;
    defer input.deinitPendingInputEvent(a, &event);
    try std.testing.expectEqual(@as(?u64, app.lua.?.generation), event.new_workspace.lua_generation);
    try std.testing.expect(luaNewTabCallback(app, null, null, null, -1, false));
    var tab_event = app.action_queue.pop().?;
    defer input.deinitPendingInputEvent(a, &tab_event);
    try std.testing.expectEqual(@as(?u64, app.lua.?.generation), tab_event.new_tab.lua_generation);
    try std.testing.expect(luaSplitPaneCallback(app, "horizontal", 0.5, null, null, null, "spawn", false, false, false, 0, 0, 0, 0, false, -1));
    var split_event = app.action_queue.pop().?;
    defer input.deinitPendingInputEvent(a, &split_event);
    try std.testing.expectEqual(@as(?u64, app.lua.?.generation), split_event.split_pane.lua_generation);
}

pub fn luaAttachSessionCallback(app_ptr: *anyopaque, session_id: []const u8, domain_name: ?[]const u8, name: ?[]const u8, callback_ref: c_int) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    var queued = false;
    defer if (!queued) {
        if (app.lua) |*lua| lua.discardOperationCallbackFromLua(callback_ref);
    };
    var event: input.PendingInputEvent = .{ .attach_session = .{
        .session_id = app.allocator.dupe(u8, session_id) catch return,
        .domain_name = null,
        .name = null,
        .callback_ref = callback_ref,
        .lua_generation = if (app.lua) |*lua| lua.generation else null,
    } };
    defer if (!queued) input.deinitPendingInputEvent(app.allocator, &event);
    if (domain_name) |value| event.attach_session.domain_name = app.allocator.dupe(u8, value) catch return;
    if (name) |value| event.attach_session.name = app.allocator.dupe(u8, value) catch return;
    queued = app.enqueueMouse(event);
}

pub fn luaCloseWorkspaceCallback(app_ptr: *anyopaque, workspace_id: ?usize) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.{ .close_workspace = workspace_id });
}

pub fn luaNextWorkspaceCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.next_workspace);
}

pub fn luaPrevWorkspaceCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.prev_workspace);
}

pub fn luaSwitchWorkspaceCallback(app_ptr: *anyopaque, index: usize) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.{ .switch_workspace = index });
}

pub fn luaSetWorkspaceNameCallback(app_ptr: *anyopaque, name: []const u8) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const owned = app.allocator.dupe(u8, name) catch return;
    var event: input.PendingInputEvent = .{ .set_workspace_name = owned };
    if (!app.enqueueMouse(event)) input.deinitPendingInputEvent(app.allocator, &event);
}

pub fn luaSetWorkspaceDefaultCwdCallback(app_ptr: *anyopaque, cwd: []const u8) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const owned = app.allocator.dupe(u8, cwd) catch return;
    var event: input.PendingInputEvent = .{ .set_workspace_default_cwd = owned };
    if (!app.enqueueMouse(event)) input.deinitPendingInputEvent(app.allocator, &event);
}

pub fn luaFocusPaneCallback(app_ptr: *anyopaque, direction: []const u8) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const dir: FocusDirection = if (std.mem.eql(u8, direction, "left")) .left else if (std.mem.eql(u8, direction, "right")) .right else if (std.mem.eql(u8, direction, "up")) .up else .down;
    _ = app.enqueueMouse(.{ .focus_pane = dir });
}

pub fn luaFocusPaneByIdCallback(app_ptr: *anyopaque, pane_id: usize) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    if (app.findPaneById(pane_id) == null) return false;
    return app.enqueueMouse(.{ .focus_pane_by_id = pane_id });
}

pub fn luaResizePaneCallback(app_ptr: *anyopaque, direction: []const u8, delta: f32) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const dir: SplitDirection = if (std.mem.eql(u8, direction, "horizontal")) .horizontal else .vertical;
    _ = app.enqueueMouse(.{ .resize_pane = .{ .direction = dir, .delta = delta } });
}

pub fn luaSwitchTabCallback(app_ptr: *anyopaque, index: usize) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.{ .switch_tab = index });
}

pub fn luaSetTabTitleCallback(app_ptr: *anyopaque, title: []const u8) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    mux_ops.setTabTitle(app, title);
}

pub fn luaCurrentTabIdCallback(app_ptr: *anyopaque) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const tab = app.activeTab() orelse return 0;
    return tab.id;
}

pub fn luaCurrentPaneIdCallback(app_ptr: *anyopaque) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const pane = app.activePane() orelse return 0;
    return pane.id;
}

pub fn luaGetTabIdAtCallback(app_ptr: *anyopaque, index: usize) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const ws = app.activeWorkspace() orelse return 0;
    if (index >= ws.tabs.items.len) return 0;
    return ws.tabs.items[index].id;
}

pub fn luaGetTabPaneCountCallback(app_ptr: *anyopaque, tab_id: usize) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const tab = app.tabById(tab_id) orelse return 0;
    return tab.panes.items.len;
}

pub fn luaGetTabPaneIdAtCallback(app_ptr: *anyopaque, tab_id: usize, index: usize) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const tab = app.tabById(tab_id) orelse return 0;
    if (index >= tab.panes.items.len) return 0;
    return tab.panes.items[index].id;
}

pub fn luaGetTabActivePaneIdCallback(app_ptr: *anyopaque, tab_id: usize) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const tab = app.tabById(tab_id) orelse return 0;
    const pane = tab.activePane() orelse return 0;
    return pane.id;
}

pub fn luaGetTabIndexByIdCallback(app_ptr: *anyopaque, tab_id: usize) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return mux_ops.tabIndexById(app, tab_id) orelse std.math.maxInt(usize);
}

pub fn luaGetPaneActiveScreenCallback(app_ptr: *anyopaque, pane_id: usize) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const pane = app.findPaneById(pane_id) orelse return 0;
    const term = pane.asTerminalConst() orelse return 0;
    return term.active_screen;
}

pub fn luaGetPanePidCallback(app_ptr: *anyopaque, pane_id: usize) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const pane = app.findPaneById(pane_id) orelse return 0;
    const term = pane.asTerminalConst() orelse return 0;
    return term.childPid();
}

pub fn luaGetPaneTitleCallback(app_ptr: *anyopaque, pane_id: usize, out_buf: []u8) []const u8 {
    _ = out_buf;
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const pane = app.findPaneById(pane_id) orelse return "";
    return pane.title;
}

pub fn luaGetPaneTextCallback(app_ptr: *anyopaque, pane_id: usize, out_buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return app.getPaneText(pane_id, out_buf);
}

pub fn luaGetPaneCwdCallback(app_ptr: *anyopaque, pane_id: usize, out_buf: []u8) []const u8 {
    _ = out_buf;
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const pane = app.findPaneById(pane_id) orelse return "";
    return pane.cwd;
}

pub fn luaGetPaneDomainCallback(app_ptr: *anyopaque, pane_id: usize, out_buf: []u8) []const u8 {
    _ = out_buf;
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const pane = app.findPaneById(pane_id) orelse return "";
    return pane.domainName();
}

pub fn luaGetPaneTagCountCallback(app_ptr: *anyopaque, pane_id: usize) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const entry = cmd_ipc.findPaneTagEntry(app, pane_id) orelse return 0;
    return entry.tags.count();
}

pub fn luaGetPaneTagAtCallback(app_ptr: *anyopaque, pane_id: usize, index: usize) ?[]const u8 {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const entry = cmd_ipc.findPaneTagEntry(app, pane_id) orelse return null;
    const keys = entry.tags.keys();
    return if (index < keys.len) keys[index] else null;
}

pub fn luaSetPaneTagsCallback(app_ptr: *anyopaque, pane_id: usize, tags: []const []const u8) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    if (app.findPaneById(pane_id) == null) return false;
    cmd_ipc.setPaneTags(app, pane_id, tags) catch return false;
    return true;
}

pub fn luaGetPaneSplitDirectionCallback(app_ptr: *anyopaque, pane_id: usize) ?[]const u8 {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const pane = app.findPaneById(pane_id) orelse return null;
    const mux = if (app.mux) |*mux| mux else return null;
    const info = mux.paneSplitInfo(pane) orelse return null;
    return switch (info.direction) {
        .horizontal => "horizontal",
        .vertical => "vertical",
    };
}

pub fn luaGetPaneSplitRatioCallback(app_ptr: *anyopaque, pane_id: usize) ?f32 {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const pane = app.findPaneById(pane_id) orelse return null;
    const mux = if (app.mux) |*mux| mux else return null;
    const info = mux.paneSplitInfo(pane) orelse return null;
    return info.size;
}

pub fn luaGetPaneRowsCallback(app_ptr: *anyopaque, pane_id: usize) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const pane = app.findPaneById(pane_id) orelse return 0;
    return pane.rows;
}

pub fn luaGetPaneColsCallback(app_ptr: *anyopaque, pane_id: usize) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const pane = app.findPaneById(pane_id) orelse return 0;
    return pane.cols;
}

pub fn luaGetPaneXCallback(app_ptr: *anyopaque, pane_id: usize) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const pane = app.findPaneById(pane_id) orelse return 0;
    return pane.x_px;
}

pub fn luaGetPaneYCallback(app_ptr: *anyopaque, pane_id: usize) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const pane = app.findPaneById(pane_id) orelse return 0;
    return pane.y_px;
}

pub fn luaGetPaneWidthCallback(app_ptr: *anyopaque, pane_id: usize) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const pane = app.findPaneById(pane_id) orelse return 0;
    return pane.width_px;
}

pub fn luaGetPaneHeightCallback(app_ptr: *anyopaque, pane_id: usize) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const pane = app.findPaneById(pane_id) orelse return 0;
    return pane.height_px;
}

pub fn luaGetWindowWidthCallback(app_ptr: *anyopaque) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return app.config.window_width;
}

pub fn luaWindowIsFocusedCallback(app_ptr: *anyopaque) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return app.window_focused;
}

pub fn luaGetWindowHeightCallback(app_ptr: *anyopaque) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return app.config.window_height;
}

pub fn luaNowMsCallback(app_ptr: *anyopaque) i64 {
    _ = app_ptr;
    return @intCast(@divFloor(io.nanoTimestamp(), std.time.ns_per_ms));
}

pub fn luaPaneIsFloatingCallback(app_ptr: *anyopaque, pane_id: usize) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const pane = app.findPaneById(pane_id) orelse return false;
    return pane.is_floating;
}

pub fn luaPaneIsMaximizedCallback(app_ptr: *anyopaque, pane_id: usize) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const pane = app.findPaneById(pane_id) orelse return false;
    if (app.mux) |*mux| return mux.paneIsMaximized(pane);
    return false;
}

pub fn luaPaneIsFocusedCallback(app_ptr: *anyopaque, pane_id: usize) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const pane = app.activePane() orelse return false;
    return pane.id == pane_id;
}

pub fn luaPaneHasBellCallback(app_ptr: *anyopaque, pane_id: usize) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const pane = app.findPaneById(pane_id) orelse return false;
    return pane.has_bell_attention;
}

pub fn luaPaneExistsCallback(app_ptr: *anyopaque, pane_id: usize) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return app.findPaneById(pane_id) != null;
}

pub fn luaSwitchTabByIdCallback(app_ptr: *anyopaque, tab_id: usize) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const index = mux_ops.tabIndexById(app, tab_id) orelse return false;
    return app.enqueueMouse(.{ .switch_tab = index });
}

pub fn luaCloseTabByIdCallback(app_ptr: *anyopaque, tab_id: usize) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const index = mux_ops.tabIndexById(app, tab_id) orelse return false;
    return app.enqueueMouse(.{ .close_tab_at = index });
}

pub fn luaSetTabTitleByIdCallback(app_ptr: *anyopaque, tab_id: usize, title: []const u8) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return mux_ops.setTabTitleById(app, tab_id, title);
}

pub fn luaReloadConfigCallback(app_ptr: *anyopaque) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.reload_config);
    return true;
}

pub fn luaRefreshLiveConfigCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    std.log.info("config: command_timing={}", .{app.config.command_timing});
    cmd_ipc.syncCommandTimingEnv(app);
    app.pending_renderer_refresh = app.config.backend == .sokol or app.config.backend == .webgpu;
    if (app.ghostty) |*runtime| {
        if (app.mux) |*mux| {
            var panes = mux.paneIterator();
            while (panes.next()) |pane| pane.applyTerminalTheme(runtime, &app.config.terminal_theme);
        }
    }
    mux_ops.invalidateAllPanes(app);
    app.requestLayoutResize(true);
}

pub fn luaSendTextToPaneCallback(app_ptr: *anyopaque, pane_id: usize, text: []const u8) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return mux_ops.sendTextToPane(app, pane_id, text);
}

pub fn luaBellPaneCallback(app_ptr: *anyopaque, pane_id: usize) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return mux_ops.sendBellToPane(app, pane_id, null, null);
}

pub fn luaSendKeyToPaneCallback(app_ptr: *anyopaque, pane_id: usize, key_name: []const u8, mods: u32) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return mux_ops.sendKeyToPane(app, pane_id, key_name, mods);
}

pub fn luaGetTabCountCallback(app_ptr: *anyopaque) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return app.tabCount();
}

pub fn luaGetActiveTabIndexCallback(app_ptr: *anyopaque) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return mux_ops.activeTabIndex(app);
}

pub fn luaGetWorkspaceCountCallback(app_ptr: *anyopaque) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return mux_ops.workspaceCount(app);
}

pub fn luaGetActiveWorkspaceIndexCallback(app_ptr: *anyopaque) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return mux_ops.activeWorkspaceIndex(app);
}

pub fn luaGetWorkspaceNameCallback(app_ptr: *anyopaque, index: usize, out_buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return app.workspaceName(index, out_buf);
}

pub fn luaGetWorkspaceSessionIdCallback(app_ptr: *anyopaque, index: usize, out_buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const mux = if (app.mux) |*mux| mux else return "";
    if (index >= mux.workspaces.items.len) return "";
    const controller = mux.workspaces.items[index].session_controller orelse return "";
    return copyOut(controller.session_id, out_buf);
}

pub fn luaGetWorkspaceSessionHostCallback(app_ptr: *anyopaque, index: usize, out_buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const mux = if (app.mux) |*mux| mux else return "";
    if (index >= mux.workspaces.items.len) return "";
    const controller = mux.workspaces.items[index].session_controller orelse return "";
    return copyOut(controller.host, out_buf);
}

fn copyOut(value: []const u8, out_buf: []u8) []const u8 {
    if (value.len > out_buf.len) return "";
    @memcpy(out_buf[0..value.len], value);
    return out_buf[0..value.len];
}

pub fn luaGetWorkspaceIdCallback(app_ptr: *anyopaque, index: usize) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return app.workspaceId(index);
}

pub fn luaGetWorkspaceTabCountCallback(app_ptr: *anyopaque, workspace_index: usize) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const mux = if (app.mux) |*mux| mux else return 0;
    if (workspace_index >= mux.workspaces.items.len) return 0;
    return mux.workspaces.items[workspace_index].tabs.items.len;
}

pub fn luaGetWorkspaceTabIdAtCallback(app_ptr: *anyopaque, workspace_index: usize, tab_index: usize) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const mux = if (app.mux) |*mux| mux else return 0;
    if (workspace_index >= mux.workspaces.items.len) return 0;
    const workspace = mux.workspaces.items[workspace_index];
    if (tab_index >= workspace.tabs.items.len) return 0;
    return workspace.tabs.items[tab_index].id;
}

pub fn luaIsLeaderActiveCallback(app_ptr: *anyopaque) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return app.isLeaderActive();
}

pub fn luaSetLeaderStateCallback(app_ptr: *anyopaque, active: bool, expires_at_ms: i64) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    app.setLeaderState(active, expires_at_ms);
}

pub fn luaSetBarCacheStateCallback(app_ptr: *anyopaque, surface: []const u8, dirty: bool, expires_at_ms: i64, visible: bool) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const bar_surface: BarSurface = if (std.mem.eql(u8, surface, "bottombar")) .bottombar else .topbar;
    app.setBarCacheState(bar_surface, dirty, expires_at_ms, visible);
}

pub fn luaRequestLayoutRefreshCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    app.requestLayoutRefresh();
}

pub fn luaRequestRedrawCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    app.requestRedraw();
}

pub fn luaCopySelectionCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.copy_selection);
}

pub fn luaClipboardWriteCallback(app_ptr: *anyopaque, text: []const u8) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    // Sokol accepts C strings; reject embedded NUL rather than silently truncate.
    if (std.mem.indexOfScalar(u8, text, 0) != null) return false;
    const owned = app.allocator.dupeSentinel(u8, text, 0) catch return false;
    if (!app.enqueueMouse(.{ .clipboard_write = owned })) {
        app.allocator.free(owned);
        return false;
    }
    return true;
}

pub fn luaPasteClipboardCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.paste_clipboard);
}

pub fn luaClipboardReadCallback(app_ptr: *anyopaque) []const u8 {
    // Called synchronously by Lua's UI key handler; the bridge copies into Lua.
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return app.readClipboard();
}

pub fn luaClipboardReadAuthorizeCallback(app_ptr: *anyopaque, pane_id: usize, allow: bool, generation: ?usize) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const pane = app.findPaneById(pane_id) orelse return false;
    const term = pane.asTerminal() orelse return false;
    if (generation) |value| if (!term.clipboard_read.matchesPrompt(value)) return false;
    term.clipboard_read.revoke(app.allocator);
    if (!allow) return true;
    if (!app.window_focused or app.activePane() != pane) return false;
    // Capture only from the user's UI action, never inside the VT callback.
    term.clipboard_read.approve(app.allocator, app.readClipboard(), io.nanoTimestamp()) catch return false;
    return true;
}

pub fn luaScrollActiveCallback(app_ptr: *anyopaque, delta: isize) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.{ .scroll_active_delta = delta });
}

pub fn luaScrollActivePageCallback(app_ptr: *anyopaque, pages: isize) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.{ .scroll_active_page = pages });
}

pub fn luaScrollActiveTopCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.scroll_active_top);
}

pub fn luaScrollActiveBottomCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.scroll_active_bottom);
}

pub fn luaPromptJumpCallback(app_ptr: *anyopaque, direction: []const u8) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const dir: PromptJumpDir = if (std.mem.eql(u8, direction, "prev")) .prev else .next;
    _ = app.enqueueMouse(.{ .prompt_jump = dir });
}

pub fn luaCopyModeEnterCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.copy_mode_enter);
}

pub fn luaCopyModeExitCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.copy_mode_exit);
}

pub fn luaCopyModeMoveCallback(app_ptr: *anyopaque, direction: []const u8, extend: bool) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const kind: CopyModeMoveKind = if (std.mem.eql(u8, direction, "left"))
        .left
    else if (std.mem.eql(u8, direction, "right"))
        .right
    else if (std.mem.eql(u8, direction, "up"))
        .up
    else if (std.mem.eql(u8, direction, "down"))
        .down
    else if (std.mem.eql(u8, direction, "page_up"))
        .page_up
    else if (std.mem.eql(u8, direction, "page_down"))
        .page_down
    else if (std.mem.eql(u8, direction, "line_start"))
        .line_start
    else if (std.mem.eql(u8, direction, "line_end"))
        .line_end
    else if (std.mem.eql(u8, direction, "top"))
        .top
    else if (std.mem.eql(u8, direction, "bottom"))
        .bottom
    else
        return;
    _ = app.enqueueMouse(.{ .copy_mode_move = .{ .kind = kind, .extend = extend } });
}

pub fn luaCopyModeClearSelectionCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.copy_mode_clear_selection);
}

pub fn luaCopyModeBeginSelectionCallback(app_ptr: *anyopaque, block: bool) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.{ .copy_mode_begin_selection = block });
}

pub fn luaCopyModeCopyCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.copy_mode_copy);
}

pub fn luaCopyModeOpenSearchCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.copy_mode_open_search);
}

pub fn luaCopyModeSearchSetQueryCallback(app_ptr: *anyopaque, query: []const u8) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const owned = app.allocator.dupe(u8, query) catch return;
    var event: input.PendingInputEvent = .{ .copy_mode_search_set_query = owned };
    if (!app.enqueueMouse(event)) input.deinitPendingInputEvent(app.allocator, &event);
}

pub fn luaCopyModeSearchNextCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.copy_mode_search_next);
}

pub fn luaCopyModeSearchPrevCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.copy_mode_search_prev);
}

pub fn luaTerminalFindCallback(app_ptr: *anyopaque, pane_id: usize, session: usize, operation: []const u8, query: []const u8) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const op = std.meta.stringToEnum(@import("terminal_find.zig").Operation, operation) orelse return false;
    // Cancellation must not fail when the input queue is full. It also acts
    // as a barrier against already queued queries from an unmounted widget.
    if (op == .close) {
        app.find_cancelled_session = @max(app.find_cancelled_session, session);
        return true;
    }
    if (session <= app.find_cancelled_session) return false;
    if (query.len > 8192) return false;
    const owned = app.allocator.dupe(u8, query) catch return false;
    var event: input.PendingInputEvent = .{ .terminal_find = .{ .pane_id = pane_id, .session = session, .epoch = app.find_epoch, .operation = op, .query = owned } };
    if (app.enqueueMouse(event)) return true;
    input.deinitPendingInputEvent(app.allocator, &event);
    return false;
}

pub fn luaQuickSelectStartCallback(app_ptr: *anyopaque, action: []const u8) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const selected: quick_select.Action = if (std.mem.eql(u8, action, "copy")) .copy else .open;
    quick_select.armInput(app);
    if (!app.enqueueMouse(.{ .quick_select_start = selected })) quick_select.disarmInput(app);
}

pub fn luaMoveTabToWorkspaceCallback(app_ptr: *anyopaque, tab_id: usize, workspace_index: usize) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return app.enqueueMouse(.{ .move_tab_to_workspace = .{ .tab_id = tab_id, .workspace_index = workspace_index } });
}

pub fn luaMovePaneToWorkspaceCallback(app_ptr: *anyopaque, pane_id: usize, workspace_index: usize) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return app.enqueueMouse(.{ .move_pane_to_workspace = .{ .pane_id = pane_id, .workspace_index = workspace_index } });
}
