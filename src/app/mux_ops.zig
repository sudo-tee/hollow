const std = @import("std");
const c = @import("sokol_c");
const builtin = @import("builtin");
const ghostty = @import("../term/ghostty.zig");
const GhosttyRuntime = ghostty.Runtime;
const htp = @import("htp.zig");
const text_helpers = @import("text_helpers.zig");
const terminal_callbacks = @import("terminal_callbacks.zig");
const selection_mod = @import("selection.zig");
const scroll = @import("scroll.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Mux = @import("../mux.zig").Mux;
const Workspace = @import("../mux.zig").Workspace;
const Tab = @import("../mux.zig").Tab;
const SplitDirection = @import("../mux.zig").SplitDirection;
const FocusDirection = @import("../mux.zig").FocusDirection;
const LayoutLeaf = @import("../mux.zig").LayoutLeaf;
const PaneBounds = @import("../mux.zig").PaneBounds;
const MAX_LAYOUT_LEAVES = @import("../mux.zig").MAX_LAYOUT_LEAVES;
const SplitCommandMode = app_mod.SplitCommandMode;
const Pane = @import("../pane.zig").Pane;
const LaunchCommand = @import("../pty/launch_command.zig").LaunchCommand;

// ============================================================
// Send/text operations
// ============================================================

pub fn sendText(self: *App, text: []const u8) void {
    const pane = self.activePane() orelse return;
    const now_ns = std.time.nanoTimestamp();
    self.last_input_activity_ns = now_ns;
    self.last_visual_activity_ns = now_ns;
    pane.pty_received_data = true;
    pane.pty_wrote_this_frame = true;
    pane.last_render_state_update_ns = 0;
    if (self.config.debug_terminal_trace) {
        std.log.info("terminal-trace sendText pane={x} len={d} sample={s}", .{
            @intFromPtr(pane),
            text.len,
            text[0..@min(text.len, 32)],
        });
    }
    scrollActiveViewportBottom(self);
    pane.sendText(text);
    self.signalWake();
}

pub fn sendTextToPane(self: *App, pane_id: usize, text: []const u8) bool {
    const pane = self.findPaneById(pane_id) orelse return false;
    pane.sendText(text);
    return true;
}

pub fn sendKeyToPane(self: *App, pane_id: usize, key_name: []const u8, mods: u32) bool {
    const pane = self.findPaneById(pane_id) orelse return false;
    const rt = if (self.ghostty) |*r| r else return false;
    const key = std.meta.stringToEnum(ghostty.Key, key_name) orelse return false;

    var buf: [128]u8 = undefined;
    var text_buf: [4]u8 = undefined;
    const effective_text = text_helpers.legacyPrintableKeyText(key, mods, &text_buf);
    const consumed: u32 = if (effective_text != null and (mods & ghostty.Mods.shift) != 0) ghostty.Mods.shift else ghostty.Mods.none;

    if (rt.encodeKey(pane.key_encoder, pane.key_event, key, mods, .press, consumed, if (effective_text) |t| text_helpers.firstCodepoint(t) else 0, effective_text, &buf)) |bytes| {
        pane.sendText(bytes);
        return true;
    }

    if (effective_text != null and (mods & ghostty.Mods.alt) != 0 and (mods & (ghostty.Mods.ctrl | ghostty.Mods.super)) == 0) {
        pane.sendText("\x1b");
        pane.sendText(effective_text.?);
        return true;
    }

    return false;
}

// ============================================================
// Startup and invalidation
// ============================================================

pub fn maybeRunStartupCommand(self: *App) void {
    if (self.startup_command_sent) return;
    const command = self.startup_command orelse return;
    if (self.frame_count < self.startup_command_delay_frames) return;
    sendText(self, command);
    if (!std.mem.endsWith(u8, command, "\r") and !std.mem.endsWith(u8, command, "\n")) {
        sendText(self, "\r");
    }
    self.startup_command_sent = true;
}

pub fn invalidateAllPanes(self: *App) void {
    const mux = if (self.mux) |*m| m else return;
    var panes = mux.paneIterator();
    while (panes.next()) |pane| {
        pane.render_dirty = .full;
        pane.last_render_state_update_ns = 0;
    }
}

pub fn sendPaste(self: *App, text: []const u8) !void {
    const pane = self.activePane() orelse return;
    const rt = if (self.ghostty) |*r| r else {
        if (self.config.debug_terminal_trace) {
            std.log.info("terminal-trace sendPaste pane={x} len={d} bracketed=false runtime=false", .{ @intFromPtr(pane), text.len });
        }
        sendText(self, text);
        return;
    };
    const bracketed = rt.terminalMode(pane.terminal, .bracketed_paste);
    if (self.config.debug_terminal_trace) {
        std.log.info("terminal-trace sendPaste pane={x} len={d} bracketed={}", .{ @intFromPtr(pane), text.len, bracketed });
    }
    if (bracketed) {
        const prefix = "\x1b[200~";
        const suffix = "\x1b[201~";
        const payload = try self.allocator.alloc(u8, prefix.len + text.len + suffix.len);
        defer self.allocator.free(payload);
        @memcpy(payload[0..prefix.len], prefix);
        @memcpy(payload[prefix.len .. prefix.len + text.len], text);
        @memcpy(payload[prefix.len + text.len ..], suffix);
        sendText(self, payload);
        return;
    }
    sendText(self, text);
}

// ============================================================
// Scroll operations
// ============================================================

pub fn scrollActiveViewportPage(self: *App, pages: isize) void {
    const pane = self.activePane() orelse return;
    scroll.scrollPaneViewport(self, pane, pages * scroll.pageScrollRows(pane));
}

pub fn scrollActiveViewportTop(self: *App) void {
    const pane = self.activePane() orelse return;
    scroll.scrollPaneViewportToRow(self, pane, 0);
}

pub fn scrollActiveViewportBottom(self: *App) void {
    const pane = self.activePane() orelse return;
    scroll.scrollPaneViewportToRow(self, pane, scroll.scrollbarMaxTopRow(pane.scrollbar()));
}

// ============================================================
// Tab operations
// ============================================================

pub fn newTab(self: *App, domain_name: ?[]const u8, command: ?[]const u8, callback_ref: c_int) void {
    const start_ms = std.time.milliTimestamp();
    var mux = if (self.mux) |*value| value else return;
    const runtime = if (self.ghostty) |*value| value else return;
    const cbs = terminal_callbacks.terminalCallbacks();
    const previous = mux.activePane();
    const launch_command: ?LaunchCommand = if (command) |value|
        .{ .command = value }
    else
        null;
    mux.newTab(runtime, cbs, self.config, self.cell_width_px, self.cell_height_px, self.config.window_width, self.config.window_height, domain_name, launch_command) catch |err| {
        std.log.err("app: newTab failed: {s}", .{@errorName(err)});
        if (self.lua) |*lua| lua.invokeOperationCallback(callback_ref, false, .none);
        return;
    };
    self.requestLayoutResize(false);
    self.syncActivePaneChange(previous, mux.activePane());
    const tab_id = if (mux.activeTab()) |tab| tab.id else 0;
    if (mux.activeTab()) |tab| {
        self.emitLuaBuiltInEvent("term:tab_activated", .{ .tab_id = tab.id });
    }
    htp.bindHtpHandlers(self);
    if (self.lua) |*lua| lua.invokeOperationCallback(callback_ref, true, .{ .tab_id = tab_id });
    std.log.info("app: newTab total_ms={d}", .{std.time.milliTimestamp() - start_ms});
    std.log.info("app: created new tab", .{});
}

pub fn emitWorkspaceClosedIfRemoved(self: *App, mux: *Mux) void {
    if (mux.last_removed_workspace_name) |name| {
        self.emitLuaBuiltInEvent("workspace:closed", .{ .workspace_closed = .{ .name = name } });
        self.allocator.free(name);
        mux.last_removed_workspace_name = null;
    }
}

pub fn quitOnWorkspaceRemoved(self: *App, mux: *Mux, log_msg: ?[]const u8) void {
    if (log_msg) |msg| std.log.info("{s}", .{msg});
    if (mux.last_removed_workspace_name) |n| self.allocator.free(n);
    mux.last_removed_workspace_name = null;
    self.pending_quit = true;
}

pub fn closeTab(self: *App) void {
    var mux = if (self.mux) |*value| value else return;
    const runtime = if (self.ghostty) |*value| value else return;
    const closed_tab_id = if (mux.activeTab()) |tab| tab.id else null;
    const should_quit = mux.closeTab(runtime);
    if (closed_tab_id) |tab_id| {
        self.emitLuaBuiltInEvent("term:tab_closed", .{ .tab_id = tab_id });
    }
    if (should_quit) {
        quitOnWorkspaceRemoved(self, mux, "app: last tab closed, quitting");
        return;
    }
    emitWorkspaceClosedIfRemoved(self, mux);
    self.refreshActivePaneBinding();
    if (mux.activeTab()) |tab| {
        self.emitLuaBuiltInEvent("term:tab_activated", .{ .tab_id = tab.id });
    }
    self.requestLayoutRefresh();
}

pub fn closeTabAt(self: *App, index: usize) void {
    var mux = if (self.mux) |*value| value else return;
    const runtime = if (self.ghostty) |*value| value else return;
    const closed_tab_id = if (mux.tabAt(index)) |tab| tab.id else null;
    const should_quit = mux.closeTabAt(runtime, index);
    if (closed_tab_id) |tab_id| {
        self.emitLuaBuiltInEvent("term:tab_closed", .{ .tab_id = tab_id });
    }
    if (should_quit) {
        quitOnWorkspaceRemoved(self, mux, "app: last tab closed, quitting");
        return;
    }
    emitWorkspaceClosedIfRemoved(self, mux);
    self.refreshActivePaneBinding();
    if (mux.activeTab()) |tab| {
        self.emitLuaBuiltInEvent("term:tab_activated", .{ .tab_id = tab.id });
    }
    self.requestLayoutRefresh();
}

pub fn closeActivePane(self: *App) void {
    var mux = if (self.mux) |*value| value else return;
    const runtime = if (self.ghostty) |*value| value else return;
    const should_quit = mux.closeActivePane(runtime);
    if (should_quit) {
        quitOnWorkspaceRemoved(self, mux, "app: last pane closed via close_pane, quitting");
        return;
    }
    emitWorkspaceClosedIfRemoved(self, mux);
    self.refreshActivePaneBinding();
    self.requestLayoutResize(false);
    std.log.info("app: active pane closed via close_pane", .{});
}

pub fn moveTabToWorkspace(self: *App, tab_id: usize, workspace_index: usize) void {
    var mux = if (self.mux) |*value| value else return;
    const runtime = if (self.ghostty) |*value| value else return;
    const previous = mux.activePane();
    if (!mux.moveTabToWorkspace(runtime, tab_id, workspace_index)) return;
    self.syncActivePaneChange(previous, mux.activePane());
    self.refreshActivePaneDisplay();
    emitWorkspaceClosedIfRemoved(self, mux);
    self.emitLuaBuiltInEvent("workspace:changed", .{ .workspace_index = mux.activeWorkspaceIndex() });
    self.requestLayoutRefresh();
    if (mux.activeTab()) |tab| self.emitLuaBuiltInEvent("term:tab_activated", .{ .tab_id = tab.id });
}

pub fn movePaneToWorkspace(self: *App, pane_id: usize, workspace_index: usize) void {
    var mux = if (self.mux) |*value| value else return;
    const runtime = if (self.ghostty) |*value| value else return;
    const previous = mux.activePane();
    if (!mux.movePaneToWorkspace(runtime, pane_id, workspace_index)) return;
    self.syncActivePaneChange(previous, mux.activePane());
    self.refreshActivePaneDisplay();
    emitWorkspaceClosedIfRemoved(self, mux);
    self.emitLuaBuiltInEvent("workspace:changed", .{ .workspace_index = mux.activeWorkspaceIndex() });
    self.requestLayoutResize(true);
    self.requestLayoutRefresh();
    if (mux.activeTab()) |tab| self.emitLuaBuiltInEvent("term:tab_activated", .{ .tab_id = tab.id });
}

// ============================================================
// Pane operations
// ============================================================

pub fn closePaneById(self: *App, pane_id: usize) void {
    var mux = if (self.mux) |*value| value else return;
    const runtime = if (self.ghostty) |*value| value else return;
    const previous = mux.activePane();
    const should_quit = mux.closePaneById(runtime, pane_id);
    if (should_quit) {
        quitOnWorkspaceRemoved(self, mux, "app: last pane closed via close_pane_by_id, quitting");
        return;
    }
    emitWorkspaceClosedIfRemoved(self, mux);
    self.syncActivePaneChange(previous, mux.activePane());
    self.refreshActivePaneBinding();
    self.requestLayoutResize(false);
    self.requestLayoutRefresh();
}

pub fn focusPaneById(self: *App, pane_id: usize) void {
    if (self.mux) |*mux| {
        const previous = mux.activePane();
        if (!mux.focusPaneById(pane_id)) return;
        self.syncActivePaneChange(previous, mux.activePane());
        self.refreshActivePaneDisplay();
        if (mux.activeTab()) |tab| self.emitLuaBuiltInEvent("term:tab_activated", .{ .tab_id = tab.id });
        self.emitLuaBuiltInEvent("workspace:changed", .{ .workspace_index = mux.activeWorkspaceIndex() });
        self.emitLuaBuiltInEvent("term:pane_focused", .{ .pane_id = pane_id });
        self.requestLayoutRefresh();
    }
}

pub fn nextTab(self: *App) void {
    if (self.mux) |*mux| {
        const previous = mux.activePane();
        mux.nextTab();
        self.syncActivePaneChange(previous, mux.activePane());
        self.refreshActivePaneDisplay();
        if (mux.activeTab()) |tab| self.emitLuaBuiltInEvent("term:tab_activated", .{ .tab_id = tab.id });
    }
    self.requestLayoutRefresh();
}

pub fn prevTab(self: *App) void {
    if (self.mux) |*mux| {
        const previous = mux.activePane();
        mux.prevTab();
        self.syncActivePaneChange(previous, mux.activePane());
        self.refreshActivePaneDisplay();
        if (mux.activeTab()) |tab| self.emitLuaBuiltInEvent("term:tab_activated", .{ .tab_id = tab.id });
    }
    self.requestLayoutRefresh();
}

// ============================================================
// Workspace operations
// ============================================================

pub fn newWorkspace(self: *App, cwd: ?[]const u8, domain_name: ?[]const u8, command: ?[]const u8, name: ?[]const u8, callback_ref: c_int) void {
    const start_ms = std.time.milliTimestamp();
    std.log.info("app: newWorkspace start_ms={d}", .{start_ms});
    var mux = if (self.mux) |*value| value else return;
    const runtime = if (self.ghostty) |*value| value else return;
    const cbs = terminal_callbacks.terminalCallbacks();
    const previous = mux.activePane();
    const inherited_domain = if (domain_name) |value|
        if (value.len > 0) value else null
    else if (previous) |pane|
        if (pane.domain_name.len > 0) pane.domain_name else null
    else
        null;
    const inherited_cwd = if (cwd) |value|
        if (value.len > 0) value else null
    else if (previous) |pane|
        if (pane.cwd.len > 0 and std.mem.eql(u8, pane.domain_name, inherited_domain orelse "")) pane.cwd else null
    else
        null;
    mux.newWorkspace(runtime, cbs, self.config, self.cell_width_px, self.cell_height_px, self.config.window_width, self.config.window_height, inherited_cwd, inherited_domain, null, name) catch |err| {
        std.log.err("app: newWorkspace failed: {s}", .{@errorName(err)});
        if (self.lua) |*lua| lua.invokeOperationCallback(callback_ref, false, .none);
        return;
    };
    htp.bindHtpHandlers(self);
    self.syncActivePaneChange(previous, mux.activePane());
    if (command) |value| {
        if (mux.activePane()) |pane| pane.sendText(value);
    }
    self.emitLuaBuiltInEvent("workspace:new", .{ .workspace_index = mux.activeWorkspaceIndex() });
    self.emitLuaBuiltInEvent("workspace:changed", .{ .workspace_index = mux.activeWorkspaceIndex() });
    self.requestLayoutResize(false);
    if (self.lua) |*lua| lua.invokeOperationCallback(callback_ref, true, .{ .workspace_index = mux.activeWorkspaceIndex() });
    std.log.info("app: newWorkspace total_ms={d}", .{std.time.milliTimestamp() - start_ms});
    std.log.info("app: created new workspace", .{});
}

pub fn closeWorkspace(self: *App, workspace_id: ?usize) void {
    var mux = if (self.mux) |*value| value else return;
    const runtime = if (self.ghostty) |*value| value else return;
    const closing_active_workspace = if (workspace_id) |target_id|
        if (mux.activeWorkspace()) |workspace| workspace.id == target_id else false
    else
        mux.activeWorkspace() != null;
    const previous = if (closing_active_workspace) null else mux.activePane();
    const should_quit = mux.closeWorkspace(runtime, workspace_id);
    if (should_quit) {
        quitOnWorkspaceRemoved(self, mux, null);
        return;
    }
    self.syncActivePaneChange(previous, mux.activePane());
    self.refreshActivePaneDisplay();
    if (mux.activeTab()) |tab| self.emitLuaBuiltInEvent("term:tab_activated", .{ .tab_id = tab.id });
    self.emitLuaBuiltInEvent("workspace:changed", .{ .workspace_index = mux.activeWorkspaceIndex() });
    emitWorkspaceClosedIfRemoved(self, mux);
    self.requestLayoutRefresh();
}

pub fn nextWorkspace(self: *App) void {
    if (self.mux) |*mux| {
        const previous = mux.activePane();
        mux.nextWorkspace();
        self.syncActivePaneChange(previous, mux.activePane());
        self.refreshActivePaneDisplay();
        self.emitLuaBuiltInEvent("workspace:changed", .{ .workspace_index = mux.activeWorkspaceIndex() });
        self.requestLayoutRefresh();
    }
}

pub fn prevWorkspace(self: *App) void {
    if (self.mux) |*mux| {
        const previous = mux.activePane();
        mux.prevWorkspace();
        self.syncActivePaneChange(previous, mux.activePane());
        self.refreshActivePaneDisplay();
        self.emitLuaBuiltInEvent("workspace:changed", .{ .workspace_index = mux.activeWorkspaceIndex() });
        self.requestLayoutRefresh();
    }
}

pub fn workspaceCount(self: *App) usize {
    if (self.mux) |*mux| return mux.workspaceCount();
    return 0;
}

pub fn activeWorkspaceIndex(self: *App) usize {
    if (self.mux) |*mux| return mux.activeWorkspaceIndex();
    return 0;
}

pub fn switchWorkspace(self: *App, index: usize) void {
    if (self.mux) |*mux| {
        const previous = mux.activePane();
        mux.switchWorkspace(index);
        self.syncActivePaneChange(previous, mux.activePane());
        self.refreshActivePaneDisplay();
        if (mux.activeTab()) |tab| self.emitLuaBuiltInEvent("term:tab_activated", .{ .tab_id = tab.id });
        self.emitLuaBuiltInEvent("workspace:changed", .{ .workspace_index = mux.activeWorkspaceIndex() });
        self.requestLayoutRefresh();
    }
}

// ============================================================
// Split/resize operations
// ============================================================

pub fn splitPane(self: *App, direction: SplitDirection, ratio: f32, domain_name: ?[]const u8, cwd: ?[]const u8, command: ?[]const u8, command_mode: SplitCommandMode, close_on_exit: bool, floating: bool, fullscreen: bool, x: ?f32, y: ?f32, width: ?f32, height: ?f32, callback_ref: c_int) void {
    const start_ms = std.time.milliTimestamp();
    var mux = if (self.mux) |*value| value else return;
    const runtime = if (self.ghostty) |*value| value else return;
    const cbs = terminal_callbacks.terminalCallbacks();
    const previous = mux.activePane();
    const launch_command: ?LaunchCommand = if (command != null and command_mode == .spawn)
        .{ .command = command.?, .close_on_exit = close_on_exit }
    else
        null;
    const split_bounds = blk: {
        if (previous) |pane| {
            var layout_buf: [MAX_LAYOUT_LEAVES]LayoutLeaf = undefined;
            const leaves = self.computeActiveLayout(&layout_buf);
            for (leaves) |leaf| {
                if (leaf.pane == pane) {
                    break :blk PaneBounds{ .x = 0, .y = 0, .width = leaf.bounds.width, .height = leaf.bounds.height };
                }
            }
            if (pane.width_px > 0 and pane.height_px > 0) {
                break :blk PaneBounds{ .x = 0, .y = 0, .width = pane.width_px, .height = pane.height_px };
            }
        }
        break :blk self.activeLayoutBounds();
    };
    const snapped_ratio = snapSplitRatio(self, ratio, direction, split_bounds);
    std.log.info("split-trace create dir={s} requested={d:.4} snapped={d:.4} bounds={d}x{d} cell={d}x{d}", .{
        @tagName(direction),
        ratio,
        snapped_ratio,
        split_bounds.width,
        split_bounds.height,
        self.cell_width_px,
        self.cell_height_px,
    });
    const pane = mux.splitActivePane(runtime, cbs, self.config, self.cell_width_px, self.cell_height_px, self.config.window_width, self.config.window_height, direction, snapped_ratio, domain_name, cwd, floating, launch_command) catch |err| {
        std.log.err("app: splitPane failed: {s}", .{@errorName(err)});
        if (self.lua) |*lua| lua.invokeOperationCallback(callback_ref, false, .none);
        return;
    };
    if (!floating) {
        if (previous) |prev| {
            if (mux.splitContainingPane(prev, direction)) |node| {
                self.pending_post_split_snap = .{
                    .node = node,
                    .ratio = ratio,
                    .direction = direction,
                };
                self.debug_split_trace_frames = 4;
            }
        }
    }
    if (floating) {
        if (x != null or y != null or width != null or height != null) {
            _ = mux.setFloatingPaneBounds(
                pane,
                x orelse pane.floating_x,
                y orelse pane.floating_y,
                width orelse pane.floating_width,
                height orelse pane.floating_height,
            );
        }
    }
    if (fullscreen) {
        _ = mux.togglePaneMaximized(pane, false);
    }
    if (command_mode == .send) {
        if (command) |cmd| {
            sendSplitPaneCommand(self, pane, cmd, close_on_exit);
        }
    }
    htp.bindHtpHandlers(self);
    self.syncActivePaneChange(previous, mux.activePane());
    if (self.lua) |*lua| lua.invokeOperationCallback(callback_ref, true, .{ .pane_id = @intFromPtr(pane) });
    self.requestLayoutResize(false);
    std.log.info("app: splitPane total_ms={d}", .{std.time.milliTimestamp() - start_ms});
    std.log.info("app: pane split done direction={s}", .{@tagName(direction)});
}

pub fn snapSplitRatio(self: *App, ratio: f32, direction: SplitDirection, bounds: PaneBounds) f32 {
    const cell_w = @max(1, self.cell_width_px);
    const cell_h = @max(1, self.cell_height_px);

    return switch (direction) {
        .vertical => blk: {
            const usable = if (bounds.width > 1) bounds.width - 1 else bounds.width;
            const total: u32 = @max(1, usable / cell_w);
            const first = @max(1, @min(total - 1, @as(u32, @intFromFloat(@round(ratio * @as(f32, @floatFromInt(total)))))));
            break :blk @as(f32, @floatFromInt(first)) / @as(f32, @floatFromInt(total));
        },
        .horizontal => blk: {
            const usable = if (bounds.height > 1) bounds.height - 1 else bounds.height;
            const total: u32 = @max(1, usable / cell_h);
            const first = @max(1, @min(total - 1, @as(u32, @intFromFloat(@round(ratio * @as(f32, @floatFromInt(total)))))));
            break :blk @as(f32, @floatFromInt(first)) / @as(f32, @floatFromInt(total));
        },
    };
}

pub fn resizePane(self: *App, direction: SplitDirection, delta: f32) void {
    if (self.mux) |*mux| {
        mux.resizeActivePane(direction, delta);
        self.requestLayoutResize(false);
    }
}

pub fn togglePaneMaximizedById(self: *App, pane_id: usize, show_background: bool) void {
    const pane = self.findPaneById(pane_id) orelse return;
    if (self.mux) |*mux| {
        const previous = mux.activePane();
        if (!mux.togglePaneMaximized(pane, show_background)) return;
        self.syncActivePaneChange(previous, mux.activePane());
        self.requestLayoutResize(false);
        self.emitLuaBuiltInEvent("term:pane_focused", .{ .pane_id = pane_id });
        self.emitLuaBuiltInEvent("term:pane_layout_changed", .{ .pane_layout_changed = .{ .pane_id = pane_id } });
    }
}

pub fn setPaneFloatingById(self: *App, pane_id: usize, floating: bool) void {
    const pane = self.findPaneById(pane_id) orelse return;
    if (self.mux) |*mux| {
        const previous = mux.activePane();
        if (!mux.setPaneFloating(pane, floating)) return;
        self.syncActivePaneChange(previous, mux.activePane());
        self.requestLayoutResize(false);
        if (floating) self.emitLuaBuiltInEvent("term:pane_focused", .{ .pane_id = pane_id });
        self.emitLuaBuiltInEvent("term:pane_layout_changed", .{ .pane_layout_changed = .{ .pane_id = pane_id } });
    }
}

pub fn setFloatingPaneBoundsById(self: *App, pane_id: usize, x: f32, y: f32, width: f32, height: f32) void {
    const pane = self.findPaneById(pane_id) orelse return;
    if (self.mux) |*mux| {
        if (!mux.setFloatingPaneBounds(pane, x, y, width, height)) return;
        self.requestLayoutResize(false);
        self.emitLuaBuiltInEvent("term:pane_layout_changed", .{ .pane_layout_changed = .{ .pane_id = pane_id } });
    }
}

pub fn movePaneById(self: *App, pane_id: usize, direction: FocusDirection, amount: f32) void {
    const pane = self.findPaneById(pane_id) orelse return;
    if (self.mux) |*mux| {
        if (!mux.movePane(pane, direction, self.config.window_width, self.config.window_height, amount)) return;
        self.requestLayoutResize(false);
        self.emitLuaBuiltInEvent("term:pane_layout_changed", .{ .pane_layout_changed = .{ .pane_id = pane_id } });
    }
}

pub fn focusPane(self: *App, direction: FocusDirection) void {
    if (self.mux) |*mux| {
        const previous = mux.activePane();
        mux.focusPaneInDirection(direction, self.config.window_width, self.config.window_height);
        self.syncActivePaneChange(previous, mux.activePane());
        if (mux.activePane()) |pane| {
            if (previous != pane) self.emitLuaBuiltInEvent("term:pane_focused", .{ .pane_id = @intFromPtr(pane) });
        }
    }
}

// ============================================================
// Workspace metadata operations
// ============================================================

pub fn setWorkspaceName(self: *App, name: []const u8) void {
    const ws = self.activeWorkspace() orelse return;
    ws.setName(name) catch |err| {
        std.log.err("app: setWorkspaceName failed: {s}", .{@errorName(err)});
        return;
    };
    if (self.mux) |*mux| self.emitLuaBuiltInEvent("workspace:changed", .{ .workspace_index = mux.activeWorkspaceIndex() });
}

pub fn setWorkspaceDefaultCwd(self: *App, cwd: []const u8) void {
    const ws = self.activeWorkspace() orelse return;
    ws.setDefaultCwd(if (cwd.len > 0) cwd else null) catch |err| {
        std.log.err("app: setWorkspaceDefaultCwd failed: {s}", .{@errorName(err)});
    };
}

// ============================================================
// Tab title/metadata operations
// ============================================================

pub fn tabTitle(self: *App, index: usize) []const u8 {
    if (self.mux) |*mux| {
        if (mux.activeWorkspace()) |ws| {
            if (index < ws.tabs.items.len) {
                const tab = ws.tabs.items[index];
                if (tab.activePane()) |pane| {
                    if (pane.title.len > 0) return pane.title;
                }
            }
        }
    }
    return self.config.windowTitle();
}

pub fn tabIndexById(self: *App, tab_id: usize) ?usize {
    const ws = self.activeWorkspace() orelse return null;
    for (ws.tabs.items, 0..) |tab, index| {
        if (tab.id == tab_id) return index;
    }
    return null;
}

pub fn activeTabIndex(self: *App) usize {
    if (self.mux) |*mux| return mux.activeTabIndex();
    return 0;
}

pub fn switchTab(self: *App, index: usize) void {
    if (self.mux) |*mux| {
        const previous = mux.activePane();
        mux.switchTab(index);
        self.syncActivePaneChange(previous, mux.activePane());
        self.refreshActivePaneDisplay();
        if (mux.activeTab()) |tab| self.emitLuaBuiltInEvent("term:tab_activated", .{ .tab_id = tab.id });
        self.requestLayoutRefresh();
    }
}

pub fn setTabTitle(self: *App, title: []const u8) void {
    const pane = self.activePane() orelse return;
    pane.setManualTitle(title);
}

pub fn setTabTitleById(self: *App, tab_id: usize, title: []const u8) bool {
    const tab = self.tabById(tab_id) orelse return false;
    const pane = tab.activePane() orelse return false;
    pane.setManualTitle(title);
    return true;
}

// ============================================================
// Cleanup
// ============================================================

pub fn cleanupDeadPanes(self: *App, runtime: *GhosttyRuntime) void {
    const mux = if (self.mux) |*m| m else return;
    var has_dead = false;
    var panes = mux.paneIterator();
    while (panes.next()) |pane| {
        if (!pane.hasLiveChildForCleanup()) {
            has_dead = true;
            break;
        }
    }
    if (!has_dead) return;

    const should_quit = mux.closeDeadPanes(runtime);
    if (should_quit) {
        quitOnWorkspaceRemoved(self, mux, "app: last pane closed (early cleanup), quitting");
        return;
    }
    emitWorkspaceClosedIfRemoved(self, mux);
    if (mux.activePane()) |active| {
        runtime.registerCallbacks(active.terminal, terminal_callbacks.terminalCallbacks());
    }
    self.emitLuaBuiltInEvent("workspace:changed", .{ .workspace_index = mux.activeWorkspaceIndex() });
    if (mux.activeTab()) |tab| {
        self.emitLuaBuiltInEvent("term:tab_activated", .{ .tab_id = tab.id });
    }
    self.requestLayoutResize(false);
    self.pending_split_ratio_node = null;
    self.pending_post_split_snap = null;
}

// ============================================================
// Standalone helpers (not on App struct)
// ============================================================

fn sendSplitPaneCommand(self: *App, pane: *Pane, command: []const u8, close_on_exit: bool) void {
    if (!close_on_exit) {
        pane.sendText(command);
        if (!std.mem.endsWith(u8, command, "\r") and !std.mem.endsWith(u8, command, "\n")) {
            pane.sendText("\r");
        }
        return;
    }

    const wrapped = wrapCommandForCloseOnExit(self, pane, command) catch |err| {
        std.log.err("app: failed to wrap split command for close_on_exit: {s}", .{@errorName(err)});
        pane.sendText(command);
        if (!std.mem.endsWith(u8, command, "\r") and !std.mem.endsWith(u8, command, "\n")) {
            pane.sendText("\r");
        }
        return;
    };
    defer self.allocator.free(wrapped);
    pane.sendText(wrapped);
    pane.sendText("\r");
}

fn wrapCommandForCloseOnExit(self: *App, pane: *Pane, command: []const u8) ![]u8 {
    const trimmed = std.mem.trimRight(u8, command, "\r\n");
    const is_windows_domain = pane.domain_name.len > 0 and !std.mem.eql(u8, pane.domain_name, "wsl") and !std.mem.eql(u8, pane.domain_name, "unix");

    if (is_windows_domain) {
        return std.fmt.allocPrint(self.allocator, "{s} & exit", .{trimmed});
    }

    return std.fmt.allocPrint(self.allocator, "{s}; exit", .{trimmed});
}
