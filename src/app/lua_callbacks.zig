const std = @import("std");
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

pub fn luaSplitPaneCallback(app_ptr: *anyopaque, direction: []const u8, ratio: f32, domain_name: ?[]const u8, cwd: ?[]const u8, command: ?[]const u8, command_mode: []const u8, close_on_exit: bool, floating: bool, fullscreen: bool, x: f32, y: f32, width: f32, height: f32, has_bounds: bool, callback_ref: c_int) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const dir: SplitDirection = if (std.mem.eql(u8, direction, "horizontal")) .horizontal else .vertical;
    const mode: SplitCommandMode = if (std.mem.eql(u8, command_mode, "spawn")) .spawn else .send;
    const owned_domain = if (domain_name) |name| app.allocator.dupe(u8, name) catch null else null;
    const owned_cwd = if (cwd) |value| app.allocator.dupe(u8, value) catch null else null;
    const owned_command = if (command) |value| app.allocator.dupe(u8, value) catch null else null;
    var event: input.PendingInputEvent = .{ .split_pane = .{
        .direction = dir,
        .ratio = ratio,
        .domain_name = owned_domain,
        .cwd = owned_cwd,
        .command = owned_command,
        .command_mode = mode,
        .close_on_exit = close_on_exit,
        .floating = floating,
        .fullscreen = fullscreen,
        .x = if (has_bounds) x else null,
        .y = if (has_bounds) y else null,
        .width = if (has_bounds) width else null,
        .height = if (has_bounds) height else null,
        .callback_ref = callback_ref,
    } };
    const queued = app.enqueueMouse(event);
    if (!queued) input.deinitPendingInputEvent(app.allocator, &event);
    return queued;
}

pub fn luaTogglePaneMaximizedCallback(app_ptr: *anyopaque, pane_id: usize, show_background: bool) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.{ .toggle_pane_maximized = .{ .pane_id = pane_id, .show_background = show_background } });
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

pub fn luaNewTabCallback(app_ptr: *anyopaque, domain_name: ?[]const u8, command: ?[]const u8, callback_ref: c_int) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const owned_domain = if (domain_name) |name| app.allocator.dupe(u8, name) catch null else null;
    const owned_command = if (command) |value| app.allocator.dupe(u8, value) catch null else null;
    var event: input.PendingInputEvent = .{ .new_tab = .{ .domain_name = owned_domain, .command = owned_command, .callback_ref = callback_ref } };
    const queued = app.enqueueMouse(event);
    if (!queued) input.deinitPendingInputEvent(app.allocator, &event);
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
    const owned_cwd = if (cwd) |value| app.allocator.dupe(u8, value) catch null else null;
    const owned_domain = if (domain_name) |value| app.allocator.dupe(u8, value) catch null else null;
    const owned_command = if (command) |value| app.allocator.dupe(u8, value) catch null else null;
    const owned_name = if (name) |value| app.allocator.dupe(u8, value) catch null else null;
    var event: input.PendingInputEvent = .{ .new_workspace = .{ .cwd = owned_cwd, .domain_name = owned_domain, .command = owned_command, .name = owned_name, .callback_ref = callback_ref, .queued_at_ms = std.time.milliTimestamp() } };
    const queued = app.enqueueMouse(event);
    if (!queued) input.deinitPendingInputEvent(app.allocator, &event);
    return queued;
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
    return @intFromPtr(pane);
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
    return @intFromPtr(tab.panes.items[index]);
}

pub fn luaGetTabActivePaneIdCallback(app_ptr: *anyopaque, tab_id: usize) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const tab = app.tabById(tab_id) orelse return 0;
    const pane = tab.activePane() orelse return 0;
    return @intFromPtr(pane);
}

pub fn luaGetTabIndexByIdCallback(app_ptr: *anyopaque, tab_id: usize) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return mux_ops.tabIndexById(app, tab_id) orelse std.math.maxInt(usize);
}

pub fn luaGetPaneActiveScreenCallback(app_ptr: *anyopaque, pane_id: usize) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const pane = app.findPaneById(pane_id) orelse return 0;
    return pane.active_screen;
}

pub fn luaGetPanePidCallback(app_ptr: *anyopaque, pane_id: usize) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    const pane = app.findPaneById(pane_id) orelse return 0;
    return pane.childPid();
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
    return pane.domain_name;
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

pub fn luaGetWindowHeightCallback(app_ptr: *anyopaque) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return app.config.window_height;
}

pub fn luaNowMsCallback(app_ptr: *anyopaque) i64 {
    _ = app_ptr;
    return @intCast(@divFloor(std.time.nanoTimestamp(), std.time.ns_per_ms));
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
    return @intFromPtr(pane) == pane_id;
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
    mux_ops.invalidateAllPanes(app);
    app.requestLayoutResize(true);
}

pub fn luaSendTextToPaneCallback(app_ptr: *anyopaque, pane_id: usize, text: []const u8) bool {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return mux_ops.sendTextToPane(app, pane_id, text);
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

pub fn luaGetWorkspaceIdCallback(app_ptr: *anyopaque, index: usize) usize {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    return app.workspaceId(index);
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

pub fn luaCopySelectionCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.copy_selection);
}

pub fn luaPasteClipboardCallback(app_ptr: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(app_ptr));
    _ = app.enqueueMouse(.paste_clipboard);
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
