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

test {
    _ = @import("session/dead_pane.zig");
}

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

test "session shell exit schedules acknowledged removal while apps retain their screen" {
    for (.{ false, true }) |auto_close| {
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
        node.content.terminal.pty.?.session.close_on_exit = auto_close;
        try frame(&connection, .exit, 1, &p.encodeExit(0));
        try std.testing.expect(try controller.step() == .dispatched);
        try std.testing.expectEqual(auto_close, controller.close_work);
        // Even shells retain their view until the owner acknowledges close.
        try std.testing.expect(node.content.terminal.retain_on_exit);
        try std.testing.expect(controller.hasBindings());
        try controller.flushCloses();
        try std.testing.expectEqual(@as(usize, if (auto_close) 1 else 0), controller.pendingCloses());
        if (auto_close) {
            const close = connection.client.nextWrite().?;
            defer close.deinit();
            const request = try p.parse(p.Request, a, close.payload);
            defer request.deinit();
            try std.testing.expectEqual(p.Op.close, request.value.op);
            try std.testing.expectEqual(@as(?u32, 1), request.value.pane);
        }
    }
}

test "reattached exited shell schedules removal but detached live shell does not" {
    for (.{ false, true }) |exited| {
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
        node.id = 11;
        var pty = @import("pty/session.zig").SessionPty.init(a, &connection, 1, controller.generation, if (exited) 0 else null);
        pty.close_on_exit = true;
        try node.content.terminal.bootstrapSession(&node, &runtime, fixture.callbacks(), cfg, pty);
        try controller.bind(&node);
        try std.testing.expectEqual(exited, controller.close_work);
        if (!exited) {
            try json(&connection, .event, p.Event{ .event = .taken, .session = "mock" });
            const step = try controller.step();
            if (step == .control) step.control.deinit();
            try std.testing.expect(!controller.close_work);
            try std.testing.expect(controller.detached);
        }
    }
}

test "session pane controller respawns only advertised dead panes and revives on acceptance" {
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
    const pty = &node.content.terminal.pty.?.session;

    try std.testing.expectError(error.PaneAlive, controller.requestRespawn(node.id));
    try frame(&connection, .exit, 1, &p.encodeExit(3));
    try std.testing.expect(try controller.step() == .dispatched);
    try std.testing.expect(!pty.isAlive());
    const dead_pane = @import("session/dead_pane.zig");
    try std.testing.expectEqual(dead_pane.State{ .status = 3, .respawn = false }, dead_pane.state(&node).?);
    // Without the owner feature nothing is sent: unknown ops drop the connection.
    try std.testing.expectError(error.Unsupported, controller.requestRespawn(node.id));
    try std.testing.expect(connection.client.nextWrite() == null);

    connection.client.respawn_supported = true;
    try std.testing.expect(dead_pane.state(&node).?.respawn);
    const rejected = try controller.requestRespawn(node.id);
    try std.testing.expectEqual(rejected, try controller.requestRespawn(node.id));
    const sent = connection.client.nextWrite().?;
    defer sent.deinit();
    const request = try p.parse(p.Request, a, sent.payload);
    defer request.deinit();
    try std.testing.expectEqual(p.Op.respawn, request.value.op);
    try std.testing.expectEqual(@as(?u32, 1), request.value.pane);
    try json(&connection, .reply, p.Reply{ .id = rejected, .ok = false, .@"error" = "ForkFailed" });
    const failed = try controller.step();
    try std.testing.expect(failed == .control);
    failed.control.deinit();
    try std.testing.expectEqual(@as(?usize, node.id), controller.finishRespawn(rejected));
    try std.testing.expect(!pty.isAlive());

    const accepted = try controller.requestRespawn(node.id);
    try std.testing.expect(accepted != rejected);
    connection.client.nextWrite().?.deinit();
    try json(&connection, .reply, p.Reply{ .id = accepted, .pane = 1 });
    const ok = try controller.step();
    try std.testing.expect(ok == .control);
    ok.control.deinit();
    try std.testing.expect(pty.isAlive());
    try std.testing.expect(dead_pane.state(&node) == null);
    try std.testing.expectEqual(@as(?usize, node.id), controller.finishRespawn(accepted));
    try std.testing.expectEqual(@as(?usize, null), controller.finishRespawn(accepted));
    node.content.terminal.reviveSession(&node);
    try std.testing.expect(node.content.terminal.hasLiveChild());
    try std.testing.expect(!node.content.terminal.exit_event_emitted);
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
    with_layout.layout = "{\"version\":2,\"tabs\":[]}";
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

test "session pane layout restores nested tabs and floating geometry with owner identities" {
    const codec = @import("session/layout.zig");
    const geometry = @import("mux/session_layout.zig");
    const Mux = @import("mux/mux.zig").Mux;
    var connection = try fixture.mockConnection();
    defer fixture.freeMock(&connection);
    const panes: []const p.PaneInfo = &.{
        .{ .id = 1, .cols = 80, .rows = 24 },
        .{ .id = 2, .cols = 40, .rows = 24 },
        .{ .id = 3, .cols = 60, .rows = 20 },
        .{ .id = 4, .cols = 80, .rows = 24 },
    };
    var info: p.SessionInfo = .{ .id = "mock", .attached = true, .revision = 7, .panes = panes };
    const attach = try connection.request(.{ .id = 0, .op = .attach, .session = "mock" });
    connection.client.nextWrite().?.deinit();
    try json(&connection, .reply, p.Reply{ .id = attach, .session = info });
    connection.poll().?.deinit();
    var controller = Controller.init(a, &connection);
    try setup(&controller);
    defer controller.deinit();
    var runtime = try ghostty.Runtime.init(a, null);
    defer runtime.deinit();
    var cfg = Config.init(a);
    defer cfg.deinit();
    const bytes = try codec.encode(a, .{
        .name = "nested-session",
        .active_tab = 1,
        .tabs = &.{
            .{
                .active_pane = 3,
                .root = 0,
                .nodes = &.{ .{ .first = 1, .second = 2, .direction = .horizontal, .ratio = 0.3 }, .{ .pane = 1 }, .{ .pane = 2 } },
                .floating = &.{.{ .pane = 3, .anchor = 2, .x = 0.2, .width = 0.4 }},
                .maximized_pane = 2,
                .maximized_show_background = true,
            },
            .{ .active_pane = 4, .root = 0, .nodes = &.{.{ .pane = 4 }} },
        },
    }, &.{ 1, 2, 3, 4 });
    defer a.free(bytes);
    info.layout = bytes;
    var mux = Mux.init(a);
    defer mux.deinit(&runtime);
    const workspace = try mux.addSessionWorkspace(&runtime, fixture.callbacks(), cfg, &controller, info, null, null);
    try std.testing.expectEqualStrings("nested-session", workspace.name.?);
    try std.testing.expectEqual(@as(usize, 1), workspace.activeTabIndex());
    const tab = workspace.tabs.items[0];
    try std.testing.expectEqual(@as(f32, 0.3), tab.root_split.?.ratio);
    try std.testing.expectEqual(@as(u32, 3), try geometry.ownerId(tab.active_pane.?));
    try std.testing.expectEqual(@as(u32, 2), try geometry.ownerId(tab.maximized_pane.?));
    try std.testing.expect(tab.active_pane.?.is_floating);
    try std.testing.expectEqual(tab.maximized_pane.?.id, tab.active_pane.?.restore_anchor_id);
    const captured = try geometry.capture(a, workspace);
    defer a.free(captured);
    try std.testing.expectEqualStrings(bytes, captured);
    mux.deinit(&runtime);
    try std.testing.expect(!controller.hasBindings());
    mux.next_pane_id.store(100, .monotonic);
    info.layout = captured;
    const restored = try mux.addSessionWorkspace(&runtime, fixture.callbacks(), cfg, &controller, info, null, null);
    try std.testing.expect(restored.tabs.items[0].active_pane.?.id >= 100);
    const recaptured = try geometry.capture(a, restored);
    defer a.free(recaptured);
    try std.testing.expectEqualStrings(bytes, recaptured);
}

test "session pane layout restore reconciles stale membership and survives a corrupt blob" {
    const codec = @import("session/layout.zig");
    const geometry = @import("mux/session_layout.zig");
    const Mux = @import("mux/mux.zig").Mux;
    var connection = try fixture.mockConnection();
    defer fixture.freeMock(&connection);
    var controller = Controller.init(a, &connection);
    try setup(&controller);
    defer controller.deinit();
    var runtime = try ghostty.Runtime.init(a, null);
    defer runtime.deinit();
    var cfg = Config.init(a);
    defer cfg.deinit();
    // Saved for panes 1|2 split; pane 2 closed and pane 3 spawned before the
    // GUI went away, so the owner still holds the old blob.
    const bytes = try codec.encode(a, .{ .name = "stale", .tabs = &.{.{
        .active_pane = 2,
        .root = 0,
        .nodes = &.{ .{ .first = 1, .second = 2 }, .{ .pane = 1 }, .{ .pane = 2 } },
    }} }, &.{ 1, 2 });
    defer a.free(bytes);
    var info: p.SessionInfo = .{
        .id = "mock",
        .attached = true,
        .revision = 3,
        .layout = bytes,
        .panes = &.{ .{ .id = 1, .cols = 80, .rows = 24 }, .{ .id = 3, .cols = 80, .rows = 24 } },
    };
    var mux = Mux.init(a);
    defer mux.deinit(&runtime);
    const workspace = try mux.addSessionWorkspace(&runtime, fixture.callbacks(), cfg, &controller, info, null, null);
    try std.testing.expectEqualStrings("stale", workspace.name.?);
    try std.testing.expectEqual(@as(usize, 2), workspace.tabs.items.len);
    const first = workspace.tabs.items[0];
    try std.testing.expectEqual(@as(usize, 1), first.panes.items.len);
    try std.testing.expect(first.root_split.?.kind == .pane);
    try std.testing.expectEqual(@as(u32, 1), try geometry.ownerId(first.active_pane.?));
    try std.testing.expectEqual(@as(u32, 3), try geometry.ownerId(workspace.tabs.items[1].active_pane.?));
    mux.deinit(&runtime);
    // A corrupt blob must not make the session unreachable.
    info.layout = "{\"tabs\":[{\"active_pane\":1,\"root\":0,\"nodes\":[{\"first\":0,\"second\":0}]}]}";
    const fallback = try mux.addSessionWorkspace(&runtime, fixture.callbacks(), cfg, &controller, info, null, null);
    try std.testing.expectEqual(@as(usize, 2), fallback.tabs.items.len);
    try std.testing.expect(fallback.name == null);
}

test "session pane controller teardown wait applies the layout reply past discarded output" {
    var connection = try fixture.mockConnection();
    defer fixture.freeMock(&connection);
    var controller = Controller.init(a, &connection);
    try setup(&controller);
    controller.revision = 2;
    defer controller.deinit();
    var runtime = try ghostty.Runtime.init(a, null);
    defer runtime.deinit();
    var cfg = Config.init(a);
    defer cfg.deinit();
    var node = Pane.init(a);
    defer node.deinit(&runtime);
    try bind(&controller, &node, &runtime, cfg, 1);
    const bytes = try @import("session/layout.zig").encode(a, .{ .tabs = &.{.{ .active_pane = 1, .root = 0, .nodes = &.{.{ .pane = 1 }} }} }, &.{1});
    defer a.free(bytes);
    const id = try controller.requestLayout(bytes);
    connection.client.nextWrite().?.deinit();
    // No transport task can deliver anything: the wait ends at once.
    try std.testing.expectError(error.Timeout, controller.awaitReply(id, io.nanoTimestamp() + std.time.ns_per_s));
    try frame(&connection, .output, 1, "late output nobody will parse");
    try json(&connection, .reply, p.Reply{ .id = id, .revision = 3 });
    try controller.awaitReply(id, 0);
    try std.testing.expectEqual(@as(u64, 3), controller.revision);
    try std.testing.expect(controller.layout_request == null);
    try std.testing.expectEqual(@as(usize, 0), node.content.terminal.pty.?.session.pendingOutputBytes());
}

test "session pane layout update advances only acknowledged revision and fences conflict" {
    var connection = try fixture.mockConnection();
    defer fixture.freeMock(&connection);
    var controller = Controller.init(a, &connection);
    try setup(&controller);
    controller.revision = 7;
    defer controller.deinit();
    var runtime = try ghostty.Runtime.init(a, null);
    defer runtime.deinit();
    var cfg = Config.init(a);
    defer cfg.deinit();
    var node = Pane.init(a);
    defer node.deinit(&runtime);
    try bind(&controller, &node, &runtime, cfg, 1);
    const bytes = try @import("session/layout.zig").encode(a, .{ .tabs = &.{.{ .active_pane = 1, .root = 0, .nodes = &.{.{ .pane = 1 }} }} }, &.{1});
    defer a.free(bytes);
    const request = try controller.requestLayout(bytes);
    try std.testing.expectError(error.LayoutPending, controller.requestLayout(bytes));
    try std.testing.expectEqual(@as(u64, 7), controller.revision);
    const outgoing = connection.client.nextWrite().?;
    defer outgoing.deinit();
    const parsed = try p.parse(p.Request, a, outgoing.payload);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, 7), parsed.value.revision.?);
    try json(&connection, .reply, p.Reply{ .id = request, .revision = 8 });
    (try controller.step()).control.deinit();
    try std.testing.expectEqual(@as(u64, 8), controller.revision);
    const conflict = try controller.requestLayout(bytes);
    connection.client.nextWrite().?.deinit();
    try json(&connection, .reply, p.Reply{ .id = conflict, .ok = false, .@"error" = "RevisionConflict", .revision = 10 });
    (try controller.step()).control.deinit();
    try std.testing.expectEqual(@as(u64, 8), controller.revision);
    try std.testing.expectError(error.RevisionConflict, controller.requestLayout(bytes));
}

fn layoutAllocationRoundtrip(allocator: std.mem.Allocator, connection: *transport.Connection, runtime: *ghostty.Runtime, cfg: Config) !void {
    var controller = Controller.init(allocator, connection);
    controller.generation = connection.client.generation;
    controller.session_id = try allocator.dupe(u8, "mock");
    // Controller teardown closes the mock bridge; restore it for next injected
    // allocation failure, without doing any real connector work.
    defer {
        controller.deinit();
        connection.closing = false;
    }
    var mux = @import("mux/mux.zig").Mux.init(allocator);
    defer mux.deinit(runtime);
    const info: p.SessionInfo = .{
        .id = "mock",
        .attached = true,
        .revision = 0,
        .panes = &.{ .{ .id = 1, .cols = 80, .rows = 24 }, .{ .id = 2, .cols = 40, .rows = 24 }, .{ .id = 3, .cols = 40, .rows = 20 } },
        .layout = "{\"name\":\"rollback\",\"tabs\":[{\"active_pane\":1,\"root\":0,\"nodes\":[{\"first\":1,\"second\":2},{\"pane\":1},{\"pane\":2}],\"floating\":[{\"pane\":3,\"anchor\":2}]}]}",
    };
    const workspace = mux.addSessionWorkspace(runtime, fixture.callbacks(), cfg, &controller, info, "session-domain", null) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), mux.workspaces.items.len);
        try std.testing.expectEqual(@as(usize, 0), mux.session_workspace_count);
        try std.testing.expect(!controller.hasBindings());
        return err;
    };
    const captured = try @import("mux/session_layout.zig").capture(allocator, workspace);
    defer allocator.free(captured);
}

test "session pane layout factory allocation failures roll back views and bindings" {
    var connection = try fixture.mockConnection();
    defer fixture.freeMock(&connection);
    var runtime = try ghostty.Runtime.init(a, null);
    defer runtime.deinit();
    var cfg = Config.init(a);
    defer cfg.deinit();
    try std.testing.checkAllAllocationFailures(a, layoutAllocationRoundtrip, .{ &connection, &runtime, cfg });
}

test {
    _ = @import("session/layout.zig");
}

test "session pane controller resync discards output received ahead of the snapshot" {
    var connection = try fixture.mockConnection();
    defer fixture.freeMock(&connection);
    connection.client.format = .vt;
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
    // Receive-ahead returns credit before parsing, so the owner may resync
    // while older frames are still queued here. The snapshot already holds
    // them; replaying them after READY drew stale alt-screen frames over the
    // restored primary screen.
    try frame(&connection, .output, 1, "stale-frame");
    try std.testing.expect(try controller.step() == .dispatched);
    try json(&connection, .event, p.Event{ .event = .resync, .session = "mock", .pane = 1 });
    const step = try controller.step();
    try std.testing.expect(step == .control);
    step.control.deinit();
    const pty = &node.content.terminal.pty.?.session;
    try std.testing.expectEqual(@as(usize, 0), pty.pendingOutputBytes());
    try std.testing.expectEqual(@as(usize, 0), connection.client.buffered);
    try frame(&connection, .snapshot, 1, "fresh-screen");
    _ = try controller.step();
    try frame(&connection, .snapshot_end, 1, "");
    _ = try controller.step();
    try history(&node, &runtime);
    try fixture.poll(&node, &runtime);
    const output = try fixture.text(&node);
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "fresh-screen") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "stale-frame") == null);
}
