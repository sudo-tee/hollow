const std = @import("std");
const builtin = @import("builtin");
const ghostty = @import("../term/ghostty.zig");
const c = @import("sokol_c");
const text_helpers = @import("text_helpers.zig");
const selection_mod = @import("selection.zig");
const selection = @import("../selection.zig");
const copy_mode = @import("copy_mode.zig");
const quick_select = @import("quick_select.zig");
const hyperlinks = @import("hyperlinks.zig");
const scroll_mod = @import("scroll.zig");
const mux_ops = @import("session_controller.zig");
const cmd_ipc = @import("command_dispatcher.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Pane = @import("../pane.zig").Pane;
const SplitDirection = @import("../mux.zig").SplitDirection;
const FocusDirection = @import("../mux.zig").FocusDirection;
const SplitNode = @import("../mux.zig").SplitNode;
const HoveredHyperlink = hyperlinks.HoveredHyperlink;
const CopyModeMoveKind = app_mod.CopyModeMoveKind;
const PromptJumpDir = app_mod.PromptJumpDir;
const SplitCommandMode = app_mod.SplitCommandMode;
const command_mod = @import("../command.zig");
const MAX_LAYOUT_LEAVES = @import("../mux.zig").MAX_LAYOUT_LEAVES;
const LayoutLeaf = @import("../mux.zig").LayoutLeaf;
const PaneBounds = @import("../mux.zig").PaneBounds;

const CLIPBOARD_EVENT_MAX = 8192;

/// An event captured on the sokol event thread, to be dispatched
/// on the frame thread inside tick() to avoid data races into the ghostty DLL.
/// Covers both mouse/focus events and key/char events so ALL DLL calls are
/// serialised through tick() on the frame thread.
pub const PendingInputEvent = union(enum) {
    none,
    /// A button press or release.
    button: struct {
        action: ghostty.MouseAction,
        button: ghostty.MouseButton,
        x: f32,
        y: f32,
        mods: u32,
    },
    /// A mouse-motion event (button may be null for hover).
    motion: struct {
        held_button: ?ghostty.MouseButton,
        x: f32,
        y: f32,
        mods: u32,
    },
    /// A scroll delta (raw float, accumulated in scrollFloat on frame thread).
    scroll: struct {
        x: f32,
        y: f32,
        raw_delta: f32,
        mods: u32,
    },
    /// Switch to a specific tab index (calls runtime.registerCallbacks on frame thread).
    switch_tab: usize,
    /// Close a specific tab index without focusing it first.
    close_tab_at: usize,
    new_tab: struct {
        domain_name: ?[]const u8,
        command: ?[]const u8,
        callback_ref: c_int,
    },
    close_tab,
    close_pane,
    close_pane_by_id: usize,
    focus_pane_by_id: usize,
    command_request: command_mod.Request,
    reload_config,
    next_tab,
    prev_tab,
    new_workspace: struct {
        cwd: ?[]const u8,
        domain_name: ?[]const u8,
        command: ?[]const u8,
        name: ?[]const u8,
        callback_ref: c_int,
        queued_at_ms: i64,
    },
    close_workspace: ?usize,
    next_workspace,
    prev_workspace,
    switch_workspace: usize,
    move_tab_to_workspace: struct {
        tab_id: usize,
        workspace_index: usize,
    },
    move_pane_to_workspace: struct {
        pane_id: usize,
        workspace_index: usize,
    },
    set_workspace_name: []const u8,
    set_workspace_default_cwd: []const u8,
    split_pane: struct {
        direction: SplitDirection,
        ratio: f32,
        domain_name: ?[]const u8,
        cwd: ?[]const u8,
        command: ?[]const u8,
        command_mode: SplitCommandMode,
        close_on_exit: bool,
        floating: bool,
        fullscreen: bool,
        x: ?f32,
        y: ?f32,
        width: ?f32,
        height: ?f32,
        callback_ref: c_int,
    },
    toggle_pane_maximized: struct {
        pane_id: usize,
        show_background: bool,
    },
    set_pane_floating: struct {
        pane_id: usize,
        floating: bool,
    },
    set_floating_pane_bounds: struct {
        pane_id: usize,
        x: f32,
        y: f32,
        width: f32,
        height: f32,
    },
    move_pane: struct {
        pane_id: usize,
        direction: FocusDirection,
        amount: f32,
    },
    focus_pane: FocusDirection,
    resize_pane: struct {
        direction: SplitDirection,
        delta: f32,
    },
    /// Update top-bar hover state computed on the event thread.
    hover: struct {
        tab_index: ?usize,
        close_tab_index: ?usize,
    },
    /// Apply a divider drag ratio on the frame thread.
    divider_ratio: struct {
        node: *SplitNode,
        ratio: f32,
    },
    divider_commit,
    /// Focus gained (true) or lost (false) — calls runtime.encodeFocus on frame thread.
    focus: bool,
    /// A key event (calls app.sendKey on frame thread).
    key: struct {
        key: ghostty.Key,
        mods: u32,
        action: ghostty.KeyAction,
    },
    /// A printable character from a CHAR event (calls app.sendText on frame thread).
    /// Stored as a small UTF-8 byte array; len==0 means empty/invalid.
    char: struct {
        bytes: [5]u8,
        len: u8,
    },
    selection_begin: struct {
        pane: *Pane,
        point: selection.CellPoint,
        extend: bool,
    },
    /// Double-click: expand selection to the word containing `point`.
    selection_begin_word: struct {
        pane: *Pane,
        point: selection.CellPoint,
    },
    /// Triple-click: select the entire row containing `point`.
    selection_begin_line: struct {
        pane: *Pane,
        point: selection.CellPoint,
    },
    selection_update: struct {
        pane: *Pane,
        point: selection.CellPoint,
    },
    selection_end,
    clear_selection,
    copy_selection,
    paste_clipboard,
    paste: struct {
        bytes: [CLIPBOARD_EVENT_MAX]u8,
        len: u16,
    },
    scroll_pane_delta: struct {
        pane: *Pane,
        delta: isize,
    },
    scroll_pane_target: struct {
        pane: *Pane,
        top_row: u64,
    },
    scroll_active_delta: isize,
    scroll_active_page: isize,
    scroll_active_top,
    scroll_active_bottom,
    prompt_jump: PromptJumpDir,
    copy_mode_enter,
    copy_mode_exit,
    copy_mode_move: struct {
        kind: CopyModeMoveKind,
        extend: bool,
    },
    copy_mode_begin_selection: bool,
    copy_mode_clear_selection,
    copy_mode_copy,
    copy_mode_open_search,
    copy_mode_search_set_query: []u8,
    copy_mode_search_next,
    copy_mode_search_prev,
    quick_select_start: quick_select.Action,
    quick_select_input: quick_select.Input,
    open_hyperlink: struct {
        pane: *Pane,
        point: selection.CellPoint,
    },
};

pub fn deinitPendingInputEvent(allocator: std.mem.Allocator, event: *PendingInputEvent) void {
    switch (event.*) {
        .new_tab => |payload| {
            if (payload.domain_name) |value| allocator.free(value);
            if (payload.command) |value| allocator.free(value);
        },
        .command_request => |*request| request.deinit(allocator),
        .new_workspace => |payload| {
            if (payload.cwd) |value| allocator.free(value);
            if (payload.domain_name) |value| allocator.free(value);
            if (payload.command) |value| allocator.free(value);
            if (payload.name) |value| allocator.free(value);
        },
        .set_workspace_name, .set_workspace_default_cwd => |value| allocator.free(value),
        .split_pane => |payload| {
            if (payload.domain_name) |value| allocator.free(value);
            if (payload.cwd) |value| allocator.free(value);
            if (payload.command) |value| allocator.free(value);
        },
        .copy_mode_search_set_query => |value| allocator.free(value),
        else => {},
    }
    event.* = .none;
}

pub fn deinitInputQueue(self: *App) void {
    while (self.action_queue.pop()) |queued| {
        var event = queued;
        if (self.lua) |*lua| switch (event) {
            .new_tab => |payload| lua.discardOperationCallback(payload.callback_ref),
            .new_workspace => |payload| lua.discardOperationCallback(payload.callback_ref),
            .split_pane => |payload| lua.discardOperationCallback(payload.callback_ref),
            else => {},
        };
        deinitPendingInputEvent(self.allocator, &event);
    }
}

/// Drain all pending events and dispatch them.  Called from tick()
/// on the frame thread, where it is safe to call into the ghostty DLL.
pub fn processInputQueue(self: *App) void {
    var processed_event = false;
    while (self.action_queue.pop()) |queued| {
        processed_event = true;
        var ev = queued;
        defer deinitPendingInputEvent(self.allocator, &ev);

        switch (ev) {
            .none => {},
            .button => |b| {
                recordPointerState(self, b.x, b.y, b.mods);
                _ = sendMouse(self, b.action, b.button, b.x, b.y, b.mods) catch false;
            },
            .motion => |m| {
                recordPointerState(self, m.x, m.y, m.mods);
                _ = sendMouse(self, .motion, m.held_button, m.x, m.y, m.mods) catch false;
            },
            .scroll => |s| {
                recordPointerState(self, s.x, s.y, s.mods);
                scrollFloat(self, s.x, s.y, s.raw_delta, s.mods);
            },
            .switch_tab => |idx| {
                mux_ops.switchTab(self, idx);
            },
            .close_tab_at => |idx| {
                mux_ops.closeTabAt(self, idx);
            },
            .new_tab => |payload| {
                mux_ops.newTab(self, payload.domain_name, payload.command, payload.callback_ref);
            },
            .close_tab => {
                mux_ops.closeTab(
                    self,
                );
            },
            .close_pane => {
                mux_ops.closeActivePane(
                    self,
                );
            },
            .close_pane_by_id => |pane_id| {
                mux_ops.closePaneById(self, pane_id);
            },
            .focus_pane_by_id => |pane_id| {
                mux_ops.focusPaneById(self, pane_id);
            },
            .command_request => |request| {
                _ = cmd_ipc.executeCommand(self, request) catch |err| {
                    std.log.err("command-ipc: deferred command failed: {s}", .{@errorName(err)});
                };
            },
            .reload_config => {
                _ = self.reloadConfig();
            },
            .next_tab => {
                mux_ops.nextTab(
                    self,
                );
            },
            .prev_tab => {
                mux_ops.prevTab(
                    self,
                );
            },
            .new_workspace => |payload| {
                std.log.info("app: new_workspace dispatch_lag_ms={d}", .{std.time.milliTimestamp() - payload.queued_at_ms});
                mux_ops.newWorkspace(self, payload.cwd, payload.domain_name, payload.command, payload.name, payload.callback_ref);
            },
            .close_workspace => |idx| {
                mux_ops.closeWorkspace(self, idx);
            },
            .next_workspace => {
                mux_ops.nextWorkspace(
                    self,
                );
            },
            .prev_workspace => {
                mux_ops.prevWorkspace(
                    self,
                );
            },
            .switch_workspace => |idx| {
                mux_ops.switchWorkspace(self, idx);
            },
            .move_tab_to_workspace => |mev| {
                mux_ops.moveTabToWorkspace(self, mev.tab_id, mev.workspace_index);
            },
            .move_pane_to_workspace => |mev| {
                mux_ops.movePaneToWorkspace(self, mev.pane_id, mev.workspace_index);
            },
            .set_workspace_name => |name| {
                mux_ops.setWorkspaceName(self, name);
            },
            .set_workspace_default_cwd => |cwd| {
                mux_ops.setWorkspaceDefaultCwd(self, cwd);
            },
            .split_pane => |split| {
                mux_ops.splitPane(self, split.direction, split.ratio, split.domain_name, split.cwd, split.command, split.command_mode, split.close_on_exit, split.floating, split.fullscreen, split.x, split.y, split.width, split.height, split.callback_ref);
            },
            .toggle_pane_maximized => |maximize| {
                mux_ops.togglePaneMaximizedById(self, maximize.pane_id, maximize.show_background);
            },
            .set_pane_floating => |floating| {
                mux_ops.setPaneFloatingById(self, floating.pane_id, floating.floating);
            },
            .set_floating_pane_bounds => |floating| {
                mux_ops.setFloatingPaneBoundsById(self, floating.pane_id, floating.x, floating.y, floating.width, floating.height);
            },
            .move_pane => |move_ev| {
                mux_ops.movePaneById(self, move_ev.pane_id, move_ev.direction, move_ev.amount);
            },
            .focus_pane => |direction| {
                mux_ops.focusPane(self, direction);
            },
            .resize_pane => |resize_ev| {
                mux_ops.resizePane(self, resize_ev.direction, resize_ev.delta);
            },
            .hover => |hover| {
                self.hovered_tab_index = hover.tab_index;
                self.hovered_close_tab_index = hover.close_tab_index;
            },
            .divider_ratio => |drag| {
                if (self.isSplitNodeValid(drag.node)) {
                    self.previewSplitNodeRatio(drag.node, drag.ratio);
                }
            },
            .divider_commit => {
                self.requestLayoutResize(false);
            },
            .focus => |gained| {
                self.sendFocus(gained) catch {};
                self.emitLuaBuiltInEvent(if (gained) "window:focused" else "window:blurred", .none);
            },
            .key => |k| {
                var text: ?[]const u8 = null;
                var fallback_buf: [4]u8 = undefined;
                var paired_char: ?PendingInputEvent = null;
                defer if (paired_char) |*event| deinitPendingInputEvent(self.allocator, event);
                if (k.action != .release) {
                    paired_char = self.action_queue.popIfChar();
                    if (paired_char) |*event| {
                        switch (event.*) {
                            .char => |*ch| {
                                if (ch.len > 0) text = ch.bytes[0..ch.len];
                            },
                            else => unreachable,
                        }
                    }
                }

                const printable_fallback = text_helpers.legacyPrintableKeyText(k.key, k.mods, &fallback_buf);
                if (!(self.sendKey(k.key, k.mods, k.action, text) catch false)) {
                    if (printable_fallback == null) {
                        if (text) |bytes| mux_ops.sendText(self, bytes);
                    }
                }
            },
            .char => |ch| {
                if (ch.len > 0) mux_ops.sendText(self, ch.bytes[0..ch.len]);
            },
            .selection_begin => |sel| {
                selection_mod.selectionBegin(self, sel.pane, sel.point, sel.extend);
            },
            .selection_begin_word => |sel| {
                selection_mod.selectionBeginWord(self, sel.pane, sel.point);
            },
            .selection_begin_line => |sel| {
                selection_mod.selectionBeginLine(self, sel.pane, sel.point);
            },
            .selection_update => |sel| {
                selection_mod.selectionUpdate(self, sel.pane, sel.point);
            },
            .selection_end => {
                selection_mod.selectionEnd(self);
            },
            .clear_selection => {
                selection_mod.clearSelection(self);
            },
            .copy_selection => {
                selection_mod.copySelectionToClipboard(self) catch |err| {
                    std.log.err("copy selection failed: {s}", .{@errorName(err)});
                };
            },
            .paste_clipboard => {
                self.pasteClipboard() catch |err| {
                    std.log.err("paste clipboard failed: {s}", .{@errorName(err)});
                };
            },
            .paste => |paste| {
                if (paste.len > 0) {
                    mux_ops.sendPaste(self, paste.bytes[0..paste.len]) catch |err| {
                        std.log.err("paste failed: {s}", .{@errorName(err)});
                    };
                }
            },
            .scroll_pane_delta => |scroll_ev| {
                if (self.hasPane(scroll_ev.pane)) {
                    if (self.copy_mode_active and self.copy_mode_pane == scroll_ev.pane) {
                        copy_mode.copyModeScrollDelta(self, scroll_ev.delta);
                    } else {
                        scroll_mod.scrollPaneViewport(self, scroll_ev.pane, scroll_ev.delta);
                    }
                }
            },
            .scroll_pane_target => |scroll_ev| {
                if (self.hasPane(scroll_ev.pane)) {
                    if (self.copy_mode_active and self.copy_mode_pane == scroll_ev.pane) {
                        copy_mode.copyModeScrollToRow(self, scroll_ev.top_row);
                    } else {
                        scroll_mod.scrollPaneViewportToRow(self, scroll_ev.pane, scroll_ev.top_row);
                    }
                }
            },
            .scroll_active_delta => |delta| {
                if (self.copy_mode_active) {
                    copy_mode.copyModeScrollDelta(self, delta);
                } else {
                    scrollActiveViewport(self, delta);
                }
            },
            .scroll_active_page => |pages| {
                if (self.copy_mode_active) {
                    if (self.copy_mode_pane) |pane| {
                        copy_mode.copyModeScrollDelta(self, pages * scroll_mod.pageScrollRows(pane));
                    }
                } else {
                    mux_ops.scrollActiveViewportPage(self, pages);
                }
            },
            .scroll_active_top => {
                if (self.copy_mode_active) {
                    copy_mode.copyModeScrollToRow(self, 0);
                } else {
                    mux_ops.scrollActiveViewportTop(
                        self,
                    );
                }
            },
            .scroll_active_bottom => {
                if (self.copy_mode_active) {
                    copy_mode.copyModeScrollToBottom(self);
                } else {
                    mux_ops.scrollActiveViewportBottom(
                        self,
                    );
                }
            },
            .prompt_jump => |dir| {
                if (self.copy_mode_active) {
                    copy_mode.copyModePromptJump(self, dir);
                } else {
                    copy_mode.handlePromptJump(self, dir);
                }
            },
            .copy_mode_enter => {
                copy_mode.enterCopyMode(self);
            },
            .copy_mode_exit => {
                copy_mode.exitCopyMode(self);
            },
            .copy_mode_move => |move| {
                copy_mode.copyModeMove(self, move.kind, move.extend);
            },
            .copy_mode_begin_selection => |block| {
                copy_mode.copyModeBeginSelectionWithBlock(self, block);
            },
            .copy_mode_clear_selection => {
                copy_mode.copyModeClearSelection(self);
            },
            .copy_mode_copy => {
                copy_mode.copyModeCopy(self) catch |err| {
                    std.log.err("copy mode copy failed: {s}", .{@errorName(err)});
                };
            },
            .copy_mode_open_search => {
                self.emitLuaBuiltInEvent("copy_mode:search_requested", .none);
            },
            .copy_mode_search_set_query => |query| {
                copy_mode.copyModeSetSearchQuery(self, query) catch |err| {
                    std.log.err("copy mode search query failed: {s}", .{@errorName(err)});
                };
            },
            .copy_mode_search_next => {
                copy_mode.copyModeJumpMatch(self, true);
            },
            .copy_mode_search_prev => {
                copy_mode.copyModeJumpMatch(self, false);
            },
            .quick_select_start => |action| {
                quick_select.start(self, action);
            },
            .quick_select_input => |value| {
                quick_select.handleInput(self, value);
            },
            .open_hyperlink => |open_ev| {
                if (self.hasPane(open_ev.pane)) hyperlinks.openHyperlinkAt(self, open_ev.pane, open_ev.point);
            },
        }
    }

    if (processed_event) self.markAutomationChanged();

    cmd_ipc.drainPendingCommand(self);
}

pub fn hasVisualActivityAt(self: *App, now_ns: i128, check_panes: bool) bool {
    const recent_input_grace_ns: i128 = 24_000_000;
    const recent_visual_grace_ns: i128 = 16_000_000;
    if (self.last_input_activity_ns != 0 and now_ns - self.last_input_activity_ns < recent_input_grace_ns) {
        return true;
    }
    if (self.last_visual_activity_ns != 0 and now_ns - self.last_visual_activity_ns < recent_visual_grace_ns) {
        return true;
    }
    if (self.pending_resize or self.pending_layout_resize or self.pending_drag_layout_resize or self.pending_quit) {
        self.last_visual_activity_ns = now_ns;
        return true;
    }
    if (!self.action_queue.isEmpty()) {
        self.last_visual_activity_ns = now_ns;
        return true;
    }
    if (self.htp_pending_message_head < self.htp_pending_messages.items.len) {
        self.last_visual_activity_ns = now_ns;
        return true;
    }
    if (self.quick_select_active or self.selection_drag_active or self.hovered_tab_index != null or self.hovered_close_tab_index != null) {
        self.last_visual_activity_ns = now_ns;
        return true;
    }
    if (leaderVisualActive(self, now_ns)) {
        self.last_visual_activity_ns = now_ns;
        return true;
    }
    if (self.startup_command != null and !self.startup_command_sent and self.frame_count >= self.startup_command_delay_frames) {
        self.last_visual_activity_ns = now_ns;
        return true;
    }
    if (self.barCacheNeedsRefresh(.topbar, now_ns) or self.barCacheNeedsRefresh(.bottombar, now_ns)) {
        self.last_visual_activity_ns = now_ns;
        return true;
    }
    if (self.next_idle_render_poll_ns != 0 and now_ns >= self.next_idle_render_poll_ns) {
        self.last_visual_activity_ns = now_ns;
        return true;
    }
    if (check_panes) {
        if (self.mux) |*mux| {
            var panes = mux.paneIterator();
            while (panes.next()) |pane| {
                if (pane.render_dirty != .false_value or pane.pty_received_data or pane.pty_wrote_this_frame or pane.title_dirty or pane.cwd_dirty or pane.bell_dirty or pane.bell_active) {
                    self.last_visual_activity_ns = now_ns;
                    return true;
                }
            }
        }
    }
    return false;
}

fn leaderVisualActive(self: *App, now_ns: i128) bool {
    if (!self.leader_visual_active) return false;
    if (self.leader_visual_expires_at_ns != 0 and now_ns > self.leader_visual_expires_at_ns) {
        self.leader_visual_active = false;
        self.leader_visual_expires_at_ns = 0;
        return false;
    }
    return true;
}

pub fn signalWake(self: *App) void {
    _ = self.wake_generation.fetchAdd(1, .release);
    std.Thread.Futex.wake(&self.wake_generation, 1);
    self.last_visual_activity_ns = std.time.nanoTimestamp();
}

pub fn currentWakeGeneration(self: *const App) u32 {
    return self.wake_generation.load(.acquire);
}

pub fn minWakeNs(current: i128, candidate: i128) i128 {
    if (candidate == 0) return current;
    if (current == 0 or candidate < current) return candidate;
    return current;
}

fn recordPointerState(self: *App, x: f32, y: f32, mods: u32) void {
    if (self.pointer_x != x or self.pointer_y != y) self.hover_probe_dirty = true;
    self.pointer_x = x;
    self.pointer_y = y;
    self.pointer_mods = mods;
}

pub fn hoveredHyperlinkAtPointer(self: *App) ?struct {
    pane: *Pane,
    point: selection.CellPoint,
} {
    const hovered = self.hovered_hyperlink orelse return null;
    if (self.hitTestPane(self.pointer_x, self.pointer_y)) |hit| {
        if (hit.pane != hovered.pane) return null;
        const point = selection_mod.cellPointFromPaneLocal(self, hit.pane, hit.x, hit.y);
        if (point.row != hovered.row or point.col < hovered.start_col or point.col >= hovered.end_col) return null;
        return .{ .pane = hit.pane, .point = point };
    }
    return null;
}

fn encodeMouseForPane(self: *App, pane: *Pane, action: ghostty.MouseAction, button: ?ghostty.MouseButton, x: f32, y: f32, mods: u32) !bool {
    const runtime = if (self.ghostty) |*rt| rt else return false;
    runtime.setMouseEncoderAnyButtonPressed(pane.mouse_encoder, action != .release and button != null);

    var buf: [64]u8 = undefined;
    const bytes = runtime.encodeMouse(
        pane.mouse_encoder,
        pane.mouse_event,
        action,
        button,
        mods,
        .{
            .x = x,
            .y = y,
        },
        &buf,
    ) orelse return false;
    pane.sendText(bytes);
    return true;
}

pub fn sendMouse(self: *App, action: ghostty.MouseAction, button: ?ghostty.MouseButton, x: f32, y: f32, mods: u32) !bool {
    const hit = self.hitTestPane(x, y) orelse return false;
    if (action == .press) {
        if (self.mux) |*mux| {
            const was_active = mux.activePane();
            mux.setActivePane(hit.pane);
            self.syncActivePaneChange(was_active, hit.pane);
        }
    }
    return try encodeMouseForPane(
        self,
        hit.pane,
        action,
        button,
        x - @as(f32, @floatFromInt(hit.pane.x_px)),
        y - @as(f32, @floatFromInt(hit.pane.y_px)),
        mods,
    );
}

pub fn hitTestScrollbar(self: *App, x: f32, y: f32) ?App.ScrollbarMetrics {
    var layout_buf: [MAX_LAYOUT_LEAVES]LayoutLeaf = undefined;
    const leaves = self.computeActiveLayout(&layout_buf);
    var i = leaves.len;
    while (i > 0) {
        i -= 1;
        const leaf = leaves[i];
        const metrics = scroll_mod.paneScrollbarMetrics(self, leaf.pane, leaf.bounds) orelse continue;
        if (x >= metrics.track_x and x < metrics.track_x + metrics.track_w and y >= metrics.track_y and y < metrics.track_y + metrics.track_h) {
            return metrics;
        }
    }

    if (self.activePane()) |pane| {
        if (scroll_mod.scrollbarMetricsForPane(self, pane)) |metrics| {
            if (x >= metrics.track_x and x < metrics.track_x + metrics.track_w and y >= metrics.track_y and y < metrics.track_y + metrics.track_h) {
                return metrics;
            }
        }
    }

    return null;
}

pub fn scroll(self: *App, x: f32, y: f32, delta: isize, mods: u32) void {
    const hit = self.hitTestPane(x, y) orelse return;
    if (self.copy_mode_active and self.copy_mode_pane == hit.pane) {
        if (hitTestScrollbar(self, x, y)) |metrics| {
            const ratio = std.math.clamp((y - metrics.track_y) / metrics.track_h, 0.0, 1.0);
            const runtime = if (self.ghostty) |*rt| rt else return;
            const scrollbar = scroll_mod.refreshPaneScrollbar(self, runtime, hit.pane);
            const max_top: usize = @intCast(scroll_mod.scrollbarMaxTopRow(scrollbar));
            const target = @as(u64, @intFromFloat(@round(ratio * @as(f32, @floatFromInt(max_top)))));
            copy_mode.copyModeScrollToRow(self, target);
        } else {
            copy_mode.copyModeScrollDelta(self, delta);
        }
        return;
    }
    const runtime = if (self.ghostty) |*rt| rt else return;
    const scrollbar = scroll_mod.refreshPaneScrollbar(self, runtime, hit.pane);
    const max_top = scroll_mod.scrollbarMaxTopRow(scrollbar);
    const in_scrollback = scroll_mod.scrollbarTopRow(scrollbar) < max_top;
    const over_scrollbar = hitTestScrollbar(self, x, y) != null;
    const should_scroll_viewport = in_scrollback or over_scrollbar or hit.pane.last_mouse_tracking == 0;

    if (should_scroll_viewport) {
        scroll_mod.scrollPaneViewport(self, hit.pane, delta);
        return;
    }

    const count: usize = @intCast(if (delta < 0) -delta else delta);
    if (count > 0) {
        const button: ghostty.MouseButton = if (delta < 0) .four else .five;
        const pane_x = x - @as(f32, @floatFromInt(hit.pane.x_px));
        const pane_y = y - @as(f32, @floatFromInt(hit.pane.y_px));
        if (encodeMouseForPane(self, hit.pane, .press, button, pane_x, pane_y, mods) catch false) {
            var i: usize = 1;
            while (i < count) : (i += 1) {
                _ = encodeMouseForPane(self, hit.pane, .press, button, pane_x, pane_y, mods) catch false;
            }
            return;
        }
    }
    scroll_mod.scrollPaneViewport(self, hit.pane, delta);
}

pub fn scrollFloat(self: *App, x: f32, y: f32, raw_delta: f32, mods: u32) void {
    self.scroll_accum += raw_delta * self.config.scroll_multiplier;
    const steps = @as(isize, @intFromFloat(self.scroll_accum));
    if (steps != 0) {
        self.scroll_accum -= @as(f32, @floatFromInt(steps));
        scroll(self, x, y, steps, mods);
    }
}

fn scrollActiveViewport(self: *App, delta: isize) void {
    const pane = self.activePane() orelse return;
    scroll_mod.scrollPaneViewport(self, pane, delta);
}
