//! Bounded GUI session discovery: single-use list/kill over a fresh connector.
//! Never attaches and never replays. Lua callers receive the result once;
//! command callers poll `session_result` until a terminal state is claimed.
const std = @import("std");
const App = @import("../app.zig").App;
const command = @import("../command.zig");
const transport = @import("../session/transport.zig");
const querying = @import("../session/query.zig");
const layout = @import("../session/layout.zig");
const domains = @import("session_domain.zig");
const mux_ops = @import("session_controller.zig");
const io = @import("../io.zig");
const p = transport.p;
const no_ref: c_int = -1;
pub const max_pending = 8;
/// Unclaimed command results expire so abandoned polls cannot pin slots.
pub const result_ttl_ns: i128 = 60 * std.time.ns_per_s;

pub const Op = querying.Op;

pub const Pending = struct {
    allocator: std.mem.Allocator,
    id: u64,
    domain: []u8,
    query: querying.Query,
    connection: ?*transport.Connection = null,
    callback_ref: c_int,
    lua_generation: ?u64,
    state: enum { running, done, failed } = .running,
    /// JSON object: the success result, or `{domain, outcome, error, remote?}`.
    result: ?[]u8 = null,
    error_name: []const u8 = "",
    finished_ns: i128 = 0,
    claimed: bool = false,

    pub fn prepare(a: std.mem.Allocator, id: u64, op: Op, session: ?[]const u8, domain: []const u8, callback_ref: c_int, generation: ?u64) !*Pending {
        const self = try a.create(Pending);
        errdefer a.destroy(self);
        const owned_domain = try a.dupe(u8, domain);
        errdefer a.free(owned_domain);
        self.* = .{
            .allocator = a,
            .id = id,
            .domain = owned_domain,
            .query = try querying.Query.init(a, op, session),
            .callback_ref = callback_ref,
            .lua_generation = generation,
        };
        return self;
    }

    /// Called only before a connector starts, after EOF, or during shutdown.
    pub fn destroy(self: *Pending) void {
        if (self.connection) |connection| connection.destroy();
        self.query.deinit();
        if (self.result) |text| self.allocator.free(text);
        self.allocator.free(self.domain);
        self.allocator.destroy(self);
    }

    fn ended(self: *const Pending) bool {
        return if (self.connection) |connection| connection.status().phase == .ended else true;
    }
};

/// Admission only. On error the caller still owns `callback_ref`; on success
/// it is invoked once on completion (or abandoned with an old Lua runtime).
pub fn begin(app: *App, op: Op, session: ?[]const u8, domain_name: ?[]const u8, callback_ref: c_int) !u64 {
    if (session) |id| if (!domains.validSessionId(id)) return error.InvalidSessionId;
    if (app.session_query_next_id == std.math.maxInt(u64)) return error.ResourceExhausted;
    reap(app);
    const slot = for (app.session_queries, 0..) |entry, i| {
        if (entry == null) break i;
    } else return error.ResourceExhausted;
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const resolved = try domains.resolve(app, arena.allocator(), domains.inheritedDomain(app, domain_name));
    const id = app.session_query_next_id;
    const pending = try Pending.prepare(app.allocator, id, op, session, resolved.domain, callback_ref, if (app.lua) |*lua| lua.generation else null);
    errdefer pending.destroy();
    // All fallible setup precedes spawning transport work.
    const connection = try mux_ops.createSessionConnection(app, resolved.options);
    pending.connection = connection;
    pending.query.bind(connection);
    app.session_queries[slot] = pending;
    app.session_query_count += 1;
    app.session_query_next_id += 1;
    app.signalWake();
    return id;
}

pub fn pump(app: *App) void {
    if (app.session_query_count == 0) return;
    // Fixed slots stay stable across Lua callbacks that admit more queries.
    for (0..max_pending) |index| {
        const pending = app.session_queries[index] orelse continue;
        if (pending.state != .running) continue;
        switch (pending.query.step()) {
            .pending => {},
            .failed => |failure| finish(app, pending, failure.reason, failureText(app.allocator, pending, failure) catch null),
            .done => |reply| {
                defer reply.deinit();
                // The owner already acted; the bridge has nothing more to do.
                pending.connection.?.close();
                const text = successText(app, pending, reply.reply.value) catch |err| {
                    finish(app, pending, err, failureText(app.allocator, pending, .{ .reason = err, .outcome = .uncertain }) catch null);
                    continue;
                };
                pending.state = .done;
                complete(app, pending, text);
            },
        }
    }
    reap(app);
}

fn finish(app: *App, pending: *Pending, reason: anyerror, text: ?[]u8) void {
    pending.state = .failed;
    pending.error_name = @errorName(reason);
    std.log.warn("session {s} query failed: {s} (not replayed)", .{ @tagName(pending.query.op), @errorName(reason) });
    complete(app, pending, text);
}

fn complete(app: *App, pending: *Pending, text: ?[]u8) void {
    pending.result = text;
    pending.finished_ns = io.nanoTimestamp();
    const callback_ref = pending.callback_ref;
    pending.callback_ref = no_ref;
    if (callback_ref != no_ref) pending.claimed = true;
    app.markAutomationChanged();
    if (callback_ref == no_ref) return;
    const lua = if (app.lua) |*value| value else return;
    // An old registry died with its runtime; its refs must not be touched.
    if (pending.lua_generation == null or lua.generation != pending.lua_generation.?) return;
    var response = responseFor(app.allocator, pending, false) catch command.Response.fail("out_of_memory", "session query result allocation failed");
    defer response.deinit(app.allocator);
    lua.invokeJobCallback(callback_ref, response);
}

/// Frees settled slots whose bridge has ended. Never blocks.
fn reap(app: *App) void {
    if (app.session_query_count == 0) return;
    const now = io.nanoTimestamp();
    for (&app.session_queries) |*slot| if (slot.*) |pending| {
        if (pending.state == .running or !pending.ended()) continue;
        if (!pending.claimed and now - pending.finished_ns < result_ttl_ns) continue;
        slot.* = null;
        app.session_query_count -= 1;
        pending.destroy();
    };
}

/// `session_result`: running, or the terminal result exactly once.
pub fn fetch(app: *App, id: u64) !command.Response {
    for (app.session_queries) |entry| if (entry) |pending| {
        if (pending.id != id or pending.claimed) continue;
        var response = try responseFor(app.allocator, pending, true);
        errdefer response.deinit(app.allocator);
        const object = &response.payload.?.object;
        try put(app.allocator, object, "revision", .{ .integer = @intCast(app.currentAutomationRevision()) });
        if (pending.state != .running) pending.claimed = true;
        return response;
    };
    return .fail("query_not_found", "no unclaimed session query with this id");
}

/// Admission response for command callers.
pub fn started(app: *App, id: u64) !command.Response {
    var object: std.json.ObjectMap = .empty;
    errdefer command.deinitJsonValue(app.allocator, .{ .object = object });
    try put(app.allocator, &object, "query", .{ .integer = @intCast(id) });
    try put(app.allocator, &object, "state", .{ .string = try app.allocator.dupe(u8, "running") });
    try put(app.allocator, &object, "revision", .{ .integer = @intCast(app.currentAutomationRevision()) });
    return .ok(.{ .object = object });
}

/// Lua gets the result object as `payload`; commands get it wrapped in a
/// `{query, op, state, result}` envelope. Query failure is data, not a
/// transport error, for command callers.
fn responseFor(a: std.mem.Allocator, pending: *const Pending, envelope: bool) !command.Response {
    var result: ?std.json.Value = null;
    errdefer if (result) |value| command.deinitJsonValue(a, value);
    if (pending.result) |text| {
        const parsed = try std.json.parseFromSlice(std.json.Value, a, text, .{});
        defer parsed.deinit();
        result = try command.cloneJsonValue(a, parsed.value);
    }
    if (!envelope) {
        const response: command.Response = if (pending.state == .done) .ok(result) else .{
            .success = false,
            .status = "session_query_failed",
            .error_message = @constCast(pending.error_name),
            .payload = result,
        };
        result = null;
        return response;
    }
    var object: std.json.ObjectMap = .empty;
    errdefer command.deinitJsonValue(a, .{ .object = object });
    try put(a, &object, "query", .{ .integer = @intCast(pending.id) });
    try put(a, &object, "op", .{ .string = try a.dupe(u8, @tagName(pending.query.op)) });
    try put(a, &object, "state", .{ .string = try a.dupe(u8, @tagName(pending.state)) });
    if (result) |value| {
        result = null;
        put(a, &object, "result", value) catch |err| {
            command.deinitJsonValue(a, value);
            return err;
        };
    }
    return .ok(.{ .object = object });
}

fn put(a: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: std.json.Value) !void {
    const owned = try a.dupe(u8, key);
    errdefer a.free(owned);
    try object.put(a, owned, value);
}

const PaneResult = struct { id: u32, title: []const u8, cwd: []const u8, cols: u16, rows: u16, exited: bool, exit_status: ?i32 = null };
const SessionResult = struct { id: []const u8, attached: bool, open: bool, revision: u64, name: ?[]const u8 = null, panes: []const PaneResult };

fn successText(app: *App, pending: *const Pending, reply: p.Reply) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const options: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };
    var host_buf: [p.max_host_len]u8 = undefined;
    const host_value = pending.connection.?.host(&host_buf);
    const host: ?[]const u8 = if (host_value.len > 0) host_value else null;
    switch (pending.query.op) {
        .kill => return std.json.Stringify.valueAlloc(app.allocator, .{ .domain = pending.domain, .host = host, .session = pending.query.session.? }, options),
        .list => {
            const sessions = reply.sessions orelse return error.InvalidReply;
            const out = try a.alloc(SessionResult, sessions.len);
            for (sessions, out) |info, *entry| {
                const panes = try a.alloc(PaneResult, info.panes.len);
                for (info.panes, panes) |pane, *value| value.* = .{
                    .id = pane.id,
                    .title = pane.title,
                    .cwd = pane.cwd,
                    .cols = pane.cols,
                    .rows = pane.rows,
                    .exited = pane.exit != null,
                    .exit_status = pane.exit,
                };
                entry.* = .{
                    .id = info.id,
                    .attached = info.attached,
                    .open = isOpen(app, host_value, info.id),
                    .revision = info.revision,
                    .name = try layout.peekName(a, info.layout),
                    .panes = panes,
                };
            }
            return std.json.Stringify.valueAlloc(app.allocator, .{ .domain = pending.domain, .host = host, .sessions = out }, options);
        },
    }
}

fn failureText(a: std.mem.Allocator, pending: *const Pending, failure: querying.Failure) ![]u8 {
    return std.json.Stringify.valueAlloc(a, .{
        .domain = pending.domain,
        .session = pending.query.session,
        .outcome = @tagName(failure.outcome),
        .@"error" = @errorName(failure.reason),
        .remote = failure.remote,
    }, .{ .emit_null_optional_fields = false });
}

/// A workspace in this GUI views the session. Host IDs are compared only
/// when both sides have one; older owners send none.
fn isOpen(app: *App, host: []const u8, session_id: []const u8) bool {
    const mux = if (app.mux) |*value| value else return false;
    for (mux.workspaces.items) |workspace| {
        const controller = workspace.session_controller orelse continue;
        if (sameSession(controller.host, controller.session_id, host, session_id)) return true;
    }
    return false;
}

fn sameSession(host_a: []const u8, session_a: []const u8, host_b: []const u8, session_b: []const u8) bool {
    if (!std.mem.eql(u8, session_a, session_b)) return false;
    return host_a.len == 0 or host_b.len == 0 or std.mem.eql(u8, host_a, host_b);
}

test "session borrowers query open match requires the same host when both are known" {
    try std.testing.expect(sameSession("h1", "s", "h1", "s"));
    try std.testing.expect(!sameSession("h1", "s", "h2", "s"));
    try std.testing.expect(sameSession("", "s", "h2", "s"));
    try std.testing.expect(sameSession("h1", "s", "", "s"));
    try std.testing.expect(!sameSession("h1", "s", "h1", "t"));
}

pub fn shutdown(app: *App) void {
    for (&app.session_queries) |*slot| if (slot.*) |pending| {
        slot.* = null;
        if (app.lua) |*lua| if (pending.lua_generation) |generation| if (lua.generation == generation) lua.discardOperationCallback(pending.callback_ref);
        if (pending.state == .running) _ = pending.query.cancel();
        pending.destroy();
    };
    app.session_query_count = 0;
}

fn mockConnection(a: std.mem.Allocator) !*transport.Connection {
    const connection = try a.create(transport.Connection);
    errdefer a.destroy(connection);
    connection.* = .{
        .allocator = a,
        .io = io.get(),
        .arena = .init(a),
        .options = .{ .ghostty_identity = "test" },
        .client = .{ .allocator = a, .identity = "test" },
    };
    errdefer {
        connection.client.deinit();
        connection.arena.deinit();
    }
    const welcome = try p.stringify(a, p.Welcome{ .ghostty = "test", .snapshot = .binary, .owner_pid = 1, .host = "host-1" });
    defer a.free(welcome);
    try connection.client.receive(p.header(.welcome, 0, welcome.len), welcome);
    return connection;
}

fn mockReply(connection: *transport.Connection, value: p.Reply) !void {
    const body = try p.stringify(std.testing.allocator, value);
    defer std.testing.allocator.free(body);
    try connection.client.receive(p.header(.reply, 0, body.len), body);
}

fn admit(app: *App, op: Op, session: ?[]const u8) !struct { *Pending, *transport.Connection } {
    const a = std.testing.allocator;
    const id = app.session_query_next_id;
    app.session_query_next_id += 1;
    const pending = try Pending.prepare(a, id, op, session, "guest", no_ref, null);
    errdefer pending.destroy();
    const connection = try mockConnection(a);
    pending.connection = connection;
    pending.query.bind(connection);
    for (&app.session_queries) |*slot| if (slot.* == null) {
        slot.* = pending;
        app.session_query_count += 1;
        return .{ pending, connection };
    };
    return error.ResourceExhausted;
}

fn submittedId(connection: *transport.Connection) !u64 {
    const message = connection.client.nextWrite() orelse return error.MissingRequest;
    defer message.deinit();
    const request = try p.parse(p.Request, std.testing.allocator, message.payload);
    defer request.deinit();
    return request.value.id;
}

test "session borrowers query list result is claimed once and marks open workspaces" {
    const a = std.testing.allocator;
    const app = try a.create(App);
    defer a.destroy(app);
    app.* = App.init(a);
    defer app.deinit();
    const pending, const connection = try admit(app, .list, null);
    const id = pending.id;
    var running = try fetch(app, id);
    try std.testing.expectEqualStrings("running", running.payload.?.object.get("state").?.string);
    running.deinit(a);
    pump(app);
    const request_id = try submittedId(connection);
    const revision = app.currentAutomationRevision();
    try mockReply(connection, .{ .id = request_id, .sessions = &.{.{
        .id = "s1",
        .attached = true,
        .revision = 4,
        .layout = "{\"name\":\"work\"}",
        .panes = &.{ .{ .id = 1, .cols = 80, .rows = 24, .title = "sh", .cwd = "/tmp" }, .{ .id = 2, .cols = 10, .rows = 5, .exit = 3 } },
    }} });
    pump(app);
    try std.testing.expect(pending.state == .done);
    try std.testing.expect(app.currentAutomationRevision() > revision);
    try std.testing.expect(connection.closing);
    var done = try fetch(app, id);
    defer done.deinit(a);
    const result = done.payload.?.object.get("result").?.object;
    try std.testing.expectEqualStrings("guest", result.get("domain").?.string);
    try std.testing.expectEqualStrings("host-1", result.get("host").?.string);
    const session = result.get("sessions").?.array.items[0].object;
    try std.testing.expectEqualStrings("s1", session.get("id").?.string);
    try std.testing.expectEqualStrings("work", session.get("name").?.string);
    try std.testing.expect(!session.get("open").?.bool);
    const panes = session.get("panes").?.array.items;
    try std.testing.expect(!panes[0].object.get("exited").?.bool);
    try std.testing.expect(panes[0].object.get("exit_status") == null);
    try std.testing.expectEqual(@as(i64, 3), panes[1].object.get("exit_status").?.integer);
    var again = try fetch(app, id);
    defer again.deinit(a);
    try std.testing.expect(!again.success);
    try std.testing.expectEqualStrings("query_not_found", again.status);
    // Claimed results are freed only after the bridge has ended.
    pump(app);
    try std.testing.expectEqual(@as(usize, 1), app.session_query_count);
    try std.testing.expect(connection.client.nextWrite() == null);
    connection.finished = true;
    pump(app);
    try std.testing.expectEqual(@as(usize, 0), app.session_query_count);
}

test "session borrowers query kill reports lost replies as uncertain and expires unclaimed" {
    const a = std.testing.allocator;
    const app = try a.create(App);
    defer a.destroy(app);
    app.* = App.init(a);
    defer app.deinit();
    const pending, const connection = try admit(app, .kill, "victim");
    pump(app);
    _ = try submittedId(connection);
    connection.finished = true;
    pump(app);
    try std.testing.expect(pending.state == .failed);
    try std.testing.expectEqual(@as(usize, 1), app.session_query_count);
    var failed = try fetch(app, pending.id);
    defer failed.deinit(a);
    try std.testing.expect(failed.success);
    const payload = failed.payload.?.object;
    try std.testing.expectEqualStrings("failed", payload.get("state").?.string);
    try std.testing.expectEqualStrings("kill", payload.get("op").?.string);
    const result = payload.get("result").?.object;
    try std.testing.expectEqualStrings("uncertain", result.get("outcome").?.string);
    try std.testing.expectEqualStrings("victim", result.get("session").?.string);

    const unclaimed, const second = try admit(app, .kill, "other");
    pump(app);
    const second_id = try submittedId(second);
    try mockReply(second, .{ .id = second_id, .ok = false, .@"error" = "SessionNotFound" });
    pump(app);
    try std.testing.expect(unclaimed.state == .failed);
    second.finished = true;
    pump(app);
    try std.testing.expectEqual(@as(usize, 1), app.session_query_count);
    unclaimed.finished_ns -= result_ttl_ns;
    pump(app);
    try std.testing.expectEqual(@as(usize, 0), app.session_query_count);
}

test "session borrowers query admission is bounded and validates before connecting" {
    const a = std.testing.allocator;
    const app = try a.create(App);
    defer a.destroy(app);
    app.* = App.init(a);
    defer app.deinit();
    try std.testing.expectError(error.InvalidSessionId, begin(app, .kill, "", null, no_ref));
    for (0..max_pending) |_| _ = try admit(app, .list, null);
    try std.testing.expectError(error.ResourceExhausted, begin(app, .list, null, null, no_ref));
    try std.testing.expectEqual(@as(u64, max_pending + 1), app.session_query_next_id);
}
