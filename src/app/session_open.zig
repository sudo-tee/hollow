//! Bounded GUI admission for asynchronous create/attach. Request strings and
//! callback generation are captured before starting a connector. No ordinary
//! shell fallback, no replay, and no transport joins from frame dispatch.
const std = @import("std");
const App = @import("../app.zig").App;
const transport = @import("../session/transport.zig");
const opener = @import("../session/open.zig");
const mux_ops = @import("session_controller.zig");
const p = transport.p;
const no_ref: c_int = -1;
pub const max_pending = 16;

pub const Pending = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    operation: opener.Open,
    connection: ?*transport.Connection = null,
    id: u64,
    domain: ?[]const u8,
    name: ?[]const u8,
    callback_ref: c_int,
    lua_generation: u64,
    state: enum { running, publishing, retiring } = .running,

    pub fn prepare(a: std.mem.Allocator, request: p.Request, domain: ?[]const u8, name: ?[]const u8, callback_ref: c_int, generation: u64, id: u64) !*Pending {
        if (domain) |value| if (value.len == 0 or value.len > 256) return error.InvalidDomain;
        if (name) |value| if (value.len > 4096) return error.InvalidWorkspaceName;
        const self = try a.create(Pending);
        errdefer a.destroy(self);
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const owned_domain = if (domain) |value| try arena.allocator().dupe(u8, value) else null;
        const owned_name = if (name) |value| try arena.allocator().dupe(u8, value) else null;
        const operation = try opener.Open.prepare(a, request);
        self.* = .{
            .allocator = a,
            .arena = arena,
            .operation = operation,
            .id = id,
            .domain = owned_domain,
            .name = owned_name,
            .callback_ref = callback_ref,
            .lua_generation = generation,
        };
        return self;
    }

    /// Called only before a connector starts, after EOF, or during shutdown.
    pub fn destroy(self: *Pending) void {
        if (self.connection) |connection| connection.destroy();
        self.operation.deinit();
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};

/// Admission only. Caller retains its Lua callback on failure; successful
/// admission invokes it once (or abandons its old-runtime ref after reload).
pub fn begin(app: *App, options: transport.Options, request: p.Request, domain: ?[]const u8, name: ?[]const u8, callback_ref: c_int) !u64 {
    if (app.mux == null or app.ghostty == null) return error.MuxUnavailable;
    if (app.session_open_next_id == std.math.maxInt(u64)) return error.ResourceExhausted;
    var index: ?usize = null;
    for (app.session_opens, 0..) |entry, i| if (entry == null) {
        index = i;
        break;
    };
    const slot = index orelse return error.ResourceExhausted;
    const id = app.session_open_next_id;
    const pending = try Pending.prepare(app.allocator, request, domain, name, callback_ref, if (app.lua) |*lua| lua.generation else 0, id);
    errdefer pending.destroy();
    // All fallible request/metadata setup precedes spawning transport work.
    const connection = try mux_ops.createSessionConnection(app, options);
    pending.connection = connection;
    pending.operation.bind(connection);
    app.session_opens[slot] = pending;
    app.session_open_count += 1;
    app.session_open_next_id += 1;
    app.signalWake();
    return id;
}

pub fn cancel(app: *App, id: u64) bool {
    for (app.session_opens) |entry| if (entry) |pending| {
        if (pending.id != id or pending.state != .running) continue;
        const failure = pending.operation.cancel();
        retire(app, pending, failure.reason, failure.outcome);
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
        const step = pending.operation.step() catch |err| {
            const failure = pending.operation.cancel();
            retire(app, pending, err, failure.outcome);
            continue;
        };
        switch (step) {
            .pending => {},
            .failed => |failure| retire(app, pending, failure.reason, failure.outcome),
            .attached => |attachment| {
                defer attachment.deinit();
                pending.state = .publishing;
                const info = attachment.reply.value.session.?;
                const workspace = mux_ops.addSessionWorkspaceNamed(app, pending.connection.?, info, pending.domain, pending.name) catch |err| {
                    // Owner has already created/attached. Do not kill its pane
                    // or replay create just because GUI allocation failed.
                    std.log.err("session {s} attached but view publication failed: {s}", .{ info.id, @errorName(err) });
                    pending.connection.?.close();
                    retire(app, pending, err, .uncertain);
                    continue;
                };
                const workspace_id = workspace.id;
                pending.connection = null; // Ownership now belongs to App controller.
                const callback_ref = pending.callback_ref;
                const generation = pending.lua_generation;
                app.session_opens[index] = null;
                app.session_open_count -= 1;
                pending.destroy();
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

fn retire(app: *App, pending: *Pending, reason: anyerror, outcome: opener.Outcome) void {
    pending.state = .retiring;
    pending.connection.?.close();
    const callback_ref = pending.callback_ref;
    pending.callback_ref = no_ref;
    std.log.warn("session workspace open failed: {s} ({s}; not replayed)", .{ @errorName(reason), @tagName(outcome) });
    complete(app, callback_ref, pending.lua_generation, null);
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
    const pending = try Pending.prepare(a, .{ .id = 0, .op = .create, .spawn = .{} }, &domain, &name, no_ref, 0, 1);
    @memset(&domain, 'x');
    @memset(&name, 'x');
    app.session_opens[0] = pending;
    app.session_open_count = 1;
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
    try std.testing.expectEqualStrings("captured-name", app.mux.?.activeWorkspace().?.name.?);
    try std.testing.expectEqualStrings("captured-domain", app.activePane().?.domainName());
    mux_ops.maybeRunStartupCommand(app);
    try std.testing.expect(app.startup_command_sent);
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
    const connection = try mockConnection(a);
    pending.connection = connection;
    pending.operation.bind(connection);
    try std.testing.expect(cancel(app, 9));
    try std.testing.expect(!cancel(app, 9));
    try std.testing.expectEqual(@as(c_int, no_ref), pending.callback_ref);
    try std.testing.expect(pending.state == .retiring);
    pump(app);
    try std.testing.expect(app.session_opens[0] == pending);
    connection.finished = true;
    pump(app);
    try std.testing.expect(app.session_opens[0] == null);
    try std.testing.expectEqual(@as(usize, 0), app.session_open_count);
    try std.testing.expectEqual(@as(usize, 0), app.session_controllers.items.len);
}

fn prepareAllocation(a: std.mem.Allocator) !void {
    const pending = try Pending.prepare(a, .{ .id = 0, .op = .create, .spawn = .{ .cwd = "/captured", .argv = &.{"sh"} } }, "domain", "name", no_ref, 7, 1);
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
