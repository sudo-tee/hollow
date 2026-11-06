const std = @import("std");
const notification = @import("../notification.zig");
const io = @import("../io.zig");
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
const PaneEdge = @import("../mux.zig").PaneEdge;
const DockScope = @import("../mux.zig").DockScope;
const FocusDirection = @import("../mux.zig").FocusDirection;
const LayoutLeaf = @import("../mux.zig").LayoutLeaf;
const PaneBounds = @import("../mux.zig").PaneBounds;
const MAX_LAYOUT_LEAVES = @import("../mux.zig").MAX_LAYOUT_LEAVES;
const SplitCommandMode = app_mod.SplitCommandMode;
const Pane = @import("../pane.zig").Pane;
const LaunchCommand = @import("../pty/launch_command.zig").LaunchCommand;
const pane_lifecycle = @import("pane_lifecycle.zig");
const SessionController = @import("../session/controller.zig").Controller;
const SessionTransport = @import("../session/transport.zig");
const SessionConnection = SessionTransport.Connection;
const SessionProtocol = @import("../agent/session_protocol.zig");
const p = SessionTransport.p;

fn wakeApp(context: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(context));
    app.signalWake();
}

/// Create a session bridge whose worker wakes the GUI when frames arrive.
/// Connection ownership transfers to App only after addSessionWorkspace succeeds.
pub fn createSessionConnection(self: *App, options: SessionTransport.Options) !*SessionConnection {
    var session_options = options;
    session_options.wake = .{ .context = self, .callback = wakeApp };
    return SessionConnection.create(self.allocator, io.get(), session_options);
}

/// Publish an already attached owner session as a workspace. On success App
/// owns the controller and connection; on failure the caller retains connection.
pub fn addSessionWorkspace(self: *App, connection: *SessionConnection, info: SessionProtocol.SessionInfo, domain: ?[]const u8) !*Workspace {
    return addSessionWorkspaceNamed(self, connection, info, domain, null);
}

pub fn addSessionWorkspaceNamed(self: *App, connection: *SessionConnection, info: SessionProtocol.SessionInfo, domain: ?[]const u8, name: ?[]const u8) !*Workspace {
    const was_suppressed = self.session_layout_suppressed;
    self.session_layout_suppressed = true;
    defer self.session_layout_suppressed = was_suppressed;
    const mux = if (self.mux) |*value| value else return error.MuxUnavailable;
    const runtime = if (self.ghostty) |*value| value else return error.TerminalUnavailable;
    const status = connection.status();
    if (status.phase != .ready or status.format == null) return error.SessionNotReady;
    if (info.id.len == 0) return error.InvalidSession;

    try self.session_controllers.ensureUnusedCapacity(self.allocator, 1);
    const controller = try self.allocator.create(SessionController);
    controller.* = SessionController.init(self.allocator, connection);
    errdefer {
        self.allocator.free(controller.session_id);
        self.allocator.free(controller.host);
        self.allocator.destroy(controller);
    }
    controller.session_id = try self.allocator.dupe(u8, info.id);
    var host_buf: [SessionProtocol.max_host_len]u8 = undefined;
    controller.host = try self.allocator.dupe(u8, connection.host(&host_buf));
    controller.generation = connection.attachmentGeneration();
    controller.revision = info.revision;

    const previous = mux.activePane();
    const workspace = try mux.addSessionWorkspaceNamed(
        runtime,
        terminal_callbacks.terminalCallbacks(),
        self.config,
        controller,
        info,
        domain,
        @import("session_borrowers.zig").beforeReplace,
        name,
    );
    self.session_controllers.appendAssumeCapacity(controller);
    htp.bindHtpHandlers(self);
    self.syncActivePaneChange(previous, mux.activePane());
    self.refreshActivePaneDisplay();
    self.emitLuaBuiltInEvent("workspace:new", .{ .workspace_index = mux.activeWorkspaceIndex() });
    self.emitLuaBuiltInEvent("workspace:changed", .{ .workspace_index = mux.activeWorkspaceIndex() });
    self.requestLayoutResize(false);
    self.requestLayoutRefresh();
    return workspace;
}

/// Detach views first (mux teardown does this), then stop/join transports.
pub fn deinitSessionControllers(self: *App) void {
    for (self.session_controllers.items) |controller| {
        const connection = controller.connection;
        controller.deinit();
        connection.destroy();
        self.allocator.destroy(controller);
    }
    self.session_controllers.deinit(self.allocator);
    self.session_controllers = .empty;
}

/// Dispatch bounded frame batches on the GUI thread. Pane polling runs between
/// passes so full pane queues and snapshot budgets can make progress.
pub fn pumpSessionControllers(self: *App, runtime: *GhosttyRuntime) void {
    @import("session_spawn.zig").pump(self);
    // Control handlers emit Lua, which can append controllers and reallocate
    // this list. Do not retain its backing slice across a handler invocation.
    const count = self.session_controllers.items.len;
    var index: usize = 0;
    while (index < count and index < self.session_controllers.items.len) : (index += 1) {
        const controller = self.session_controllers.items[index];
        controller.reconcile();
        controller.flushCloses() catch |err| {
            std.log.warn("session close admission failed: {s}", .{@errorName(err)});
        };

        var dispatched: usize = 0;
        while (dispatched < 64) : (dispatched += 1) {
            const step = controller.step() catch |err| {
                std.log.err("session controller failed: {s}", .{@errorName(err)});
                self.markAutomationChanged();
                break;
            };
            switch (step) {
                .idle, .blocked => break,
                .dispatched => {},
                .control => |message| {
                    const handled = handleSessionControl(self, runtime, controller, message);
                    message.deinit();
                    if (!handled) break;
                },
            }
        }
        // A bounded batch may leave frames without another network arrival.
        // Close admission also needs a retry after the writer frees capacity.
        if (dispatched == 64 or (controller.close_work and !controller.spawn_active and sessionCanCloseRemotely(controller))) self.signalWake();
        if (controller.layout_failure) |reason| {
            controller.layout_failure = null;
            @import("session_spawn.zig").layoutRejected(self, reason);
        }
    }

    @import("session_spawn.zig").saveLayouts(self);
    retireSessionControllers(self);
}

fn handleSessionControl(self: *App, runtime: *GhosttyRuntime, controller: *SessionController, message: SessionTransport.Message) bool {
    if (message.kind == .reply) {
        if (@import("session_spawn.zig").handle(self, controller, message)) return true;
        const request_id = message.request_id orelse return false;
        if (controller.finishRespawn(request_id)) |pane_id| {
            finishRespawn(self, pane_id, message);
            return true;
        }
        const pane_id = controller.closeTarget(request_id) orelse return false;
        const reply = SessionProtocol.parse(SessionProtocol.Reply, self.allocator, message.payload) catch |err| {
            std.log.err("invalid session close reply: {s}", .{@errorName(err)});
            return true;
        };
        defer reply.deinit();
        if (!reply.value.ok) {
            std.log.warn("session pane close rejected: {s}", .{reply.value.@"error" orelse "unknown error"});
            if (self.mux) |*mux| for (mux.workspaces.items) |workspace| {
                if (workspace.session_controller != controller) continue;
                workspace.session_close_desired = false;
                for (workspace.tabs.items) |tab| for (tab.panes.items) |pane| {
                    if (pane.id == pane_id) tab.close_after_session_ack = false;
                };
                break;
            };
            return true;
        }
        closePaneByIdNow(self, runtime, pane_id);
        controller.layout_dirty = true;
        controller.layout_due_ns = 0;
        self.markAutomationChanged();
        return true;
    }

    if (message.kind == .event) return true;
    return false;
}

fn finishRespawn(self: *App, pane_id: usize, message: SessionTransport.Message) void {
    const reply = SessionProtocol.parse(SessionProtocol.Reply, self.allocator, message.payload) catch |err| {
        std.log.err("invalid session respawn reply: {s}", .{@errorName(err)});
        return;
    };
    defer reply.deinit();
    if (!reply.value.ok) {
        @import("session_spawn.zig").respawnRejected(self, reply.value.@"error");
        return;
    }
    const pane = self.findPaneById(pane_id) orelse return;
    const term = pane.asTerminal() orelse return;
    term.reviveSession(pane);
    self.requestRedraw();
    self.markAutomationChanged();
    self.emitLuaBuiltInEvent("term:pane_respawned", .{ .pane_id = pane.id });
}

/// Restarts the exited process of a persistent pane, keeping its screen.
pub fn respawnPane(self: *App, pane_id: usize) !void {
    const mux = if (self.mux) |*value| value else return error.PaneNotFound;
    const controller = mux.controllerForPane(pane_id) orelse return error.NotSessionPane;
    if (!sessionCanCloseRemotely(controller)) return error.Detached;
    _ = try controller.requestRespawn(pane_id);
    self.signalWake();
}

fn retireSessionControllers(self: *App) void {
    var index: usize = 0;
    while (index < self.session_controllers.items.len) {
        const controller = self.session_controllers.items[index];
        const status = controller.connection.status();
        const in_mux = if (self.mux) |*mux| blk: {
            for (mux.workspaces.items) |workspace| {
                if (workspace.session_controller == controller) break :blk true;
            }
            break :blk false;
        } else false;

        if (in_mux or controller.spawn_active or (controller.hasBindings() and status.phase != .ended)) {
            index += 1;
            continue;
        }
        if (status.phase != .ended) {
            // Closing bridge is nonblocking. Join/free only after its worker
            // reports EOF, never while a GUI frame can wait on network I/O.
            controller.connection.close();
            index += 1;
            continue;
        }

        _ = self.session_controllers.orderedRemove(index);
        const connection = controller.connection;
        controller.deinit();
        connection.destroy();
        self.allocator.destroy(controller);
    }
}

// ============================================================
// Send/text operations
// ============================================================

pub fn sendText(self: *App, text: []const u8) void {
    const pane = self.activePane() orelse return;
    const term = pane.asTerminal() orelse return;
    const now_ns = io.nanoTimestamp();
    self.last_input_activity_ns = now_ns;
    self.last_visual_activity_ns = now_ns;
    term.pty_received_data = true;
    term.pty_wrote_this_frame = true;
    term.last_render_state_update_ns = 0;
    if (self.config.debug_terminal_trace) {
        std.log.info("terminal-trace sendText pane={x} len={d} sample={s}", .{
            pane.id,
            text.len,
            text[0..@min(text.len, 32)],
        });
    }
    scrollActiveViewportBottom(self);
    term.sendUserText(pane.allocator, text);
    self.signalWake();
}

pub fn sendTextToPane(self: *App, pane_id: usize, text: []const u8) bool {
    const pane = self.findPaneById(pane_id) orelse return false;
    const term = pane.asTerminal() orelse return false;
    term.sendUserText(pane.allocator, text);
    self.signalWake();
    return true;
}

pub fn sendBellToPane(self: *App, pane_id: usize, level: ?notification.Level, color: ?ghostty.ColorRgb) bool {
    const pane = self.findPaneById(pane_id) orelse return false;
    pane.bell_flash_color = color orelse if (level) |value| value.color() else null;
    pane.bell_dirty = true;
    self.signalWake();
    return true;
}

pub fn sendKeyToPane(self: *App, pane_id: usize, key_name: []const u8, mods: u32) bool {
    const pane = self.findPaneById(pane_id) orelse return false;
    const term = pane.asTerminal() orelse return false;
    const rt = if (self.ghostty) |*r| r else return false;
    const key = std.meta.stringToEnum(ghostty.Key, key_name) orelse return false;

    var buf: [128]u8 = undefined;
    var text_buf: [4]u8 = undefined;
    const effective_text = text_helpers.legacyPrintableKeyText(key, mods, &text_buf);
    const consumed: u32 = if (effective_text != null and (mods & ghostty.Mods.shift) != 0) ghostty.Mods.shift else ghostty.Mods.none;

    if (term.encodeKey(rt, key, mods, .press, consumed, if (effective_text) |t| text_helpers.firstCodepoint(t) else 0, effective_text, &buf)) |bytes| {
        term.sendUserText(pane.allocator, bytes);
        self.signalWake();
        return true;
    }

    if (effective_text != null and (mods & ghostty.Mods.alt) != 0 and (mods & (ghostty.Mods.ctrl | ghostty.Mods.super)) == 0) {
        term.sendUserText(pane.allocator, "\x1b");
        term.sendUserText(pane.allocator, effective_text.?);
        self.signalWake();
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
    const pane = startupCommandPane(self) orelse return;
    if (self.activePane() == pane) sendText(self, command) else _ = sendTextToPane(self, pane.id, command);
    if (!std.mem.endsWith(u8, command, "\r") and !std.mem.endsWith(u8, command, "\n")) {
        if (self.activePane() == pane) sendText(self, "\r") else _ = sendTextToPane(self, pane.id, "\r");
    }
    self.startup_command_sent = true;
}

pub fn startupCommandHasTarget(self: *App) bool {
    return startupCommandPane(self) != null;
}

fn startupCommandPane(self: *App) ?*Pane {
    const pane = switch (self.startup_session_target) {
        .unbound => self.activePane(),
        .opening, .failed => null,
        .pane => |id| self.findPaneById(id),
    } orelse return null;
    const term = pane.asTerminal() orelse return null;
    if (self.startup_session_target == .pane) {
        if (term.pty) |*pty| if (!pty.isAlive()) return null;
    }
    return pane;
}

pub fn invalidateAllPanes(self: *App) void {
    const mux = if (self.mux) |*m| m else return;
    var panes = mux.paneIterator();
    while (panes.next()) |pane| {
        pane.invalidate();
        if (pane.asTerminal()) |term| term.last_render_state_update_ns = 0;
    }
}

pub fn sendPaste(self: *App, text: []const u8) !void {
    const pane = self.activePane() orelse return;
    const term = pane.asTerminal() orelse return error.NotATerminal;
    const rt = if (self.ghostty) |*r| r else {
        if (self.config.debug_terminal_trace) {
            std.log.info("terminal-trace sendPaste pane={x} len={d} bracketed=false runtime=false", .{ pane.id, text.len });
        }
        sendText(self, text);
        return;
    };
    var output: ghostty.PasteOutput = .{ .allocator = self.allocator };
    defer output.deinit();
    term.paste_output = &output;
    defer term.paste_output = null;
    // Preserve inline/bracketed paste and its safety checks. Installing a read
    // callback would otherwise opt into Kitty mode-5522 paste events, whose
    // follow-up request cannot be serviced asynchronously by this C API.
    rt.setClipboardReadCallback(term.terminal, null);
    defer rt.setClipboardReadCallback(term.terminal, @import("terminal_callbacks.zig").terminalCallbacks().clipboard_read);
    rt.pasteText(term.terminal, text) catch |err| {
        if (err == error.UnsafePaste) {
            try term.osc99_notifications.enqueueSimple(self.allocator, "Paste blocked", "Unsafe terminal paste rejected (unbracketed multiline text or embedded paste terminator).", .warn);
            self.signalWake();
        }
        return err;
    };
    if (output.failure) |err| return err;
    if (output.bytes.items.len > 0) sendText(self, output.bytes.items);
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
    const term = pane.asTerminalConst() orelse return;
    scroll.scrollPaneViewportToRow(self, pane, scroll.scrollbarMaxTopRow(term.scrollbar()));
}

// ============================================================
// Tab operations
// ============================================================

pub fn newTab(self: *App, cwd: ?[]const u8, domain_name: ?[]const u8, command: ?[]const u8, callback_ref: c_int, insert_at_end: bool) void {
    const start_ms = io.milliTimestamp();
    var mux = if (self.mux) |*value| value else return;
    const runtime = if (self.ghostty) |*value| value else return;
    const cbs = terminal_callbacks.terminalCallbacks();
    const previous = mux.activePane();
    const effective_command = nonEmptyCommand(command);
    if (mux.activeWorkspace()) |workspace| if (workspace.session_controller != null) {
        @import("session_spawn.zig").newTab(self, cwd, domain_name, effective_command, callback_ref, insert_at_end) catch |err| {
            @import("session_spawn.zig").reject(self, callback_ref, err);
        };
        return;
    };
    const launch_command: ?LaunchCommand = if (effective_command) |value|
        .{ .command = value }
    else
        null;
    mux.newTab(runtime, cbs, self.config, self.cell_width_px, self.cell_height_px, self.config.window_width, self.config.window_height, cwd, domain_name, launch_command, insert_at_end) catch |err| {
        std.log.err("app: newTab failed: {s} domain={s}", .{ @errorName(err), domain_name orelse "" });
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
    std.log.info("app: newTab total_ms={d}", .{io.milliTimestamp() - start_ms});
    std.log.info("app: created new tab", .{});
}

pub fn emitWorkspaceClosedIfRemoved(self: *App, mux: *Mux) void {
    const name = mux.last_removed_workspace_name;
    mux.last_removed_workspace_name = null;
    defer if (name) |value| self.allocator.free(value);
    const session = mux.takeRemovedSession();
    defer if (session) |value| value.deinit(self.allocator);
    if (name == null and session == null) return;
    self.emitLuaBuiltInEvent("workspace:closed", .{ .workspace_closed = .{
        .name = name,
        .session_id = if (session) |value| value.id else null,
        .session_host = if (session) |value| value.host else null,
        .session_ended = if (session) |value| value.ended else false,
    } });
}

pub fn quitOnWorkspaceRemoved(self: *App, mux: *Mux, log_msg: ?[]const u8) void {
    // Session restore must still learn that the last persistent session ended.
    if (mux.last_removed_session != null) emitWorkspaceClosedIfRemoved(self, mux);
    if (mux.last_removed_workspace_name) |n| self.allocator.free(n);
    mux.last_removed_workspace_name = null;
    if (@import("session_open.zig").hasLiveOpen(self)) return;
    if (log_msg) |msg| std.log.info("{s}", .{msg});
    self.pending_quit = true;
}

pub fn closeTab(self: *App) void {
    var mux = if (self.mux) |*value| value else return;
    const runtime = if (self.ghostty) |*value| value else return;
    if (mux.activeWorkspace()) |workspace| if (sessionCanCloseRemotely(workspace.session_controller)) {
        if (workspace.activeTab()) |tab| scheduleSessionTabClose(self, workspace, tab);
        return;
    };
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
    if (mux.activeWorkspace()) |workspace| if (sessionCanCloseRemotely(workspace.session_controller)) {
        const tab = mux.tabAt(index) orelse return;
        const previous = mux.activePane();
        workspace.active_tab = tab;
        scheduleSessionTabClose(self, workspace, tab);
        self.syncActivePaneChange(previous, mux.activePane());
        self.refreshActivePaneDisplay();
        if (mux.activeTab()) |active| self.emitLuaBuiltInEvent("term:tab_activated", .{ .tab_id = active.id });
        self.requestLayoutRefresh();
        return;
    };
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
    if (mux.activePane()) |pane| {
        if (scheduleSessionPaneClose(self, pane.id)) return;
    }
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
    if (scheduleSessionPaneClose(self, pane_id)) return;
    const runtime = if (self.ghostty) |*value| value else return;
    closePaneByIdNow(self, runtime, pane_id);
}

fn closePaneByIdNow(self: *App, runtime: *GhosttyRuntime, pane_id: usize) void {
    var mux = if (self.mux) |*value| value else return;
    const pending_tab_close = pendingSessionTabCloseForPane(mux, pane_id);
    // Closing the focused pane destroys it before focus synchronization. Only
    // retain the previous pane when it will survive the close operation.
    const previous = if (mux.activePane()) |pane|
        (if (pane.id != pane_id) pane else null)
    else
        null;
    const should_quit = mux.closePaneById(runtime, pane_id);
    if (pending_tab_close) |tab_id| if (mux.tabById(tab_id) == null) {
        self.emitLuaBuiltInEvent("term:tab_closed", .{ .tab_id = tab_id });
    };
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

fn scheduleSessionPaneClose(self: *App, pane_id: usize) bool {
    const mux = if (self.mux) |*value| value else return false;
    const controller = mux.controllerForPane(pane_id) orelse return false;
    if (!sessionCanCloseRemotely(controller)) return false;
    controller.scheduleClose(pane_id) catch |err| {
        std.log.warn("could not schedule persistent pane close: {s}", .{@errorName(err)});
    };
    self.signalWake();
    return true;
}

/// A lost attachment cannot acknowledge owner mutations. Closing its local
/// views is still allowed, and never sends a kill to the new attachment.
fn sessionCanCloseRemotely(controller: ?*SessionController) bool {
    const value = controller orelse return false;
    return !value.detached and value.connection.status().phase != .ended;
}

fn scheduleSessionTabClose(self: *App, workspace: *Workspace, tab: *Tab) void {
    const controller = workspace.session_controller orelse return;
    const mux = if (self.mux) |*value| value else return;
    tab.close_after_session_ack = true;
    for (tab.panes.items) |pane| {
        if (mux.controllerForPane(pane.id) != controller) continue;
        controller.scheduleClose(pane.id) catch |err| {
            std.log.warn("could not schedule persistent pane close: {s}", .{@errorName(err)});
        };
    }
    self.signalWake();
}

fn pendingSessionTabCloseForPane(mux: *Mux, pane_id: usize) ?usize {
    for (mux.workspaces.items) |workspace| for (workspace.tabs.items) |tab| {
        if (!tab.close_after_session_ack) continue;
        for (tab.panes.items) |pane| if (pane.id == pane_id) return tab.id;
    };
    return null;
}

fn scheduleSessionWorkspaceClose(self: *App, workspace: *Workspace) void {
    const controller = workspace.session_controller orelse return;
    workspace.session_close_desired = true;
    var panes = workspace.paneIterator();
    while (panes.next()) |pane| {
        controller.scheduleClose(pane.id) catch |err| {
            if (err != error.PaneNotFound) std.log.warn("could not schedule persistent pane close: {s}", .{@errorName(err)});
        };
    }
    self.signalWake();
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
    const start_ms = io.milliTimestamp();
    std.log.info("app: newWorkspace start_ms={d}", .{start_ms});
    var mux = if (self.mux) |*value| value else return;
    const runtime = if (self.ghostty) |*value| value else return;
    const cbs = terminal_callbacks.terminalCallbacks();
    const previous = mux.activePane();
    const effective_command = nonEmptyCommand(command);
    const inherited_domain = if (domain_name) |value|
        if (value.len > 0) value else null
    else if (previous) |pane|
        if (pane.domainName().len > 0) pane.domainName() else null
    else
        null;
    const inherited_cwd = if (cwd) |value|
        if (value.len > 0) value else null
    else if (previous) |pane|
        if (pane.cwd.len > 0 and std.mem.eql(u8, pane.domainName(), inherited_domain orelse "")) pane.cwd else null
    else
        null;
    if (self.config.persistForDomain(inherited_domain)) {
        _ = @import("session_domain.zig").begin(self, inherited_cwd, inherited_domain, effective_command, name, callback_ref, false) catch |err| {
            std.log.warn("persistent workspace admission failed: {s}", .{@errorName(err)});
            @import("session_open.zig").reportAdmissionFailure(self, err, false);
            if (self.lua) |*lua| lua.invokeOperationCallback(callback_ref, false, .none);
            return;
        };
        return;
    }
    mux.newWorkspace(runtime, cbs, self.config, self.cell_width_px, self.cell_height_px, self.config.window_width, self.config.window_height, inherited_cwd, inherited_domain, null, name) catch |err| {
        std.log.err("app: newWorkspace failed: {s} domain={s}", .{ @errorName(err), inherited_domain orelse "" });
        if (self.lua) |*lua| lua.invokeOperationCallback(callback_ref, false, .none);
        return;
    };
    htp.bindHtpHandlers(self);
    self.syncActivePaneChange(previous, mux.activePane());
    if (effective_command) |value| {
        if (mux.activePane()) |pane| queueStartupInput(pane, value) catch |err| {
            std.log.err("app: failed to queue workspace startup command: {s}", .{@errorName(err)});
        };
    }
    self.emitLuaBuiltInEvent("workspace:new", .{ .workspace_index = mux.activeWorkspaceIndex() });
    self.emitLuaBuiltInEvent("workspace:changed", .{ .workspace_index = mux.activeWorkspaceIndex() });
    self.requestLayoutResize(false);
    if (self.lua) |*lua| lua.invokeOperationCallback(callback_ref, true, .{ .workspace_index = mux.activeWorkspaceIndex() });
    std.log.info("app: newWorkspace total_ms={d}", .{io.milliTimestamp() - start_ms});
    std.log.info("app: created new workspace", .{});
}

pub fn closeWorkspace(self: *App, workspace_id: ?usize) void {
    var mux = if (self.mux) |*value| value else return;
    const runtime = if (self.ghostty) |*value| value else return;
    const target_workspace = if (workspace_id) |target_id|
        mux.workspaceById(target_id)
    else
        mux.activeWorkspace();
    if (target_workspace) |workspace| if (sessionCanCloseRemotely(workspace.session_controller)) {
        scheduleSessionWorkspaceClose(self, workspace);
        return;
    };
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

pub fn splitPane(self: *App, direction: SplitDirection, ratio: f32, domain_name: ?[]const u8, cwd: ?[]const u8, command: ?[]const u8, command_mode: SplitCommandMode, close_on_exit: bool, floating: bool, fullscreen: bool, x: ?f32, y: ?f32, width: ?f32, height: ?f32, callback_ref: c_int, edge: ?PaneEdge, dock: ?DockScope) void {
    const start_ms = io.milliTimestamp();
    var mux = if (self.mux) |*value| value else return;
    if (dock) |scope| {
        const occupied = if (edge) |side| mux.dockOccupant(scope, side) != null else true;
        if (occupied or floating) {
            std.log.warn("app: splitPane dock={s} needs a free edge slot", .{@tagName(scope)});
            if (self.lua) |*lua| lua.invokeOperationCallback(callback_ref, false, .none);
            return;
        }
    }
    const runtime = if (self.ghostty) |*value| value else return;
    const cbs = terminal_callbacks.terminalCallbacks();
    const previous = mux.activePane();
    const effective_command = nonEmptyCommand(command);
    const launch_command: ?LaunchCommand = if (effective_command != null and command_mode == .spawn)
        .{ .command = effective_command.?, .close_on_exit = close_on_exit }
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
    const snapped_ratio = if (edge != null) std.math.clamp(ratio, 0.05, 0.95) else snapSplitRatio(self, ratio, direction, split_bounds);
    if (mux.activeWorkspace()) |workspace| if (workspace.session_controller != null) {
        if (edge != null or dock != null) {
            std.log.warn("app: session-backed workspaces do not support edge or dock splits", .{});
            if (self.lua) |*lua| lua.invokeOperationCallback(callback_ref, false, .none);
            return;
        }
        const source = previous orelse return;
        @import("session_spawn.zig").split(self, .{ .split = .{
            .tab_id = mux.activeTab().?.id,
            .source_id = source.id,
            .direction = direction,
            .ratio = snapped_ratio,
            .floating = floating,
            .fullscreen = fullscreen,
            .x = x,
            .y = y,
            .width = width,
            .height = height,
        } }, cwd, domain_name, effective_command, command_mode, close_on_exit, callback_ref) catch |err| {
            @import("session_spawn.zig").reject(self, callback_ref, err);
        };
        return;
    };
    std.log.info("split-trace create dir={s} requested={d:.4} snapped={d:.4} bounds={d}x{d} cell={d}x{d}", .{
        @tagName(direction),
        ratio,
        snapped_ratio,
        split_bounds.width,
        split_bounds.height,
        self.cell_width_px,
        self.cell_height_px,
    });
    const pane = mux.splitActivePanePlaced(runtime, cbs, self.config, self.cell_width_px, self.cell_height_px, self.config.window_width, self.config.window_height, direction, snapped_ratio, domain_name, cwd, floating, launch_command, edge) catch |err| {
        std.log.err("app: splitPane failed: {s} domain={s}", .{ @errorName(err), domain_name orelse "" });
        if (self.lua) |*lua| lua.invokeOperationCallback(callback_ref, false, .none);
        return;
    };
    if (!floating and edge == null) {
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
    if (dock) |scope| {
        // The edge split gave the pane its domain/cwd; now hand it to the dock.
        mux.dockPane(pane, edge.?, scope, std.math.clamp(ratio, 0.05, 0.95)) catch |err| {
            std.log.warn("app: splitPane dock failed: {s}", .{@errorName(err)});
        };
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
        if (effective_command) |cmd| {
            sendSplitPaneCommand(self, pane, cmd, close_on_exit);
        }
    }
    htp.bindHtpHandlers(self);
    self.syncActivePaneChange(previous, mux.activePane());
    if (self.lua) |*lua| lua.invokeOperationCallback(callback_ref, true, .{ .pane_id = pane.id });
    self.requestLayoutResize(false);
    std.log.info("app: splitPane total_ms={d}", .{io.milliTimestamp() - start_ms});
    std.log.info("app: pane split done direction={s}", .{@tagName(direction)});
}

fn nonEmptyCommand(command: ?[]const u8) ?[]const u8 {
    if (command) |value| {
        return if (value.len > 0) value else null;
    }
    return null;
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

/// Hide/show a pane without closing its PTY or releasing its mux session.
pub fn setPaneVisibleById(self: *App, pane_id: usize, visible: bool) void {
    const pane = self.findPaneById(pane_id) orelse return;
    if (self.mux) |*mux| {
        const previous = mux.activePane();
        if (!mux.setPaneVisible(pane, visible)) return;
        if (visible) pane.invalidate();
        self.syncActivePaneChange(previous, mux.activePane());
        self.requestLayoutResize(false);
        self.emitLuaBuiltInEvent("term:pane_layout_changed", .{ .pane_layout_changed = .{ .pane_id = pane_id } });
    }
}

/// Move a pane into a window-edge dock; it then survives tab switches.
pub fn dockPaneById(self: *App, pane_id: usize, edge: PaneEdge, scope: DockScope, ratio: f32) void {
    const pane = self.findPaneById(pane_id) orelse return;
    if (self.mux) |*mux| {
        const previous = mux.activePane();
        mux.dockPane(pane, edge, scope, ratio) catch |err| {
            std.log.warn("app: dockPane failed: {s} pane={d} edge={s} scope={s}", .{ @errorName(err), pane_id, @tagName(edge), @tagName(scope) });
            return;
        };
        pane.invalidate();
        self.syncActivePaneChange(previous, mux.activePane());
        self.requestLayoutResize(false);
        if (mux.activePane() == pane) self.emitLuaBuiltInEvent("term:pane_focused", .{ .pane_id = pane_id });
        self.emitLuaBuiltInEvent("term:pane_layout_changed", .{ .pane_layout_changed = .{ .pane_id = pane_id } });
    }
}

/// Return a docked pane to the active tab as an edge split.
pub fn undockPaneById(self: *App, pane_id: usize) void {
    const pane = self.findPaneById(pane_id) orelse return;
    if (self.mux) |*mux| {
        const previous = mux.activePane();
        mux.undockPane(pane) catch |err| {
            std.log.warn("app: undockPane failed: {s} pane={d}", .{ @errorName(err), pane_id });
            return;
        };
        pane.invalidate();
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
            if (previous != pane) self.emitLuaBuiltInEvent("term:pane_focused", .{ .pane_id = pane.id });
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
    if (ws.session_controller) |controller| {
        controller.layout_dirty = true;
        controller.layout_due_ns = io.nanoTimestamp() + 100 * std.time.ns_per_ms;
        self.signalWake();
    }
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
        const term = pane.asTerminal() orelse continue;
        if (!term.hasLiveChild()) {
            if (!term.retain_on_exit) has_dead = true;
            pane_lifecycle.exited(self, pane);
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
        if (active.asTerminal()) |term| runtime.registerCallbacks(term.terminal, terminal_callbacks.terminalCallbacks());
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
        queueStartupInput(pane, command) catch |err| {
            std.log.err("app: failed to queue split startup command: {s}", .{@errorName(err)});
        };
        return;
    }

    const wrapped = wrapCommandForCloseOnExit(self, pane, command) catch |err| {
        std.log.err("app: failed to wrap split command for close_on_exit: {s}", .{@errorName(err)});
        queueStartupInput(pane, command) catch |queue_err| {
            std.log.err("app: failed to queue split startup command after wrap error: {s}", .{@errorName(queue_err)});
        };
        return;
    };
    defer self.allocator.free(wrapped);
    queueStartupInput(pane, wrapped) catch |err| {
        std.log.err("app: failed to queue wrapped split startup command: {s}", .{@errorName(err)});
    };
}

fn queueStartupInput(pane: *Pane, text: []const u8) !void {
    const term = pane.asTerminal() orelse return error.NotATerminal;
    try term.queueStartupInput(pane.allocator, text);
}

fn wrapCommandForCloseOnExit(self: *App, pane: *Pane, command: []const u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, command, "\r\n");
    const domain = pane.domainName();
    const is_windows_domain = domain.len > 0 and !std.mem.eql(u8, domain, "wsl") and !std.mem.eql(u8, domain, "unix");

    if (is_windows_domain) {
        return std.fmt.allocPrint(self.allocator, "{s} & exit", .{trimmed});
    }

    return std.fmt.allocPrint(self.allocator, "{s}; exit", .{trimmed});
}

test "paste capture clears borrowed output on success and unsafe rejection" {
    const allocator = std.testing.allocator;
    const app = try allocator.create(App);
    defer allocator.destroy(app);
    app.* = App.init(allocator);
    defer app.deinit();
    app.ghostty = try GhosttyRuntime.init(allocator, null);
    const runtime = &app.ghostty.?;
    app.mux = Mux.init(allocator);
    const mux = &app.mux.?;
    const workspace = try allocator.create(Workspace);
    workspace.* = Workspace.init(allocator, 1);
    try mux.workspaces.append(allocator, workspace);
    mux.active_workspace = workspace;
    const tab = try workspace.newTab(2, false);
    const pane = try allocator.create(Pane);
    pane.* = Pane.init(allocator);
    try tab.appendPane(pane);
    const term = pane.asTerminal().?;
    term.terminal_runtime = runtime;
    term.terminal = try runtime.createTerminal(80, 24, 0);
    runtime.setTerminalUserdata(term.terminal, pane);
    runtime.registerCallbacks(term.terminal, terminal_callbacks.terminalCallbacks());
    try term.queueStartupInput(allocator, "startup");

    try sendPaste(app, "safe");
    try std.testing.expect(term.paste_output == null);
    try std.testing.expectEqualStrings("startup\rsafe", term.pending_startup_input);
    try std.testing.expectError(error.UnsafePaste, sendPaste(app, "first\nsecond"));
    try std.testing.expect(term.paste_output == null);
    try std.testing.expect(term.osc99_notifications.hasNotifications());
    try std.testing.expectEqualStrings("startup\rsafe", term.pending_startup_input);

    try std.testing.expect(runtime.setTerminalMode(term.terminal, .bracketed_paste, true));
    try sendPaste(app, "first\nsecond");
    try std.testing.expect(term.paste_output == null);
    try std.testing.expectEqualStrings("startup\rsafe\x1b[200~first\nsecond\x1b[201~", term.pending_startup_input);
}

fn mockAttachedSessionConnection(allocator: std.mem.Allocator) !*SessionConnection {
    const connection = try allocator.create(SessionConnection);
    errdefer allocator.destroy(connection);
    connection.* = .{
        .allocator = allocator,
        .io = io.get(),
        .arena = .init(allocator),
        .options = .{ .ghostty_identity = "test" },
        .client = .{ .allocator = allocator, .identity = "test" },
    };
    errdefer {
        connection.client.deinit();
        connection.arena.deinit();
    }

    const welcome = "{\"protocol\":\"hollow-session\",\"version\":1,\"ghostty\":\"test\",\"snapshot\":\"binary\",\"owner_pid\":1}";
    try connection.client.receive(p.header(.welcome, 0, welcome.len), welcome);
    connection.poll().?.deinit();

    const request_id = try connection.request(.{ .id = 0, .op = .attach, .session = "mock" });
    connection.client.nextWrite().?.deinit();
    const body = try p.stringify(allocator, p.Reply{ .id = request_id, .session = .{
        .id = "mock",
        .attached = true,
        .revision = 0,
        .panes = &.{.{ .id = 1, .cols = 80, .rows = 24 }},
    } });
    defer allocator.free(body);
    try connection.client.receive(p.header(.reply, 0, body.len), body);
    connection.poll().?.deinit();
    return connection;
}

test "session borrowers keep App pane close gated on owner acknowledgement" {
    const allocator = std.testing.allocator;
    const connection = try mockAttachedSessionConnection(allocator);
    var app_owns_connection = false;
    defer if (!app_owns_connection) connection.destroy();

    const app = try allocator.create(App);
    defer allocator.destroy(app);
    app.* = App.init(allocator);
    defer app.deinit();
    app.ghostty = try GhosttyRuntime.init(allocator, null);
    app.mux = Mux.init(allocator);
    app.mux.?.host_context = app;
    app.mux.?.pane_created = pane_lifecycle.created;
    app.mux.?.pane_closing = pane_lifecycle.closing;
    app.lua = try @import("../lua_bridge.zig").Runtime.initForTests(allocator, &app.config);
    try app.lua.?.runString(recordWorkspaceClosed);

    const info: SessionProtocol.SessionInfo = .{
        .id = "mock",
        .attached = true,
        .revision = 0,
        .panes = &.{.{ .id = 1, .cols = 80, .rows = 24 }},
    };
    _ = try addSessionWorkspace(app, connection, info, "session-domain");
    app_owns_connection = true;
    const controller = app.session_controllers.items[0];
    const pane_id = app.activePane().?.id;

    closePaneById(app, pane_id);
    try std.testing.expect(app.findPaneById(pane_id) != null);
    try std.testing.expectEqual(@as(usize, 0), controller.pendingCloses());

    pumpSessionControllers(app, &app.ghostty.?);
    try std.testing.expectEqual(@as(usize, 1), controller.pendingCloses());
    const first_close = connection.client.nextWrite().?;
    const first_request = try p.parse(p.Request, allocator, first_close.payload);
    defer first_request.deinit();
    defer first_close.deinit();
    try std.testing.expectEqual(p.Op.close, first_request.value.op);

    const rejected = try p.stringify(allocator, p.Reply{ .id = first_request.value.id, .ok = false, .@"error" = "temporary failure" });
    defer allocator.free(rejected);
    try connection.client.receive(p.header(.reply, 0, rejected.len), rejected);
    pumpSessionControllers(app, &app.ghostty.?);
    try std.testing.expect(app.findPaneById(pane_id) != null);
    try std.testing.expectEqual(@as(usize, 0), controller.pendingCloses());

    closeTab(app);
    pumpSessionControllers(app, &app.ghostty.?);
    const second_close = connection.client.nextWrite().?;
    const second_request = try p.parse(p.Request, allocator, second_close.payload);
    defer second_request.deinit();
    defer second_close.deinit();
    try std.testing.expect(second_request.value.id != first_request.value.id);

    const accepted = try p.stringify(allocator, p.Reply{ .id = second_request.value.id });
    defer allocator.free(accepted);
    try connection.client.receive(p.header(.reply, 0, accepted.len), accepted);
    pumpSessionControllers(app, &app.ghostty.?);
    try std.testing.expect(app.findPaneById(pane_id) == null);
    try std.testing.expectEqual(@as(usize, 0), app.mux.?.workspaces.items.len);
    try std.testing.expect(app.pending_quit);
    try std.testing.expect(!controller.hasBindings());
    // The owner acknowledged the last close, so restore must forget it.
    try app.lua.?.runString("assert(#closed == 1 and closed[1].session_id == 'mock' and closed[1].session_ended == true)");
}

const recordWorkspaceClosed =
    \\closed = {}
    \\hollow = {_emit_builtin_event = function(name, payload)
    \\  if name == "workspace:closed" then closed[#closed + 1] = payload end
    \\end}
;

test "session borrowers allow local close after takeover or connection loss" {
    const allocator = std.testing.allocator;
    for (0..3) |mode| {
        const connection = try mockAttachedSessionConnection(allocator);
        var owned = false;
        defer if (!owned) connection.destroy();
        const app = try allocator.create(App);
        defer allocator.destroy(app);
        app.* = App.init(allocator);
        defer app.deinit();
        app.ghostty = try GhosttyRuntime.init(allocator, null);
        app.mux = Mux.init(allocator);
        app.lua = try @import("../lua_bridge.zig").Runtime.initForTests(allocator, &app.config);
        try app.lua.?.runString(recordWorkspaceClosed);
        const info: SessionProtocol.SessionInfo = .{
            .id = "mock",
            .attached = true,
            .revision = 0,
            .panes = &.{.{ .id = 1, .cols = 80, .rows = 24 }},
        };
        _ = try addSessionWorkspace(app, connection, info, null);
        owned = true;
        const pane_id = app.activePane().?.id;
        if (mode == 0) {
            const body = try p.stringify(allocator, p.Event{ .event = .taken, .session = "mock" });
            defer allocator.free(body);
            try connection.client.receive(p.header(.event, 0, body.len), body);
            pumpSessionControllers(app, &app.ghostty.?);
            closePaneById(app, pane_id);
        } else {
            connection.client.ended = true;
            connection.finished = true;
            if (mode == 1) closeTab(app) else closeWorkspace(app, null);
        }
        try std.testing.expect(app.findPaneById(pane_id) == null);
        try std.testing.expectEqual(@as(usize, 0), app.mux.?.session_workspace_count);
        try std.testing.expect(connection.client.nextWrite() == null);
        // Only local views closed; the session must stay remembered.
        try app.lua.?.runString("assert(#closed == 1 and closed[1].session_id == 'mock' and closed[1].session_ended == false)");
    }
}
