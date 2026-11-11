//! Bounded GUI admission for asynchronous create/attach. Request strings and
//! callback generation are captured before starting a connector. No ordinary
//! shell fallback, no replay, and no transport joins from frame dispatch.
const std = @import("std");
const App = @import("../app.zig").App;
const transport = @import("../session/transport.zig");
const opener = @import("../session/open.zig");
const session_notice = @import("../session/notice.zig");
const mux_ops = @import("session_controller.zig");
const p = transport.p;
const no_ref: c_int = -1;
pub const max_pending = 16;

pub const StartupTarget = union(enum) {
    unbound,
    opening: u64,
    pane: usize,
    failed,
};

pub const Pending = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    operation: opener.Open,
    connection: ?*transport.Connection = null,
    id: u64,
    domain: ?[]const u8,
    name: ?[]const u8,
    startup_input: ?[]u8 = null,
    callback_ref: c_int,
    lua_generation: u64,
    state: enum { running, publishing, retiring } = .running,

    pub fn prepare(a: std.mem.Allocator, request: p.Request, domain: ?[]const u8, name: ?[]const u8, callback_ref: c_int, generation: u64, id: u64) !*Pending {
        return prepareWithInput(a, request, domain, name, callback_ref, generation, id, null);
    }

    pub fn prepareWithInput(a: std.mem.Allocator, request: p.Request, domain: ?[]const u8, name: ?[]const u8, callback_ref: c_int, generation: u64, id: u64, input: ?[]const u8) !*Pending {
        if (domain) |value| if (value.len == 0 or value.len > 256) return error.InvalidDomain;
        if (name) |value| if (value.len > 4096) return error.InvalidWorkspaceName;
        const self = try a.create(Pending);
        errdefer a.destroy(self);
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const owned_domain = if (domain) |value| try arena.allocator().dupe(u8, value) else null;
        const owned_name = if (name) |value| try arena.allocator().dupe(u8, value) else null;
        const startup_input: ?[]u8 = if (input) |value| blk: {
            if (value.len > 64 * 1024 or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidStartupInput;
            const suffix = if (std.mem.endsWith(u8, value, "\r") or std.mem.endsWith(u8, value, "\n")) "" else "\r";
            break :blk try std.mem.concat(a, u8, &.{ value, suffix });
        } else null;
        errdefer if (startup_input) |value| a.free(value);
        const operation = try opener.Open.prepare(a, request);
        self.* = .{
            .allocator = a,
            .arena = arena,
            .operation = operation,
            .id = id,
            .domain = owned_domain,
            .name = owned_name,
            .startup_input = startup_input,
            .callback_ref = callback_ref,
            .lua_generation = generation,
        };
        return self;
    }

    /// Called only before a connector starts, after EOF, or during shutdown.
    pub fn destroy(self: *Pending) void {
        if (self.connection) |connection| connection.destroy();
        self.operation.deinit();
        if (self.startup_input) |value| self.allocator.free(value);
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};

/// Admission only. Caller retains its Lua callback on failure; successful
/// admission invokes it once (or abandons its old-runtime ref after reload).
pub fn begin(app: *App, options: transport.Options, request: p.Request, domain: ?[]const u8, name: ?[]const u8, callback_ref: c_int) !u64 {
    return beginWithInput(app, options, request, domain, name, callback_ref, null);
}

pub fn beginWithInput(app: *App, options: transport.Options, request: p.Request, domain: ?[]const u8, name: ?[]const u8, callback_ref: c_int, input: ?[]const u8) !u64 {
    if (app.mux == null or app.ghostty == null) return error.MuxUnavailable;
    if (app.session_open_next_id == std.math.maxInt(u64)) return error.ResourceExhausted;
    var index: ?usize = null;
    for (app.session_opens, 0..) |entry, i| if (entry == null) {
        index = i;
        break;
    };
    const slot = index orelse return error.ResourceExhausted;
    const id = app.session_open_next_id;
    const pending = try Pending.prepareWithInput(app.allocator, request, domain, name, callback_ref, if (app.lua) |*lua| lua.generation else 0, id, input);
    errdefer pending.destroy();
    // All fallible request/metadata setup precedes spawning transport work.
    const connection = try mux_ops.createSessionConnection(app, options);
    pending.connection = connection;
    pending.operation.bind(connection);
    app.session_opens[slot] = pending;
    app.session_open_count += 1;
    app.session_open_next_id += 1;
    _ = app.session_notices.start(id);
    app.requestRedraw();
    return id;
}

pub fn beginStartup(app: *App, options: transport.Options, request: p.Request, domain: ?[]const u8, name: ?[]const u8) !u64 {
    if (app.startup_session_target != .unbound) return error.StartupAlreadyAdmitted;
    const id = try begin(app, options, request, domain, name, no_ref);
    app.startup_session_target = .{ .opening = id };
    return id;
}

/// Configuration/validation failure before transport admission still needs a
/// visible empty-window error. Reserve its notice ID so later opens cannot
/// accidentally dismiss the wrong warning.
pub fn reportAdmissionFailure(app: *App, reason: anyerror, startup: bool) void {
    const id = app.session_open_next_id;
    if (id != std.math.maxInt(u64)) app.session_open_next_id += 1;
    if (startup) app.startup_session_target = .failed;
    _ = app.session_notices.failed(id, reason, .not_sent);
    app.requestRedraw();
}

/// Mirrors notices into Lua notifications (and the attention history). The
/// native panel keeps any notice Lua could not show.
pub fn syncNotices(app: *App) void {
    const Sink = struct {
        app: *App,

        pub fn show(self: @This(), value: session_notice.Notice) bool {
            const lua = if (self.app.lua) |*lua| lua else return false;
            var text: session_notice.Text = .{};
            text.format(value);
            var buf: [192]u8 = undefined;
            var len: usize = 0;
            for (text.lines[1..text.count], 0..) |line, i| {
                const sep: []const u8 = if (i == 0) "" else "\n";
                const piece = std.fmt.bufPrint(buf[len..], "{s}{s}", .{ sep, line }) catch break;
                len += piece.len;
            }
            const level = if (value.state == .connecting) "info" else if (value.outcome == .uncertain) "warn" else "error";
            return lua.emitBuiltInEventChecked("session:notice", .{ .session_notice = .{
                .id = value.id,
                .connecting = value.state == .connecting,
                .level = level,
                .title = text.lines[0],
                .message = buf[0..len],
            } });
        }

        pub fn close(self: @This(), id: u64) void {
            if (self.app.lua) |*lua| lua.emitBuiltInEvent("session:notice", .{ .session_notice = .{ .id = id, .close = true } });
        }
    };
    app.session_notices.sync(Sink{ .app = app });
}

/// A pointer click is deliberate cancellation/dismissal, never a retry. Do not
/// silently duplicate a create whose reply might have been lost. Native clicks
/// target the visible panel; Lua notifications target their own notice.
pub fn activateNotice(app: *App, id: u64) void {
    const current = app.session_notices.get(id) orelse return;
    if (!current.published) {
        const visible = app.session_notices.currentNative() orelse return;
        if (visible.id != id) return;
    }
    if (current.state == .connecting) {
        _ = cancel(app, id);
    } else if (app.session_notices.clear(id)) app.requestRedraw();
}

pub fn cancel(app: *App, id: u64) bool {
    for (app.session_opens) |entry| if (entry) |pending| {
        if (pending.id != id or pending.state != .running) continue;
        const failure = pending.operation.cancel();
        retire(app, pending, failure.reason, failure.outcome, failure.remote);
        return true;
    };
    return false;
}

pub fn hasLiveOpen(app: *const App) bool {
    if (app.session_open_count == 0) return false;
    for (app.session_opens) |entry| if (entry) |pending| {
        if (pending.state != .retiring) return true;
    };
    return false;
}

pub fn pump(app: *App) void {
    if (app.session_open_count == 0) return;
    // Fixed slots remain stable across Lua callbacks that admit more opens.
    for (0..max_pending) |index| {
        const pending = app.session_opens[index] orelse continue;
        if (pending.state == .publishing) continue;
        if (pending.state == .retiring) {
            if (pending.connection.?.status().phase == .ended) {
                app.session_opens[index] = null;
                app.session_open_count -= 1;
                pending.destroy();
            }
            continue;
        }
        if (pending.connection.?.takeHandoff()) |handoff| mux_ops.reportHandoff(app, handoff);
        const step = pending.operation.step() catch |err| {
            const failure = pending.operation.cancel();
            retire(app, pending, err, failure.outcome, null);
            continue;
        };
        switch (step) {
            .pending => {},
            .failed => |failure| retire(app, pending, failure.reason, failure.outcome, failure.remote),
            .attached => |attachment| {
                defer attachment.deinit();
                pending.state = .publishing;
                const info = attachment.reply.value.session.?;
                const workspace = mux_ops.addSessionWorkspaceNamed(app, pending.connection.?, info, pending.domain, pending.name) catch |err| {
                    // Owner has already created/attached. Do not kill its pane
                    // or replay create just because GUI allocation failed.
                    std.log.err("session {s} attached but view publication failed: {s}", .{ info.id, @errorName(err) });
                    pending.connection.?.close();
                    retire(app, pending, err, .uncertain, null);
                    continue;
                };
                const workspace_id = workspace.id;
                const operation_id = pending.id;
                if (pending.startup_input) |value| {
                    const term = workspace.activeTab().?.activePane().?.asTerminal().?;
                    std.debug.assert(term.pending_startup_input_capacity == 0);
                    term.pending_startup_input = value;
                    term.pending_startup_input_capacity = value.len;
                    term.startup_input_quiet_ticks = 0;
                    pending.startup_input = null; // View owns prepared buffer now.
                }
                // Initial geometry/name belongs to this new session only.
                // Attach must never silently overwrite a saved owner layout.
                // Splits inherit this before the shell reports a cwd (and
                // forever for programs like nvim that never do).
                if (pending.operation.request.op == .create) if (pending.operation.request.spawn) |spawn| {
                    workspace.setDefaultCwd(spawn.cwd) catch |err| std.log.warn("session default cwd failed: {s}", .{@errorName(err)});
                };
                if (pending.operation.request.op == .create) save_initial: {
                    const bytes = @import("../mux/session_layout.zig").capture(app.allocator, workspace) catch |err| {
                        std.log.warn("initial session geometry capture failed: {s}", .{@errorName(err)});
                        break :save_initial;
                    };
                    defer app.allocator.free(bytes);
                    _ = workspace.session_controller.?.requestLayout(bytes) catch |err| blk: {
                        std.log.warn("initial session geometry admission failed: {s}", .{@errorName(err)});
                        break :blk 0;
                    };
                }
                if (app.startup_session_target == .opening and app.startup_session_target.opening == operation_id) {
                    app.startup_session_target = if (workspace.activeTab()) |tab|
                        (if (tab.activePane()) |pane| .{ .pane = pane.id } else .failed)
                    else
                        .failed;
                }
                pending.connection = null; // Ownership now belongs to App controller.
                const callback_ref = pending.callback_ref;
                const generation = pending.lua_generation;
                app.session_opens[index] = null;
                app.session_open_count -= 1;
                pending.destroy();
                if (app.session_notices.clear(operation_id)) app.requestRedraw();
                var workspace_index: ?usize = null;
                if (app.mux) |*mux| for (mux.workspaces.items, 0..) |value, i| {
                    if (value.id == workspace_id) {
                        workspace_index = i;
                        break;
                    }
                };
                complete(app, callback_ref, generation, workspace_index);
            },
        }
    }
}

fn retire(app: *App, pending: *Pending, reason: anyerror, outcome: opener.Outcome, remote: ?[]const u8) void {
    pending.state = .retiring;
    pending.connection.?.close();
    const callback_ref = pending.callback_ref;
    pending.callback_ref = no_ref;
    const recovery = if (outcome == .uncertain) pending.operation.recoverySession() else null;
    if (app.startup_session_target == .opening and app.startup_session_target.opening == pending.id) app.startup_session_target = .failed;
    if (reason == error.Canceled and outcome == .not_sent) {
        _ = app.session_notices.clear(pending.id);
    } else {
        _ = app.session_notices.failedWithRecovery(pending.id, reason, outcome, remote, recovery);
    }
    app.requestRedraw();
    std.log.warn("session workspace open failed: {s} ({s}; not replayed)", .{ @errorName(reason), @tagName(outcome) });
    if (recovery) |sid| std.log.warn("recover session {s} in domain {s}; list/attach explicitly, do not recreate", .{ sid, pending.domain orelse "default" });
    if (app.lua) |*lua| if (lua.generation == pending.lua_generation) {
        lua.invokeOperationCallback(callback_ref, false, .{ .failure = .{ .reason = @errorName(reason), .outcome = @tagName(outcome), .remote = remote, .session_id = recovery } });
    };
}

fn complete(app: *App, callback_ref: c_int, generation: u64, workspace_index: ?usize) void {
    if (app.lua) |*lua| {
        if (lua.generation != generation) return; // Old registry died with old runtime.
        lua.invokeOperationCallback(callback_ref, workspace_index != null, if (workspace_index) |index| .{ .workspace_index = index } else .none);
    }
}

pub fn shutdown(app: *App) void {
    for (&app.session_opens) |*slot| if (slot.*) |pending| {
        slot.* = null;
        if (app.lua) |*lua| if (lua.generation == pending.lua_generation) lua.discardOperationCallback(pending.callback_ref);
        _ = pending.operation.cancel();
        pending.destroy();
    };
    app.session_open_count = 0;
    app.session_notices = .{};
}

fn mockConnection(a: std.mem.Allocator) !*transport.Connection {
    const connection = try a.create(transport.Connection);
    errdefer a.destroy(connection);
    connection.* = .{
        .allocator = a,
        .io = @import("../io.zig").get(),
        .arena = .init(a),
        .options = .{ .ghostty_identity = "test" },
        .client = .{ .allocator = a, .identity = "test" },
    };
    errdefer {
        connection.client.deinit();
        connection.arena.deinit();
    }
    const welcome = try p.stringify(a, p.Welcome{ .ghostty = "test", .snapshot = .binary, .owner_pid = 1 });
    defer a.free(welcome);
    try connection.client.receive(p.header(.welcome, 0, welcome.len), welcome);
    return connection;
}

test "session borrowers pending create publishes views before subsequent output dispatch" {
    const a = std.testing.allocator;
    const app = try a.create(App);
    defer a.destroy(app);
    app.* = App.init(a);
    defer app.deinit();
    app.ghostty = try @import("../term/ghostty.zig").Runtime.init(a, null);
    app.mux = @import("../mux.zig").Mux.init(a);
    var domain = "captured-domain".*;
    var name = "captured-name".*;
    const pending = try Pending.prepareWithInput(a, .{ .id = 0, .op = .create, .spawn = .{} }, &domain, &name, no_ref, 0, 1, "cd /project");
    @memset(&domain, 'x');
    @memset(&name, 'x');
    app.session_opens[0] = pending;
    app.session_open_count = 1;
    _ = app.session_notices.start(1);
    app.startup_session_target = .{ .opening = 1 };
    const connection = try mockConnection(a);
    pending.connection = connection;
    pending.operation.bind(connection);
    pump(app);
    try std.testing.expectEqual(@as(usize, 0), app.mux.?.workspaces.items.len);
    mux_ops.closeTab(app);
    try std.testing.expect(!app.pending_quit);
    app.startup_command = try a.dupe(u8, "startup-command");
    app.frame_count = app.startup_command_delay_frames;
    mux_ops.maybeRunStartupCommand(app);
    try std.testing.expect(!app.startup_command_sent);
    const outgoing = connection.client.nextWrite().?;
    defer outgoing.deinit();
    const request = try p.parse(p.Request, a, outgoing.payload);
    defer request.deinit();
    const body = try p.stringify(a, p.Reply{ .id = request.value.id, .session = .{
        .id = "created",
        .attached = true,
        .revision = 0,
        .panes = &.{.{ .id = 1, .cols = 80, .rows = 24 }},
    } });
    defer a.free(body);
    try connection.client.receive(p.header(.reply, 0, body.len), body);
    try connection.client.receive(p.header(.output, 1, 4), "tail");
    pump(app);
    try std.testing.expect(app.session_opens[0] == null);
    try std.testing.expectEqual(@as(usize, 0), app.session_open_count);
    try std.testing.expectEqual(@as(usize, 1), app.session_controllers.items.len);
    try std.testing.expect(app.session_notices.current() == null);
    try std.testing.expectEqual(app.activePane().?.id, app.startup_session_target.pane);
    try std.testing.expectEqualStrings("captured-name", app.mux.?.activeWorkspace().?.name.?);
    try std.testing.expectEqualStrings("captured-domain", app.activePane().?.domainName());
    mux_ops.maybeRunStartupCommand(app);
    try std.testing.expect(app.startup_command_sent);
    try std.testing.expectEqualStrings("cd /project\rstartup-command\r", app.activePane().?.content.terminal.pending_startup_input);
    try std.testing.expectEqual(@as(usize, 1), connection.status().queued_frames);
    mux_ops.pumpSessionControllers(app, &app.ghostty.?);
    try std.testing.expectEqual(@as(usize, 4), app.activePane().?.content.terminal.pty.?.session.pendingOutputBytes());
}

test "session borrowers pending open cancel retires without blocking or publishing" {
    const a = std.testing.allocator;
    const app = try a.create(App);
    defer a.destroy(app);
    app.* = App.init(a);
    defer app.deinit();
    const pending = try Pending.prepare(a, .{ .id = 0, .op = .attach, .session = "existing" }, null, null, no_ref, 0, 9);
    app.session_opens[0] = pending;
    app.session_open_count = 1;
    _ = app.session_notices.start(9);
    app.startup_session_target = .{ .opening = 9 };
    const connection = try mockConnection(a);
    pending.connection = connection;
    pending.operation.bind(connection);
    try std.testing.expect(cancel(app, 9));
    try std.testing.expect(!cancel(app, 9));
    try std.testing.expectEqual(@as(c_int, no_ref), pending.callback_ref);
    try std.testing.expect(pending.state == .retiring);
    try std.testing.expect(app.startup_session_target == .failed);
    try std.testing.expect(app.session_notices.current() == null);
    pump(app);
    try std.testing.expect(app.session_opens[0] == pending);
    connection.finished = true;
    pump(app);
    try std.testing.expect(app.session_opens[0] == null);
    try std.testing.expectEqual(@as(usize, 0), app.session_open_count);
    try std.testing.expectEqual(@as(usize, 0), app.session_controllers.items.len);
}

fn prepareAllocation(a: std.mem.Allocator) !void {
    const pending = try Pending.prepareWithInput(a, .{ .id = 0, .op = .create, .spawn = .{ .cwd = "/captured", .argv = &.{"sh"} } }, "domain", "name", no_ref, 7, 1, "cd /project");
    defer pending.destroy();
}

test "session borrowers pending open preparation allocation rollback" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, prepareAllocation, .{});
}

test "session borrowers pending open admission rejects exhausted capacity before connecting" {
    const a = std.testing.allocator;
    const app = try a.create(App);
    defer a.destroy(app);
    app.* = App.init(a);
    defer app.deinit();
    app.ghostty = try @import("../term/ghostty.zig").Runtime.init(a, null);
    app.mux = @import("../mux.zig").Mux.init(a);
    for (&app.session_opens, 0..) |*slot, i| {
        slot.* = try Pending.prepare(a, .{ .id = 0, .op = .create, .spawn = .{} }, null, null, no_ref, 0, i + 1);
    }
    app.session_open_count = max_pending;
    try std.testing.expectError(error.ResourceExhausted, begin(app, .{ .ghostty_identity = "test" }, .{ .id = 0, .op = .create, .spawn = .{} }, null, null, no_ref));
    try std.testing.expectEqual(@as(u64, 1), app.session_open_next_id);
}

test "session borrowers domain snapshot tolerates no active pane" {
    const a = std.testing.allocator;
    const app = try a.create(App);
    defer a.destroy(app);
    app.* = App.init(a);
    defer app.deinit();
    const value = try app.domainValue("future-domain");
    defer @import("../app.zig").deinitJsonValue(a, value);
    try std.testing.expect(!value.object.get("is_active").?.bool);
}

test "session borrowers uncertain cancellation remains visible until deliberately dismissed" {
    const a = std.testing.allocator;
    const app = try a.create(App);
    defer a.destroy(app);
    app.* = App.init(a);
    defer app.deinit();
    const pending = try Pending.prepare(a, .{ .id = 0, .op = .create, .spawn = .{} }, null, null, no_ref, 0, 3);
    app.session_opens[0] = pending;
    app.session_open_count = 1;
    _ = app.session_notices.start(3);
    const connection = try mockConnection(a);
    pending.connection = connection;
    pending.operation.bind(connection);
    pump(app);
    connection.client.nextWrite().?.deinit(); // Submitted, cannot assume not sent.
    const before = app.wake_generation.load(.monotonic);
    activateNotice(app, 3);
    const notice = app.session_notices.current().?;
    try std.testing.expect(notice.state == .failed and notice.outcome == .uncertain);
    try std.testing.expect(app.wake_generation.load(.monotonic) != before);
    activateNotice(app, 2); // Stale click must not dismiss another operation.
    try std.testing.expect(app.session_notices.current() != null);
    activateNotice(app, 3);
    try std.testing.expect(app.session_notices.current() == null);
    try std.testing.expectEqual(@as(u64, 2), connection.client.next_id);
}

test "session borrowers lost create reply retains recovery ID after opener retirement" {
    const a = std.testing.allocator;
    const app = try a.create(App);
    defer a.destroy(app);
    app.* = App.init(a);
    defer app.deinit();
    const pending = try Pending.prepare(a, .{ .id = 0, .op = .create, .spawn = .{} }, "captured-domain", null, no_ref, 0, 3);
    app.session_opens[0] = pending;
    app.session_open_count = 1;
    const connection = try mockConnection(a);
    pending.connection = connection;
    pending.operation.bind(connection);
    connection.client.create_id_supported = true;
    const sid: [32]u8 = pending.operation.request.create_id.?[0..32].*;
    pump(app);
    connection.client.nextWrite().?.deinit();
    connection.client.ended = true;
    connection.finished = true;
    pump(app);
    try std.testing.expectEqual(@as(?[32]u8, sid), app.session_notices.current().?.recovery_session);
    try std.testing.expectEqual(@as(u64, 2), connection.client.next_id);
    pump(app); // Retire transport and opener, not the recovery notice.
    try std.testing.expectEqual(@as(usize, 0), app.session_open_count);
    try std.testing.expectEqual(@as(?[32]u8, sid), app.session_notices.current().?.recovery_session);
}

test "session borrowers startup command targets its own pane without changing focus" {
    const a = std.testing.allocator;
    const app = try a.create(App);
    defer a.destroy(app);
    app.* = App.init(a);
    defer app.deinit();
    app.ghostty = try @import("../term/ghostty.zig").Runtime.init(a, null);
    app.mux = @import("../mux.zig").Mux.init(a);
    const Pane = @import("../pane.zig").Pane;
    var panes: [2]*Pane = undefined;
    for (&panes) |*slot| {
        const pane = try a.create(Pane);
        pane.* = Pane.init(a);
        pane.id = app.mux.?.reservePaneId();
        try pane.content.terminal.queuePendingRawInput(a, "seed:");
        try app.mux.?.newWorkspaceWithPane(&app.ghostty.?, pane, null);
        slot.* = pane;
    }
    app.startup_command = try a.dupe(u8, "startup-command");
    app.frame_count = app.startup_command_delay_frames;
    app.startup_session_target = .{ .opening = 10 };
    mux_ops.maybeRunStartupCommand(app);
    try std.testing.expect(!app.startup_command_sent);
    app.startup_session_target = .failed;
    mux_ops.maybeRunStartupCommand(app);
    try std.testing.expect(!app.startup_command_sent);
    const target_id = panes[0].id;
    app.startup_session_target = .{ .pane = target_id };
    mux_ops.maybeRunStartupCommand(app);
    try std.testing.expect(app.startup_command_sent);
    try std.testing.expect(app.activePane() == panes[1]);
    try std.testing.expectEqualStrings("seed:startup-command\r", panes[0].content.terminal.pending_startup_input);
    try std.testing.expectEqualStrings("seed:", panes[1].content.terminal.pending_startup_input);
    _ = app.mux.?.closePaneById(&app.ghostty.?, target_id);
    app.startup_command_sent = false;
    mux_ops.maybeRunStartupCommand(app);
    try std.testing.expect(!app.startup_command_sent);
    try std.testing.expectEqualStrings("seed:", panes[1].content.terminal.pending_startup_input);
}
