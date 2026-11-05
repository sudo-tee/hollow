const std = @import("std");
const io = @import("io.zig");
const Controller = @import("session/controller.zig").Controller;
const core = @import("session/client.zig");
const transport = @import("session/transport.zig");
const Pane = @import("pane.zig").Pane;
const ghostty = @import("term/ghostty.zig");
const Config = @import("config.zig").Config;
const fixture = @import("session_pane_test.zig");
const p = transport.p;
const a = std.testing.allocator;

fn setup(controller: *Controller) !void {
    controller.session_id = try a.dupe(u8, "mock");
    controller.generation = controller.connection.client.generation;
}

fn bind(controller: *Controller, node: *Pane, runtime: *ghostty.Runtime, cfg: Config, remote: u32) !void {
    node.id = remote + 10;
    try node.content.terminal.bootstrapSession(node, runtime, fixture.callbacks(), cfg, @import("pty/session.zig").SessionPty.init(a, controller.connection, remote, controller.generation, null));
    try controller.bind(node);
}

fn frame(connection: *transport.Connection, kind: p.Kind, pane: u32, bytes: []const u8) !void {
    try connection.client.receive(p.header(kind, pane, bytes.len), bytes);
}

fn json(connection: *transport.Connection, kind: p.Kind, value: anytype) !void {
    const bytes = try p.stringify(a, value);
    defer a.free(bytes);
    try frame(connection, kind, 0, bytes);
}

fn history(node: *Pane, runtime: *ghostty.Runtime) !void {
    const deadline = io.nanoTimestamp() + 5 * std.time.ns_per_s;
    while (node.content.terminal.session_snapshot != null) {
        if (io.nanoTimestamp() >= deadline) return error.Timeout;
        try node.content.terminal.pollSessionSnapshot(node, runtime);
        try std.Io.sleep(io.get(), .fromMilliseconds(1), .awake);
    }
}

test "session pane controller retains a blocked frame until the pane drains" {
    var connection = try fixture.mockConnection();
    defer fixture.freeMock(&connection);
    var controller = Controller.init(a, &connection);
    try setup(&controller);
    defer controller.deinit();
    var runtime = try ghostty.Runtime.init(a, null);
    defer runtime.deinit();
    var cfg = Config.init(a);
    defer cfg.deinit();
    var node = Pane.init(a);
    defer node.deinit(&runtime);
    try bind(&controller, &node, &runtime, cfg, 1);
    for (0..core.queue_frames) |_| {
        try frame(&connection, .output, 1, "x");
        try std.testing.expect(try controller.step() == .dispatched);
    }
    try frame(&connection, .output, 1, "z");
    try std.testing.expect(try controller.step() == .blocked);
    try std.testing.expect(controller.pending != null);
    try fixture.poll(&node, &runtime);
    try std.testing.expect(try controller.step() == .dispatched);
    try std.testing.expect(controller.pending == null);
    const grant = connection.client.nextWrite().?;
    defer grant.deinit();
    try std.testing.expectEqual(p.Kind.credit, grant.kind);
    try std.testing.expect((try p.decodeCredit(grant.payload)) > 0);
}

test "session pane controller retries scheduled close admission under queue pressure" {
    var connection = try fixture.mockConnection();
    defer fixture.freeMock(&connection);
    var controller = Controller.init(a, &connection);
    try setup(&controller);
    defer controller.deinit();
    var runtime = try ghostty.Runtime.init(a, null);
    defer runtime.deinit();
    var cfg = Config.init(a);
    defer cfg.deinit();
    var node = Pane.init(a);
    defer node.deinit(&runtime);
    try bind(&controller, &node, &runtime, cfg, 1);

    for (0..core.queue_frames) |_| try connection.send(.input, 1, "");
    try controller.scheduleClose(node.id);
    try controller.flushCloses();
    try std.testing.expectEqual(@as(usize, 0), controller.pendingCloses());
    try std.testing.expect(controller.close_work);

    while (connection.client.nextWrite()) |message| message.deinit();
    try controller.flushCloses();
    try std.testing.expectEqual(@as(usize, 1), controller.pendingCloses());
    const close = connection.client.nextWrite().?;
    defer close.deinit();
    const request = try p.parse(p.Request, a, close.payload);
    defer request.deinit();
    try std.testing.expectEqual(p.Op.close, request.value.op);
    try std.testing.expect(!controller.close_work);
}

test "session pane controller keeps close tombstone and connection until acknowledgement" {
    var connection = try fixture.mockConnection();
    defer fixture.freeMock(&connection);
    var controller = Controller.init(a, &connection);
    try setup(&controller);
    defer controller.deinit();
    var runtime = try ghostty.Runtime.init(a, null);
    defer runtime.deinit();
    var cfg = Config.init(a);
    defer cfg.deinit();
    var node = Pane.init(a);
    defer node.deinit(&runtime);
    try bind(&controller, &node, &runtime, cfg, 1);
    for (0..core.queue_frames) |_| try connection.send(.input, 1, "");
    try std.testing.expectError(error.ResourceExhausted, controller.requestClose(node.id));
    try std.testing.expectEqual(@as(usize, 0), controller.pendingCloses());
    try std.testing.expect(node.content.terminal.session_view != null);
    while (connection.client.nextWrite()) |message| message.deinit();
    const id = try controller.requestClose(node.id);
    try std.testing.expect(!controller.closesSettled());
    connection.client.nextWrite().?.deinit();
    node.deinit(&runtime); // Callback unbinds safely, but close metadata stays.
    try std.testing.expectEqual(@as(usize, 1), controller.pendingCloses());
    try frame(&connection, .output, 1, "closing tail");
    try std.testing.expect(try controller.step() == .dispatched);
    try json(&connection, .reply, p.Reply{ .id = id });
    const result = try controller.step();
    try std.testing.expect(result == .control);
    result.control.deinit();
    try std.testing.expect(controller.closesSettled());
    try std.testing.expectEqual(@as(usize, 0), controller.pendingCloses());
    try std.testing.expect(connection.status().phase == .ready);
}

test "session pane controller aggregate snapshot budget unblocks after history polling" {
    var connection = try fixture.mockConnection();
    defer fixture.freeMock(&connection);
    connection.client.format = .vt;
    const spawn = try connection.request(.{ .id = 0, .op = .spawn });
    connection.client.nextWrite().?.deinit();
    try json(&connection, .reply, p.Reply{ .id = spawn, .pane = 2 });
    connection.poll().?.deinit();
    var controller = Controller.init(a, &connection);
    try setup(&controller);
    controller.snapshot_limit = 160;
    defer controller.deinit();
    var runtime = try ghostty.Runtime.init(a, null);
    defer runtime.deinit();
    var cfg = Config.init(a);
    defer cfg.deinit();
    var first = Pane.init(a);
    defer first.deinit(&runtime);
    var second = Pane.init(a);
    defer second.deinit(&runtime);
    try bind(&controller, &first, &runtime, cfg, 1);
    try bind(&controller, &second, &runtime, cfg, 2);
    const bytes: [100]u8 = @splat('x');
    try frame(&connection, .snapshot, 1, &bytes);
    _ = try controller.step();
    try frame(&connection, .snapshot_end, 1, "");
    _ = try controller.step();
    try frame(&connection, .snapshot, 2, &bytes);
    try std.testing.expect(try controller.step() == .blocked);
    try std.testing.expectEqual(@as(usize, 100), controller.snapshot_bytes);
    try history(&first, &runtime);
    controller.reconcile();
    try std.testing.expect(try controller.step() == .dispatched);
    try frame(&connection, .snapshot_end, 2, "");
    _ = try controller.step();
    try history(&second, &runtime);
    controller.reconcile();
    try std.testing.expectEqual(@as(usize, 0), controller.snapshot_bytes);
}

test "session pane controller take-over freezes view and can tear down before views" {
    var connection = try fixture.mockConnection();
    defer fixture.freeMock(&connection);
    var controller = Controller.init(a, &connection);
    try setup(&controller);
    defer controller.deinit();
    var runtime = try ghostty.Runtime.init(a, null);
    defer runtime.deinit();
    var cfg = Config.init(a);
    defer cfg.deinit();
    var node = Pane.init(a);
    defer node.deinit(&runtime);
    try bind(&controller, &node, &runtime, cfg, 1);
    try json(&connection, .event, p.Event{ .event = .taken, .session = "mock" });
    const result = try controller.step();
    result.control.deinit();
    try std.testing.expect(controller.detached);
    try std.testing.expectError(error.Detached, controller.requestClose(node.id));
    controller.deinit();
    try std.testing.expect(node.content.terminal.session_view == null);
    try std.testing.expectError(error.Detached, node.content.terminal.pty.?.session.requestClose());
    try std.testing.expect(!node.content.terminal.pty.?.isAlive());
}

test "session pane controller creates a mux workspace without native shell spawn" {
    var connection = try fixture.mockConnection();
    defer fixture.freeMock(&connection);
    var controller = Controller.init(a, &connection);
    try setup(&controller);
    defer controller.deinit();
    var runtime = try ghostty.Runtime.init(a, null);
    defer runtime.deinit();
    var cfg = Config.init(a);
    defer cfg.deinit();
    cfg.shell = try a.dupe(u8, "/never-spawn-this");
    var mux = @import("mux/mux.zig").Mux.init(a);
    defer mux.deinit(&runtime);
    const info: p.SessionInfo = .{ .id = "mock", .attached = true, .revision = 0, .panes = &.{.{ .id = 1, .cols = 80, .rows = 24 }} };
    const workspace = try mux.addSessionWorkspace(&runtime, fixture.callbacks(), cfg, &controller, info, "session-domain", null);
    try std.testing.expect(workspace.session_controller == &controller);
    try std.testing.expectEqualStrings("session-domain", mux.activePane().?.domainName());
    try std.testing.expect(mux.activePane().?.content.terminal.pty.? == .session);
    try std.testing.expectError(error.UnsupportedSessionMutation, mux.newTab(&runtime, fixture.callbacks(), cfg, 8, 16, 640, 480, null, null, null, false));
    try std.testing.expectError(error.UnsupportedSessionMutation, mux.splitActivePane(&runtime, fixture.callbacks(), cfg, 8, 16, 640, 480, .horizontal, 0.5, null, null, false, null));
    var with_layout = info;
    with_layout.layout = "{\"version\":1}";
    try std.testing.expectError(error.UnsupportedSessionLayout, mux.addSessionWorkspace(&runtime, fixture.callbacks(), cfg, &controller, with_layout, null, null));
    try std.testing.expectEqual(@as(usize, 1), mux.workspaces.items.len);
    try std.testing.expectEqual(@as(usize, 1), mux.session_workspace_count);
    const local_id = mux.activePane().?.id;
    try std.testing.expect(mux.controllerForPane(local_id) == &controller);
    const session_tab_id = mux.activeTab().?.id;
    const ordinary = try a.create(Pane);
    ordinary.* = Pane.init(a);
    ordinary.id = mux.reservePaneId();
    try mux.newWorkspaceWithPane(&runtime, ordinary, null);
    const ordinary_tab_id = mux.activeTab().?.id;
    try std.testing.expect(!mux.movePaneToWorkspace(&runtime, local_id, 1));
    try std.testing.expect(!mux.movePaneToWorkspace(&runtime, ordinary.id, 0));
    try std.testing.expect(!mux.moveTabToWorkspace(&runtime, session_tab_id, 1));
    try std.testing.expect(!mux.moveTabToWorkspace(&runtime, ordinary_tab_id, 0));
    try std.testing.expect(!mux.closePaneById(&runtime, local_id));
    try std.testing.expectEqual(@as(usize, 0), mux.session_workspace_count);
    try std.testing.expect(mux.controllerForPane(local_id) == null);
}

test "session pane controller retries scheduled close admission without duplicate requests" {
    var connection = try fixture.mockConnection();
    defer fixture.freeMock(&connection);
    var controller = Controller.init(a, &connection);
    try setup(&controller);
    defer controller.deinit();
    var runtime = try ghostty.Runtime.init(a, null);
    defer runtime.deinit();
    var cfg = Config.init(a);
    defer cfg.deinit();
    var node = Pane.init(a);
    defer node.deinit(&runtime);
    try bind(&controller, &node, &runtime, cfg, 1);
    for (0..core.queue_frames) |_| try connection.send(.input, 1, "");
    try controller.scheduleClose(node.id);
    try controller.flushCloses();
    try std.testing.expect(controller.close_work);
    try std.testing.expectEqual(@as(usize, 0), controller.pendingCloses());
    while (connection.client.nextWrite()) |message| message.deinit();
    try controller.flushCloses();
    try std.testing.expect(!controller.close_work);
    try std.testing.expectEqual(@as(usize, 1), controller.pendingCloses());
    const close = connection.client.nextWrite().?;
    defer close.deinit();
    const request = try p.parse(p.Request, a, close.payload);
    defer request.deinit();
    try std.testing.expectEqual(p.Op.close, request.value.op);
    try controller.scheduleClose(node.id);
    try controller.flushCloses();
    try std.testing.expect(connection.client.nextWrite() == null);
}
