//! Owner-backed tab/split admission. One in-flight operation per workspace;
//! all arguments are copied before submission. A lost reply is never replayed.
const std = @import("std");
const App = @import("../app.zig").App;
const Mux = @import("../mux/mux.zig").Mux;
const Controller = @import("../session/controller.zig").Controller;
const transport = @import("../session/transport.zig");
const p = transport.p;
const io = @import("../io.zig");
pub const max_pending = 16;

pub const Operation = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    controller: *Controller,
    generation: u64,
    workspace_id: usize,
    placement: Mux.SessionPlacement,
    domain: []const u8,
    spawn: p.Spawn,
    request_id: ?u64 = null,
    input: ?[]u8 = null,
    callback_ref: c_int,
    lua_generation: u64,

    fn destroy(self: *Operation) void {
        if (self.input) |value| self.allocator.free(value);
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};

pub fn newTab(app: *App, cwd: ?[]const u8, domain: ?[]const u8, command: ?[]const u8, callback_ref: c_int, insert_at_end: bool) !void {
    const mux = if (app.mux) |*value| value else return error.MuxUnavailable;
    const tab = mux.activeTab() orelse return error.NoActiveTab;
    try admit(app, .{ .tab = .{ .after_tab_id = tab.id, .insert_at_end = insert_at_end } }, cwd, domain, command, false, false, callback_ref);
}

pub fn split(app: *App, placement: Mux.SessionPlacement, cwd: ?[]const u8, domain: ?[]const u8, command: ?[]const u8, command_mode: @import("../app.zig").SplitCommandMode, close_on_exit: bool, callback_ref: c_int) !void {
    try admit(app, placement, cwd, domain, command, command_mode == .spawn, close_on_exit, callback_ref);
}

fn sameOptional(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |value| return if (b) |other| std.mem.eql(u8, value, other) else false;
    return b == null;
}

fn sameHost(options: transport.Options, host: @import("../pty/agent.zig").Host) bool {
    if (host.fallback or host.error_message != null or options.path_style != host.path_style or
        options.connector.remote_shell != host.connector.remote_shell or options.connector.argv.len != host.connector.argv.len) return false;
    for (options.connector.argv, host.connector.argv) |a, b| if (!std.mem.eql(u8, a, b)) return false;
    if (!sameOptional(options.agent.path, host.agent.path) or !sameOptional(options.agent.dir, host.agent.dir)) return false;
    for (options.agent.artifacts.values, host.agent.artifacts.values) |a, b| {
        if (a) |value| {
            const other = b orelse return false;
            if (!std.mem.eql(u8, value.path, other.path) or !std.mem.eql(u8, value.sha256, other.sha256)) return false;
        } else if (b != null) return false;
    }
    return true;
}

fn admit(app: *App, placement: Mux.SessionPlacement, cwd: ?[]const u8, requested_domain: ?[]const u8, command: ?[]const u8, spawn_command: bool, close_on_exit: bool, callback_ref: c_int) !void {
    const mux = if (app.mux) |*value| value else return error.MuxUnavailable;
    const ws = mux.activeWorkspace() orelse return error.NoActiveWorkspace;
    const controller = ws.session_controller orelse return error.NotSessionWorkspace;
    if (controller.detached or controller.connection.status().phase != .ready) return error.Detached;
    if (ws.session_close_desired or controller.close_work or controller.pendingCloses() != 0 or controller.kill_request != null) return error.SessionClosing;
    if (controller.spawn_active) return error.SessionBusy;
    if (controller.layout_conflict) return error.RevisionConflict;
    const source = mux.activePane() orelse return error.NoActivePane;
    const tab = mux.activeTab() orelse return error.NoActiveTab;
    if (tab.close_after_session_ack) return error.SessionClosing;
    if (placement == .split and tab.panes.items.len >= 64) return error.ResourceExhausted;
    var pane_count: usize = 0;
    var panes = ws.paneIterator();
    while (panes.next() != null) pane_count += 1;
    if (pane_count >= 1024) return error.ResourceExhausted;
    var slot: ?usize = null;
    for (app.session_spawns, 0..) |value, index| if (value == null) {
        slot = index;
        break;
    };
    const index = slot orelse return error.ResourceExhausted;
    if (source.domainName().len == 0) return error.UnknownDomain;
    if (requested_domain) |value| if (!std.mem.eql(u8, value, source.domainName())) return error.CrossSessionDomain;

    const op = try app.allocator.create(Operation);
    errdefer app.allocator.destroy(op);
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const domain = try a.dupe(u8, source.domainName());
    const definition = app.config.domainByName(domain) orelse return error.UnknownDomain;
    const configured_shell = if (definition.shell) |value| try a.dupe(u8, value) else null;
    const shell_hint = configured_shell orelse try a.dupe(u8, app.config.shellOrDefault());
    const base_cwd = cwd orelse if (source.cwd.len > 0) source.cwd else ws.default_cwd orelse app.config.defaultCwdForDomain(domain);
    const owned_cwd = if (base_cwd) |value| try a.dupe(u8, value) else null;
    const lua = if (app.lua) |*value| value else return error.LuaUnavailable;
    const host = try lua.sessionHost(a, domain, shell_hint);
    if (!sameHost(controller.connection.options, host)) return error.SessionHostChanged;
    var spawn = try @import("session_domain.zig").prepareSpawn(a, app.config, host, if (host.connector.argv.len == 0) shell_hint else configured_shell orelse "", owned_cwd, domain, command, mux.spawn_filter);
    if (spawn_command) {
        spawn.command = command;
        spawn.close_on_exit = close_on_exit;
    }
    // Retain request data independently of Lua/config storage for queued admission.
    const bytes = try p.stringify(a, spawn);
    if (bytes.len > p.control_limit) return error.PayloadTooLarge;
    const parsed = try std.json.parseFromSlice(p.Spawn, a, bytes, .{ .allocate = .alloc_always });
    const input: ?[]u8 = if (!spawn_command and command != null and command.?.len > 0) blk: {
        const text = if (close_on_exit) try std.fmt.allocPrint(a, "{s}; exit", .{std.mem.trimEnd(u8, command.?, "\r\n")}) else command.?;
        const suffix = if (std.mem.endsWith(u8, text, "\r") or std.mem.endsWith(u8, text, "\n")) "" else "\r";
        break :blk try std.mem.concat(app.allocator, u8, &.{ text, suffix });
    } else null;
    op.* = .{
        .allocator = app.allocator,
        .arena = arena,
        .controller = controller,
        .generation = controller.generation,
        .workspace_id = ws.id,
        .placement = placement,
        .domain = domain,
        .spawn = parsed.value,
        .input = input,
        .callback_ref = callback_ref,
        .lua_generation = lua.generation,
    };
    controller.spawn_active = true;
    app.session_spawns[index] = op;
    app.session_spawn_count += 1;
    app.signalWake();
}

pub fn reject(app: *App, callback_ref: c_int, reason: anyerror) void {
    report(app, reason, .not_sent, null);
    complete(app, callback_ref, if (app.lua) |*lua| lua.generation else 0, false, .none);
}

pub fn layoutRejected(app: *App, reason: anyerror) void {
    report(app, reason, .rejected, null);
}

pub fn respawnRejected(app: *App, remote: ?[]const u8) void {
    report(app, error.RespawnRejected, .rejected, remote);
}

fn report(app: *App, reason: anyerror, outcome: @import("../session/open.zig").Outcome, remote: ?[]const u8) void {
    const id = app.session_open_next_id;
    if (id != std.math.maxInt(u64)) app.session_open_next_id += 1;
    _ = app.session_notices.failedRemote(id, reason, outcome, remote);
    app.requestRedraw();
    std.log.warn("session pane operation failed: {s} ({s}; not replayed)", .{ @errorName(reason), @tagName(outcome) });
}

fn complete(app: *App, callback_ref: c_int, generation: u64, ok: bool, payload: @import("../lua_bridge.zig").OperationCallbackPayload) void {
    if (app.lua) |*lua| if (lua.generation == generation) lua.invokeOperationCallback(callback_ref, ok, payload);
}

const Completion = struct { callback_ref: c_int, generation: u64 };

fn remove(app: *App, index: usize) Completion {
    const op = app.session_spawns[index].?;
    const result: Completion = .{ .callback_ref = op.callback_ref, .generation = op.lua_generation };
    app.session_spawns[index] = null;
    app.session_spawn_count -= 1;
    op.controller.finishSpawn();
    op.destroy();
    return result;
}

fn fail(app: *App, index: usize, reason: anyerror, outcome: @import("../session/open.zig").Outcome, remote: ?[]const u8) void {
    // Copy diagnostic detail before releasing the operation or caller's reply.
    report(app, reason, outcome, remote);
    const callback = remove(app, index);
    complete(app, callback.callback_ref, callback.generation, false, .none);
}

pub fn pump(app: *App) void {
    if (app.session_spawn_count == 0) return;
    for (0..max_pending) |index| {
        const op = app.session_spawns[index] orelse continue;
        const controller = op.controller;
        const phase = controller.connection.status().phase;
        if (controller.detached or controller.generation != op.generation or phase == .ended or phase == .closing) {
            controller.connection.close(); // Fence writer before classifying queued work.
            const state = if (op.request_id) |id| controller.connection.requestState(id) else .not_sent;
            const outcome: @import("../session/open.zig").Outcome = if (state == .queued or state == .not_sent) .not_sent else .uncertain;
            fail(app, index, error.Detached, outcome, null);
            continue;
        }
        if (op.request_id != null) continue;
        const ws = if (app.mux) |*mux| mux.workspaceById(op.workspace_id) else null;
        if (ws == null or ws.?.session_controller != controller) {
            fail(app, index, error.WorkspaceClosed, .not_sent, null);
            continue;
        }
        if (controller.layout_request != null) continue;
        if (controller.layout_conflict) {
            fail(app, index, error.RevisionConflict, .not_sent, null);
            continue;
        }
        op.request_id = controller.requestSpawn(op.spawn) catch |err| {
            if (err == error.ResourceExhausted) {
                app.signalWake();
                continue;
            }
            fail(app, index, err, .not_sent, null);
            continue;
        };
    }
}

/// Reply barrier: bind the new view before any following pane data is routed.
pub fn handle(app: *App, controller: *Controller, message: transport.Message) bool {
    const request_id = message.request_id orelse return false;
    for (app.session_spawns, 0..) |entry, index| {
        const op = entry orelse continue;
        if (op.controller != controller or op.request_id != request_id) continue;
        const parsed = p.parse(p.Reply, app.allocator, message.payload) catch |err| {
            controller.abort(err);
            fail(app, index, err, .uncertain, null);
            return true;
        };
        defer parsed.deinit();
        if (!parsed.value.ok) {
            fail(app, index, error.Rejected, .rejected, parsed.value.@"error");
            return true;
        }
        if (message.generation != op.generation or parsed.value.pane == null) {
            controller.abort(error.InvalidReply);
            fail(app, index, error.InvalidReply, .uncertain, null);
            return true;
        }
        const mux = if (app.mux) |*value| value else unreachable;
        const previous = mux.activePane();
        const pane = mux.addSessionPane(&app.ghostty.?, @import("terminal_callbacks.zig").terminalCallbacks(), app.config, controller, op.workspace_id, .{ .id = parsed.value.pane.?, .cols = op.spawn.cols, .rows = op.spawn.rows }, op.domain, @import("session_borrowers.zig").beforeReplace, op.placement) catch |err| {
            // Spawn succeeded, but no view can receive its stream. Detach safely;
            // reattachment recovers it. Never replay spawn or keep routing blind.
            controller.abort(err);
            fail(app, index, err, .uncertain, null);
            return true;
        };
        const pane_id = pane.id;
        if (op.input) |value| {
            pane.content.terminal.pending_startup_input = value;
            pane.content.terminal.pending_startup_input_capacity = value.len;
            op.input = null;
        }
        const workspace = mux.workspaceById(op.workspace_id).?;
        var tab_id: usize = 0;
        var should_close = workspace.session_close_desired;
        for (workspace.tabs.items) |tab| for (tab.panes.items) |node| if (node == pane) {
            tab_id = tab.id;
            should_close = should_close or tab.close_after_session_ack;
            break;
        };
        const is_tab = op.placement == .tab;
        const callback = remove(app, index);
        if (should_close) controller.scheduleClose(pane_id) catch {};
        controller.layout_dirty = true;
        controller.layout_due_ns = 0;
        @import("htp.zig").bindHtpHandlers(app);
        app.syncActivePaneChange(previous, mux.activePane());
        if (mux.activePane() == pane) app.refreshActivePaneDisplay();
        app.requestLayoutResize(false);
        app.requestLayoutRefresh();
        if (is_tab and mux.activePane() == pane) app.emitLuaBuiltInEvent("term:tab_activated", .{ .tab_id = tab_id });
        complete(app, callback.callback_ref, callback.generation, true, if (is_tab) .{ .tab_id = tab_id } else .{ .pane_id = pane_id });
        return true;
    }
    return false;
}

fn canSave(controller: *const Controller) bool {
    return controller.layout_dirty and !controller.detached and !controller.spawn_active and !controller.close_work and
        controller.layout_request == null and controller.kill_request == null and !controller.layout_conflict and controller.pendingCloses() == 0;
}

pub fn nextLayoutWakeNs(app: *const App) i128 {
    const mux = if (app.mux) |*value| value else return 0;
    if (mux.session_workspace_count == 0) return 0;
    var result: i128 = 0;
    for (mux.workspaces.items) |ws| {
        const controller = ws.session_controller orelse continue;
        if (!canSave(controller)) continue;
        const due = if (controller.layout_due_ns == 0) io.nanoTimestamp() else controller.layout_due_ns;
        result = if (result == 0) due else @min(result, due);
    }
    return result;
}

pub fn saveLayouts(app: *App) void {
    const mux = if (app.mux) |*value| value else return;
    if (mux.session_workspace_count == 0) return;
    for (mux.workspaces.items) |ws| {
        const controller = ws.session_controller orelse continue;
        if (!canSave(controller) or io.nanoTimestamp() < controller.layout_due_ns) continue;
        const bytes = @import("../mux/session_layout.zig").capture(app.allocator, ws) catch |err| {
            controller.layout_dirty = false;
            report(app, err, .not_sent, null);
            continue;
        };
        defer app.allocator.free(bytes);
        _ = controller.requestLayout(bytes) catch |err| {
            if (err == error.ResourceExhausted) {
                app.signalWake();
                continue;
            }
            controller.layout_dirty = false;
            report(app, err, .not_sent, null);
            continue;
        };
        controller.layout_dirty = false;
    }
}

/// Quit flushes geometry the debounce has not written yet, then waits for
/// the owner's acknowledgement: tearing the connector down right after the
/// write could drop the frame before it reaches the owner.
pub const shutdown_flush_ns: i128 = 500 * std.time.ns_per_ms;

/// Quit path, before the mux is torn down. Bounded by `budget_ns` in total,
/// across every session workspace; never sends anything but layout saves.
pub fn flushLayouts(app: *App, budget_ns: i128) void {
    const mux = if (app.mux) |*value| value else return;
    if (mux.session_workspace_count == 0) return;
    var deadline: ?i128 = null;
    // An in-flight save must land first: its reply carries the revision the
    // final save is checked against.
    for (mux.workspaces.items) |ws| {
        const controller = ws.session_controller orelse continue;
        const id = controller.layout_request orelse continue;
        if (!controller.layout_dirty) continue;
        const end = deadline orelse controller.connection.clock() + budget_ns;
        deadline = end;
        controller.awaitReply(id, end) catch |err| std.log.warn("session layout flush: {s}", .{@errorName(err)});
    }
    for (mux.workspaces.items) |ws| {
        const controller = ws.session_controller orelse continue;
        if (!canSave(controller)) continue;
        controller.layout_dirty = false;
        const bytes = @import("../mux/session_layout.zig").capture(app.allocator, ws) catch |err| {
            std.log.warn("session layout flush: {s}", .{@errorName(err)});
            continue;
        };
        defer app.allocator.free(bytes);
        _ = controller.requestLayout(bytes) catch |err| std.log.warn("session layout flush: {s}", .{@errorName(err)});
    }
    for (mux.workspaces.items) |ws| {
        const controller = ws.session_controller orelse continue;
        const id = controller.layout_request orelse continue;
        const end = deadline orelse controller.connection.clock() + budget_ns;
        deadline = end;
        controller.awaitReply(id, end) catch |err| std.log.warn("session layout flush: {s}", .{@errorName(err)});
    }
}

pub fn shutdown(app: *App) void {
    for (0..max_pending) |index| {
        const op = app.session_spawns[index] orelse continue;
        if (app.lua) |*lua| if (lua.generation == op.lua_generation) lua.discardOperationCallback(op.callback_ref);
        _ = remove(app, index); // Teardown detaches; never send remote close.
    }
}

fn mockApp() !*App {
    const a = std.testing.allocator;
    const app = try a.create(App);
    app.* = App.init(a);
    errdefer {
        app.deinit();
        a.destroy(app);
    }
    app.ghostty = try @import("../term/ghostty.zig").Runtime.init(a, null);
    app.mux = Mux.init(a);
    app.mux.?.host_context = app;
    try app.config.setDomainShell("bound", "/bin/sh");
    try app.config.setDomainPersist("bound", true);
    app.lua = try @import("../lua_bridge.zig").Runtime.initForTests(a, &app.config);
    try app.lua.?.runString(
        \\hollow = {_session_host=function() return {mode='explicit',path_style='posix',
        \\ connector={argv={'ssh','test-host'}},agent={path='/fake-agent'}} end}
    );
    const connection = try a.create(transport.Connection);
    var owned = false;
    errdefer if (!owned) connection.destroy();
    connection.* = .{
        .allocator = a,
        .io = io.get(),
        .arena = .init(a),
        .options = .{ .ghostty_identity = "test", .connector = .{ .argv = &.{ "ssh", "test-host" } }, .agent = .{ .path = "/fake-agent" } },
        .client = .{ .allocator = a, .identity = "test" },
    };
    const welcome = try p.stringify(a, p.Welcome{ .ghostty = "test", .snapshot = .binary, .owner_pid = 1 });
    defer a.free(welcome);
    try connection.client.receive(p.header(.welcome, 0, welcome.len), welcome);
    connection.poll().?.deinit();
    const request = try connection.request(.{ .id = 0, .op = .attach, .session = "mock" });
    connection.client.nextWrite().?.deinit();
    const info: p.SessionInfo = .{ .id = "mock", .attached = true, .revision = 0, .panes = &.{.{ .id = 1, .cols = 80, .rows = 24 }} };
    try mockReply(connection, .{ .id = request, .session = info });
    connection.poll().?.deinit();
    _ = try @import("session_controller.zig").addSessionWorkspace(app, connection, info, "bound");
    owned = true;
    return app;
}

fn mockReply(connection: *transport.Connection, value: p.Reply) !void {
    const bytes = try p.stringify(std.testing.allocator, value);
    defer std.testing.allocator.free(bytes);
    try connection.client.receive(p.header(.reply, 0, bytes.len), bytes);
}

fn mockPump(app: *App) void {
    @import("session_controller.zig").pumpSessionControllers(app, &app.ghostty.?);
}

test "session borrowers owner tab spawn waits for acknowledgement and saves geometry" {
    const a = std.testing.allocator;
    const app = try mockApp();
    defer a.destroy(app);
    defer app.deinit();
    const ws = app.activeWorkspace().?;
    const controller = ws.session_controller.?;
    const connection = controller.connection;
    try newTab(app, null, null, "cd /work", -1, false);
    try std.testing.expectEqual(@as(usize, 1), ws.tabs.items.len);
    try std.testing.expectError(error.SessionBusy, newTab(app, null, null, null, -1, false));
    mockPump(app);
    const outgoing = connection.client.nextWrite().?;
    defer outgoing.deinit();
    const request = try p.parse(p.Request, a, outgoing.payload);
    defer request.deinit();
    try std.testing.expectEqual(p.Op.spawn, request.value.op);
    try std.testing.expect(request.value.spawn.?.command == null);
    try std.testing.expectEqualStrings("/bin/sh", request.value.spawn.?.argv[0]);
    try mockReply(connection, .{ .id = request.value.id, .pane = 2, .revision = 1 });
    try connection.client.receive(p.header(.output, 2, 5), "child");
    mockPump(app);
    try std.testing.expectEqual(@as(usize, 2), ws.tabs.items.len);
    const pane = app.activePane().?;
    try std.testing.expect(pane.content.terminal.terminal_output_ready);
    try std.testing.expectEqualStrings("cd /work\r", pane.content.terminal.pending_startup_input);
    try std.testing.expectEqual(@as(usize, 5), pane.content.terminal.pty.?.session.pendingOutputBytes());
    try std.testing.expectEqual(@as(usize, 0), app.session_spawn_count);
    const receipt_credit = connection.client.nextWrite().?;
    defer receipt_credit.deinit();
    try std.testing.expectEqual(p.Kind.credit, receipt_credit.kind);
    try std.testing.expectEqual(@as(u32, 2), receipt_credit.pane);
    const save = connection.client.nextWrite().?;
    defer save.deinit();
    const layout_request = try p.parse(p.Request, a, save.payload);
    defer layout_request.deinit();
    try std.testing.expectEqual(p.Op.layout, layout_request.value.op);
    try std.testing.expectEqual(@as(?u64, 1), layout_request.value.revision);
    const layout = try @import("../session/layout.zig").decode(a, layout_request.value.layout.?, &.{ 1, 2 });
    defer layout.deinit();
    try std.testing.expectEqual(@as(usize, 2), layout.value.tabs.len);
    try mockReply(connection, .{ .id = layout_request.value.id, .revision = 2 });
    mockPump(app);
    try std.testing.expect(controller.layout_request == null and !controller.layout_dirty);
}

test "session borrowers pending split coalesces layout changes behind acknowledged save" {
    const a = std.testing.allocator;
    const app = try mockApp();
    defer a.destroy(app);
    defer app.deinit();
    const ws = app.activeWorkspace().?;
    const connection = ws.session_controller.?.connection;
    try split(app, .{ .split = .{ .tab_id = ws.active_tab.?.id, .source_id = app.activePane().?.id, .direction = .horizontal, .ratio = 0.3 } }, null, null, null, .send, false, -1);
    mockPump(app);
    const request = connection.client.nextWrite().?;
    const id = request.request_id.?;
    request.deinit();
    try mockReply(connection, .{ .id = id, .pane = 2, .revision = 1 });
    mockPump(app);
    try std.testing.expectEqual(@as(usize, 2), ws.active_tab.?.panes.items.len);
    try std.testing.expectEqual(@as(f32, 0.7), ws.active_tab.?.root_split.?.ratio);
    const save = connection.client.nextWrite().?;
    defer save.deinit();
    app.requestLayoutRefresh();
    mockPump(app);
    try std.testing.expect(connection.client.nextWrite() == null);
    try mockReply(connection, .{ .id = save.request_id.?, .revision = 2 });
    mockPump(app);
    try std.testing.expect(connection.client.nextWrite() == null);
    try std.testing.expect(app.nextIdleWakeNs() > 0);
    ws.session_controller.?.layout_due_ns = 0; // Model settled geometry deadline.
    mockPump(app);
    const latest = connection.client.nextWrite().?;
    defer latest.deinit();
    const parsed = try p.parse(p.Request, a, latest.payload);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?u64, 2), parsed.value.revision);
}

test "session borrowers workspace close waits for pending spawn and includes its child" {
    const a = std.testing.allocator;
    const app = try mockApp();
    defer a.destroy(app);
    defer app.deinit();
    const ws = app.activeWorkspace().?;
    const connection = ws.session_controller.?.connection;
    try newTab(app, null, null, null, -1, false);
    mockPump(app);
    const request = connection.client.nextWrite().?;
    const id = request.request_id.?;
    request.deinit();
    @import("session_controller.zig").closeWorkspace(app, null);
    mockPump(app);
    try std.testing.expect(connection.client.nextWrite() == null);
    try mockReply(connection, .{ .id = id, .pane = 2, .revision = 1 });
    mockPump(app);
    mockPump(app);
    var requests: [2]u64 = undefined;
    for (&requests) |*value| {
        const close = connection.client.nextWrite().?;
        defer close.deinit();
        const parsed = try p.parse(p.Request, a, close.payload);
        defer parsed.deinit();
        try std.testing.expectEqual(p.Op.close, parsed.value.op);
        value.* = parsed.value.id;
    }
    try std.testing.expect(connection.client.nextWrite() == null);
    for (requests, 2..) |value, revision| {
        try mockReply(connection, .{ .id = value, .revision = revision });
        mockPump(app);
    }
    try std.testing.expectEqual(@as(usize, 0), app.mux.?.workspaces.items.len);
}

test "session borrowers spawn rejects changed host and never replays a lost reply" {
    const a = std.testing.allocator;
    const app = try mockApp();
    defer a.destroy(app);
    defer app.deinit();
    const controller = app.activeWorkspace().?.session_controller.?;
    const connection = controller.connection;
    try std.testing.expectError(error.CrossSessionDomain, newTab(app, null, "other", null, -1, false));
    try app.lua.?.runString("hollow._session_host=function() return {mode='explicit',path_style='posix',connector={argv={'ssh','other-host'}},agent={path='/fake-agent'}} end");
    try std.testing.expectError(error.SessionHostChanged, newTab(app, null, null, null, -1, false));
    try std.testing.expectEqual(@as(usize, 0), app.session_spawn_count);
    try app.lua.?.runString("hollow._session_host=function() return {mode='explicit',path_style='posix',connector={argv={'ssh','test-host'}},agent={path='/fake-agent'}} end");
    try newTab(app, null, null, null, -1, false);
    mockPump(app);
    connection.client.nextWrite().?.deinit();
    connection.client.ended = true;
    connection.finished = true;
    pump(app);
    try std.testing.expectEqual(@as(usize, 0), app.session_spawn_count);
    try std.testing.expect(!controller.spawn_active);
    try std.testing.expectEqual(@as(u64, 3), connection.client.next_id); // attach + spawn only.
    try std.testing.expect(app.session_notices.current().?.outcome == .uncertain);
}

test "session borrowers acknowledged spawn allocation failure detaches instead of routing unbound data" {
    const a = std.testing.allocator;
    const app = try mockApp();
    defer a.destroy(app);
    defer app.deinit();
    const controller = app.activeWorkspace().?.session_controller.?;
    const connection = controller.connection;
    try newTab(app, null, null, null, -1, false);
    mockPump(app);
    const request = connection.client.nextWrite().?;
    const id = request.request_id.?;
    request.deinit();
    try mockReply(connection, .{ .id = id, .pane = 2, .revision = 1 });
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    app.mux.?.allocator = failing.allocator();
    defer app.mux.?.allocator = a;
    mockPump(app);
    try std.testing.expect(controller.detached);
    try std.testing.expectEqual(@as(usize, 0), app.session_spawn_count);
    try std.testing.expectEqual(@as(usize, 1), app.activeWorkspace().?.tabs.items.len);
    try std.testing.expect(app.session_notices.current().?.outcome == .uncertain);
}

test "session borrowers background spawn does not scroll unrelated active pane" {
    const a = std.testing.allocator;
    const app = try mockApp();
    defer a.destroy(app);
    defer app.deinit();
    const connection = app.activeWorkspace().?.session_controller.?.connection;
    try newTab(app, null, null, null, -1, false);
    mockPump(app);
    const request = connection.client.nextWrite().?;
    const id = request.request_id.?;
    request.deinit();
    const Pane = @import("../pane.zig").Pane;
    const other = try a.create(Pane);
    other.* = Pane.init(a);
    other.id = app.mux.?.reservePaneId();
    other.content.terminal.terminal = try app.ghostty.?.createTerminal(20, 5, 10000);
    try app.mux.?.newWorkspaceWithPane(&app.ghostty.?, other, null);
    for (0..40) |_| app.ghostty.?.terminalWrite(other.content.terminal.terminal, "history\r\n");
    app.ghostty.?.terminalScrollTop(other.content.terminal.terminal);
    const before = app.ghostty.?.terminalScrollbar(other.content.terminal.terminal).?;
    try std.testing.expect(before.total > before.len);
    try mockReply(connection, .{ .id = id, .pane = 2, .revision = 1 });
    mockPump(app);
    try std.testing.expect(app.activePane() == other);
    try std.testing.expectEqual(before.offset, app.ghostty.?.terminalScrollbar(other.content.terminal.terminal).?.offset);
}

test "session borrowers workspace rename persists without another layout action" {
    const a = std.testing.allocator;
    const app = try mockApp();
    defer a.destroy(app);
    defer app.deinit();
    const controller = app.activeWorkspace().?.session_controller.?;
    @import("session_controller.zig").setWorkspaceName(app, "renamed-session");
    try std.testing.expect(app.nextIdleWakeNs() > 0);
    controller.layout_due_ns = 0;
    mockPump(app);
    const save = controller.connection.client.nextWrite().?;
    defer save.deinit();
    const request = try p.parse(p.Request, a, save.payload);
    defer request.deinit();
    const layout = try @import("../session/layout.zig").decode(a, request.value.layout.?, &.{1});
    defer layout.deinit();
    try std.testing.expectEqualStrings("renamed-session", layout.value.name.?);
}

test "session borrowers quit flushes a debounced layout behind the in-flight save" {
    const a = std.testing.allocator;
    const app = try mockApp();
    defer a.destroy(app);
    defer app.deinit();
    const controller = app.activeWorkspace().?.session_controller.?;
    const connection = controller.connection;
    @import("session_controller.zig").setWorkspaceName(app, "first-name");
    controller.layout_due_ns = 0;
    mockPump(app);
    const first = connection.client.nextWrite().?;
    const first_id = first.request_id.?;
    first.deinit();
    // Renamed again within the debounce window, with the first save unanswered.
    @import("session_controller.zig").setWorkspaceName(app, "final-name");
    try std.testing.expect(controller.layout_due_ns > io.nanoTimestamp());
    try mockReply(connection, .{ .id = first_id, .revision = 5 });
    flushLayouts(app, 0);
    try std.testing.expectEqual(@as(u64, 5), controller.revision);
    try std.testing.expect(!controller.layout_dirty);
    const final = connection.client.nextWrite().?;
    defer final.deinit();
    const request = try p.parse(p.Request, a, final.payload);
    defer request.deinit();
    try std.testing.expectEqual(p.Op.layout, request.value.op);
    try std.testing.expectEqual(@as(?u64, 5), request.value.revision);
    const layout = try @import("../session/layout.zig").decode(a, request.value.layout.?, &.{1});
    defer layout.deinit();
    try std.testing.expectEqualStrings("final-name", layout.value.name.?);
    // Nothing else is sent at quit; a clean session flushes nothing.
    try std.testing.expect(connection.client.nextWrite() == null);
}

test "session borrowers acknowledged pane close saves only surviving owner structure" {
    const a = std.testing.allocator;
    const app = try mockApp();
    defer a.destroy(app);
    defer app.deinit();
    const ws = app.activeWorkspace().?;
    const controller = ws.session_controller.?;
    const connection = controller.connection;
    const parent_id = app.activePane().?.id;
    try newTab(app, null, null, null, -1, false);
    mockPump(app);
    const spawn = connection.client.nextWrite().?;
    const spawn_id = spawn.request_id.?;
    spawn.deinit();
    try mockReply(connection, .{ .id = spawn_id, .pane = 2, .revision = 1 });
    mockPump(app);
    const initial = connection.client.nextWrite().?;
    const initial_id = initial.request_id.?;
    initial.deinit();
    try mockReply(connection, .{ .id = initial_id, .revision = 2 });
    mockPump(app);
    @import("session_controller.zig").closePaneById(app, parent_id);
    mockPump(app);
    const close = connection.client.nextWrite().?;
    const close_id = close.request_id.?;
    close.deinit();
    try mockReply(connection, .{ .id = close_id, .revision = 3 });
    mockPump(app);
    try std.testing.expectEqual(@as(usize, 1), ws.tabs.items.len);
    const saved = connection.client.nextWrite().?;
    defer saved.deinit();
    const parsed = try p.parse(p.Request, a, saved.payload);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?u64, 3), parsed.value.revision);
    const layout = try @import("../session/layout.zig").decode(a, parsed.value.layout.?, &.{2});
    defer layout.deinit();
    try std.testing.expectEqual(@as(usize, 1), layout.value.tabs.len);
}
