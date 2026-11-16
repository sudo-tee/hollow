//! Two-attachment tab transfer. Source offer is a delivery barrier; destination
//! adoption replies before its new snapshots. Never replay a submitted request.
const std = @import("std");
const App = @import("../app.zig").App;
const Controller = @import("../session/controller.zig").Controller;
const transport = @import("../session/transport.zig");
const p = transport.p;
const io = @import("../io.zig");

pub const Operation = struct {
    source: *Controller,
    destination: *Controller,
    source_workspace: usize,
    destination_workspace: usize,
    tab_id: usize,
    source_generation: u64,
    destination_generation: u64,
    token: [32]u8,
    panes: [64]u32 = undefined,
    local_ids: [64]usize = undefined,
    count: usize,
    phase: enum { waiting, offering, committing, canceling } = .waiting,
    request: ?u64 = null,
    deadline: i128,
};

fn available(controller: *Controller) bool {
    if (controller.detached or controller.taken or controller.failure != null or
        controller.connection.status().phase != .ready or controller.layout_conflict or
        controller.spawn_active or controller.transfer_active or controller.close_work or controller.kill_request != null) return false;
    for (controller.bindings) |entry| if (entry) |binding| {
        if (binding.close_request != null or binding.close_desired or binding.respawn_request != null) return false;
    };
    return true;
}

pub fn begin(app: *App, tab_id: usize, destination_index: usize) !void {
    if (app.session_transfer != null) return error.SessionBusy;
    const mux = if (app.mux) |*value| value else return error.MuxUnavailable;
    const tab = mux.tabById(tab_id) orelse return error.TabNotFound;
    const source_ws = for (mux.workspaces.items) |workspace| {
        if (workspace.tabById(tab_id) != null) break workspace;
    } else return error.WorkspaceNotFound;
    if (destination_index >= mux.workspaces.items.len) return error.WorkspaceNotFound;
    const destination_ws = mux.workspaces.items[destination_index];
    if (source_ws == destination_ws) return error.SameSession;
    const source = source_ws.session_controller orelse return error.CrossSessionMove;
    const destination = destination_ws.session_controller orelse return error.CrossSessionMove;
    if (!available(source) or !available(destination) or source_ws.session_close_desired or
        destination_ws.session_close_desired or tab.close_after_session_ack) return error.SessionBusy;
    if (!source.connection.supportsTabTransfer() or !destination.connection.supportsTabTransfer()) return error.OwnerUpgradeRequired;
    if (source.host.len == 0 or !std.mem.eql(u8, source.host, destination.host)) return error.SessionHostChanged;
    const target_tab = destination_ws.activeTab() orelse return error.NoActivePane;
    const target_pane = target_tab.activePane() orelse return error.NoActivePane;
    const domain = target_pane.domainName();
    if (domain.len == 0 or tab.panes.items.len == 0 or tab.panes.items.len > 64) return error.CrossSessionDomain;
    var op: Operation = .{
        .source = source,
        .destination = destination,
        .source_workspace = source_ws.id,
        .destination_workspace = destination_ws.id,
        .tab_id = tab_id,
        .source_generation = source.generation,
        .destination_generation = destination.generation,
        .token = @import("../agent/diagnostics.zig").randomId(),
        .count = tab.panes.items.len,
        .deadline = io.nanoTimestamp() + 30 * std.time.ns_per_s,
    };
    var source_count: usize = 0;
    var destination_count: usize = 0;
    for (source.bindings) |slot| if (slot != null) {
        source_count += 1;
    };
    for (destination.bindings) |slot| if (slot != null) {
        destination_count += 1;
    };
    if (destination_count + op.count > destination.bindings.len) return error.ResourceExhausted;
    // A dock-only session view cannot currently be represented/restored.
    if (source_ws.tabs.items.len == 1 and source_count != op.count) return error.LastTabWithDocks;
    for (tab.panes.items, 0..) |pane, i| {
        if (!std.mem.eql(u8, pane.domainName(), domain) or mux.controllerForPane(pane.id) != source) return error.CrossSessionDomain;
        const term = pane.asTerminal() orelse return error.NotSessionPane;
        op.panes[i] = term.pty.?.session.pane;
        op.local_ids[i] = pane.id;
    }
    try destination_ws.tabs.ensureUnusedCapacity(app.allocator, 1);
    source.transfer_active = true;
    destination.transfer_active = true;
    app.session_transfer = op;
    for (tab.panes.items) |pane| pane.content.terminal.pty.?.session.transfer_pending = true;
    app.signalWake();
}

pub fn paused(app: *const App, controller: *Controller) bool {
    const op = app.session_transfer orelse return false;
    return controller == op.source and op.phase == .committing;
}

fn release(app: *App) void {
    const op = app.session_transfer orelse return;
    app.session_transfer = null;
    for (op.local_ids[0..op.count]) |id| if (app.findPaneById(id)) |pane| {
        if (pane.asTerminal()) |term| if (term.pty) |*pty| if (pty.* == .session) {
            pty.session.transfer_pending = false;
        };
    };
    op.source.transfer_active = false;
    op.destination.transfer_active = false;
}

fn uncertain(app: *App, reason: anyerror) void {
    const op = app.session_transfer orelse return;
    // The owner may have committed. Freeze both views; explicit reattachment
    // reconciles their authoritative memberships. Never close remote panes.
    op.source.abort(reason);
    op.destination.abort(reason);
    release(app);
    std.log.warn("tab transfer needs reattachment: {s}", .{@errorName(reason)});
    @import("session_spawn.zig").report(app, error.TransferOutcomeUnknown, .uncertain, @errorName(reason));
}

pub fn shutdown(app: *App) void {
    if (app.session_transfer != null) uncertain(app, error.Canceled);
}

pub fn pump(app: *App) void {
    const op = if (app.session_transfer) |*value| value else return;
    if (io.nanoTimestamp() >= op.deadline or op.source.detached or op.destination.detached or
        op.source.generation != op.source_generation or op.destination.generation != op.destination_generation or
        op.source.connection.status().phase != .ready or op.destination.connection.status().phase != .ready)
    {
        if (op.phase == .waiting) {
            release(app);
            @import("session_spawn.zig").report(app, error.Detached, .not_sent, null);
        } else uncertain(app, error.TransferConnectionLost);
        return;
    }
    if (op.phase != .waiting or op.source.layout_request != null or op.destination.layout_request != null) return;
    op.request = op.source.connection.transferRequest(op.source_generation, .{
        .id = 0,
        .op = .transfer_offer,
        .revision = op.source.revision,
        .transfer_session = op.destination.session_id,
        .transfer_token = &op.token,
        .transfer_panes = op.panes[0..op.count],
    }) catch |err| {
        release(app);
        @import("session_spawn.zig").report(app, err, .not_sent, null);
        return;
    };
    op.phase = .offering;
}

fn cancel(app: *App) void {
    const op = &app.session_transfer.?;
    op.request = op.source.connection.transferRequest(op.source_generation, .{
        .id = 0,
        .op = .transfer_cancel,
        .transfer_token = &op.token,
    }) catch |err| return uncertain(app, err);
    op.phase = .canceling;
}

pub fn handle(app: *App, controller: *Controller, message: transport.Message) bool {
    const op = if (app.session_transfer) |*value| value else return false;
    const expected = if (op.phase == .committing) op.destination else op.source;
    if (controller != expected or message.request_id != op.request or op.request == null) return false;
    const parsed = p.parse(p.Reply, app.allocator, message.payload) catch |err| {
        uncertain(app, err);
        return true;
    };
    defer parsed.deinit();
    const reply = parsed.value;
    if (op.phase == .canceling) {
        if (reply.ok) release(app) else uncertain(app, error.TransferCancelRejected);
        return true;
    }
    if (!reply.ok) {
        @import("session_spawn.zig").report(app, error.TransferRejected, .rejected, reply.@"error");
        if (op.phase == .offering) release(app) else cancel(app);
        return true;
    }
    if (op.phase == .offering) {
        op.request = op.destination.connection.transferRequest(op.destination_generation, .{
            .id = 0,
            .op = .transfer,
            .revision = op.destination.revision,
            .transfer_session = op.source.session_id,
            .transfer_token = &op.token,
        }) catch |err| {
            @import("session_spawn.zig").report(app, err, .not_sent, null);
            cancel(app);
            return true;
        };
        op.phase = .committing;
        return true;
    }
    finish(app, reply) catch |err| uncertain(app, err);
    return true;
}

fn finish(app: *App, reply: p.Reply) !void {
    const op = app.session_transfer.?;
    const mux = &app.mux.?;
    const tab = mux.tabById(op.tab_id) orelse return error.TabNotFound;
    const source_ws = mux.workspaceById(op.source_workspace) orelse return error.WorkspaceNotFound;
    const destination_ws = mux.workspaceById(op.destination_workspace) orelse return error.WorkspaceNotFound;
    const mappings = reply.transferred orelse return error.InvalidReply;
    if (mappings.len != op.count or tab.panes.items.len != op.count or source_ws.tabById(tab.id) != tab or
        source_ws.session_controller != op.source or destination_ws.session_controller != op.destination) return error.InvalidTransfer;
    const revision = reply.source_revision orelse return error.InvalidRevision;
    if (!availableForCommit(op.source, op.source_generation) or
        !availableForCommit(op.destination, op.destination_generation)) return error.Detached;
    var source_count: usize = 0;
    var destination_count: usize = 0;
    for (op.source.bindings) |slot| if (slot != null) {
        source_count += 1;
    };
    for (op.destination.bindings) |slot| if (slot != null) {
        destination_count += 1;
    };
    if ((source_ws.tabs.items.len == 1 and source_count != op.count) or
        destination_count + op.count > op.destination.bindings.len) return error.InvalidTransfer;
    for (tab.panes.items, mappings, 0..) |pane, mapping, i| {
        if (pane.id != op.local_ids[i] or mapping.from != op.panes[i] or mapping.to == 0 or
            mux.controllerForPane(pane.id) != op.source) return error.InvalidTransfer;
        for (mappings[0..i]) |previous_mapping| if (previous_mapping.to == mapping.to) return error.InvalidTransfer;
        for (op.destination.bindings) |slot| if (slot) |binding| {
            if (binding.pane == mapping.to) return error.InvalidTransfer;
        };
    }
    // Other local actions can consume the capacity reserved at admission.
    // Allocate before changing any binding, even though owner commit is final.
    try destination_ws.tabs.ensureUnusedCapacity(app.allocator, 1);
    const previous = mux.activePane();
    for (tab.panes.items, mappings) |pane, mapping| {
        const term = &pane.content.terminal;
        const exit = term.pty.?.session.status;
        const close_on_exit = term.pty.?.session.close_on_exit;
        op.source.unbind(pane.id);
        term.pty.?.session.deinit();
        op.source.connection.forgetTransferredPane(op.source_generation, mapping.from);
        term.pty.?.session = @import("../pty/session.zig").SessionPty.init(app.allocator, op.destination.connection, mapping.to, op.destination_generation, exit);
        term.session_snapshot_waiting = true;
        term.terminal_output_ready = false;
        try op.destination.bind(pane);
        term.pty.?.session.close_on_exit = close_on_exit;
    }
    op.source.revision = revision;
    const insert_at = destination_ws.activeTabIndex() + 1;
    source_ws.detachTab(tab);
    destination_ws.tabs.insertAssumeCapacity(insert_at, tab);
    destination_ws.active_tab = tab;
    mux.active_workspace = destination_ws;
    mux.focused_dock = null;
    release(app);
    for (tab.panes.items) |pane| {
        const pty = &pane.content.terminal.pty.?.session;
        if (pty.close_on_exit and pty.status != null) try op.destination.scheduleClose(pane.id);
    }
    if (source_ws.tabs.items.len == 0) mux.removeEmptyTransferredWorkspace(&app.ghostty.?, source_ws);
    app.markSessionLayoutsDirty();
    app.syncActivePaneChange(previous, mux.activePane());
    app.refreshActivePaneDisplay();
    @import("session_controller.zig").emitWorkspaceClosedIfRemoved(app, mux);
    app.emitLuaBuiltInEvent("workspace:changed", .{ .workspace_index = mux.activeWorkspaceIndex() });
    app.requestLayoutResize(true);
    app.requestLayoutRefresh();
    app.emitLuaBuiltInEvent("term:tab_activated", .{ .tab_id = tab.id });
}

fn availableForCommit(controller: *Controller, generation: u64) bool {
    return !controller.detached and !controller.taken and controller.failure == null and
        controller.generation == generation and controller.connection.status().phase == .ready;
}
