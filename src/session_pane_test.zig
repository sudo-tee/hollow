//! Real Pane/PTY/VT integration without window, fonts or Lua. The owner fixture
//! uses HOLLOW_TEST_AGENT on Linux, or explicit session-test-wsl/agent options.
const std = @import("std");
const io = @import("io.zig");
const ghostty = @import("term/ghostty.zig");
const Pane = @import("pane.zig").Pane;
const Config = @import("config.zig").Config;
const SessionPty = @import("pty/session.zig").SessionPty;
const transport = @import("session/transport.zig");
const core = @import("session/client.zig");
const vt = @import("agent/session_vt.zig");
const support = @import("session_transport_test.zig");
const p = transport.p;
const a = std.testing.allocator;

pub fn callbacks() ghostty.TerminalCallbacks {
    const C = struct {
        fn write(_: ?*anyopaque, ctx: ?*anyopaque, bytes: [*]const u8, len: usize) callconv(.c) void {
            const node: *Pane = @ptrCast(@alignCast(ctx.?));
            node.content.terminal.sendText(bytes[0..len]);
        }
        fn noop(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {}
        fn title(_: ?*anyopaque, ctx: ?*anyopaque) callconv(.c) void {
            const node: *Pane = @ptrCast(@alignCast(ctx.?));
            node.title_dirty = true;
        }
        fn string(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) ghostty.String {
            return .{ .ptr = null, .len = 0 };
        }
        fn size(_: ?*anyopaque, _: ?*anyopaque, _: *ghostty.SizeReportSize) callconv(.c) bool {
            return false;
        }
        fn scheme(_: ?*anyopaque, _: ?*anyopaque, _: *ghostty.ColorScheme) callconv(.c) bool {
            return false;
        }
        fn attributes(_: ?*anyopaque, _: ?*anyopaque, _: *ghostty.DeviceAttributes) callconv(.c) bool {
            return false;
        }
    };
    return .{
        .write_pty = C.write,
        .bell = C.noop,
        .enquiry = C.string,
        .xtversion = C.string,
        .size = C.size,
        .color_scheme = C.scheme,
        .device_attributes = C.attributes,
        .title_changed = C.title,
    };
}

pub fn mockConnection() !transport.Connection {
    var connection: transport.Connection = .{
        .allocator = a,
        .io = io.get(),
        .arena = .init(a),
        .options = .{ .ghostty_identity = "test" },
        .client = .{ .allocator = a, .identity = "test" },
    };
    errdefer connection.client.deinit();
    const welcome = "{\"ghostty\":\"test\",\"snapshot\":\"binary\",\"owner_pid\":1}";
    try connection.client.receive(p.header(.welcome, 0, welcome.len), welcome);
    connection.poll().?.deinit();
    const id = try connection.request(.{ .id = 0, .op = .attach, .session = "mock" });
    connection.client.nextWrite().?.deinit();
    const body = try p.stringify(a, p.Reply{ .id = id, .session = .{
        .id = "mock",
        .attached = true,
        .revision = 0,
        .panes = &.{.{ .id = 1, .cols = 80, .rows = 24 }},
    } });
    defer a.free(body);
    try connection.client.receive(p.header(.reply, 0, body.len), body);
    connection.poll().?.deinit();
    return connection;
}

pub fn freeMock(connection: *transport.Connection) void {
    connection.client.deinit();
    connection.arena.deinit();
}

fn deliver(connection: *transport.Connection, pane: *Pane, bytes: []const u8) !void {
    try connection.client.receive(p.header(.output, 1, bytes.len), bytes);
    const message = connection.poll().?;
    errdefer message.deinit();
    try pane.content.terminal.pty.?.session.offerOutput(message);
}

pub fn poll(pane: *Pane, runtime: *ghostty.Runtime) !void {
    _ = try pane.content.terminal.pollPty(pane, runtime, 16, 64 * 1024, 10 * std.time.ns_per_ms, 16 * 1024, false);
}

fn text(pane: *Pane) ![]u8 {
    return vt.plain(@ptrCast(pane.content.terminal.terminal), a);
}

test "session pane reads grant credit after parsing and preserve user paste" {
    var connection = try mockConnection();
    defer freeMock(&connection);
    var runtime = try ghostty.Runtime.init(a, null);
    defer runtime.deinit();
    var cfg = Config.init(a);
    defer cfg.deinit();
    cfg.shell = try a.dupe(u8, "/this-must-never-be-spawned");
    var pane = Pane.init(a);
    defer pane.deinit(&runtime);
    try pane.content.terminal.bootstrapSession(&pane, &runtime, callbacks(), cfg, SessionPty.init(a, &connection, 1, connection.client.generation, null));
    try std.testing.expect(pane.content.terminal.pty.? == .session);
    try std.testing.expect(pane.content.terminal.retain_on_exit);
    try std.testing.expectEqual(@as(usize, 0), pane.content.terminal.childPid());
    const bytes = "live text\x1b[5n\x1b[6n\x1b[?2004h";
    try deliver(&connection, &pane, bytes);
    try std.testing.expect(connection.client.nextWrite() == null);
    try poll(&pane, &runtime);
    const grant = connection.client.nextWrite().?;
    defer grant.deinit();
    try std.testing.expectEqual(p.Kind.credit, grant.kind);
    try std.testing.expectEqual(@as(u32, bytes.len), try p.decodeCredit(grant.payload));
    try std.testing.expect(connection.client.nextWrite() == null); // No duplicate query replies.
    try runtime.pasteText(pane.content.terminal.terminal, "user paste");
    const input = connection.client.nextWrite().?;
    defer input.deinit();
    try std.testing.expectEqual(p.Kind.input, input.kind);
    try std.testing.expectEqualStrings("\x1b[200~user paste\x1b[201~", input.payload);
    const output = try text(&pane);
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "live text") != null);
}

test "session pane adapter partial reads do not return premature or duplicate credit" {
    var connection = try mockConnection();
    defer freeMock(&connection);
    var pty = SessionPty.init(a, &connection, 1, connection.client.generation, null);
    defer pty.deinit();
    try connection.client.receive(p.header(.output, 1, 6), "abcdef");
    try pty.offerOutput(connection.poll().?);
    var buffer: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try pty.read(&buffer));
    try std.testing.expectEqualStrings("ab", &buffer);
    try std.testing.expect(connection.client.nextWrite() == null);
    try pty.parsed(2);
    const grant = connection.client.nextWrite().?;
    defer grant.deinit();
    try std.testing.expectEqual(@as(u32, 2), try p.decodeCredit(grant.payload));
    try std.testing.expectError(error.InvalidCredit, pty.parsed(1));
    pty.setExit(-9);
    try std.testing.expect(!pty.isAlive());
    try std.testing.expect(pty.hasPendingOutput());
    try std.testing.expectEqual(@as(?u32, 137), pty.exitStatus());
}

test "session pane input is generation fenced and view teardown never queues close" {
    var connection = try mockConnection();
    defer freeMock(&connection);
    var pty = SessionPty.init(a, &connection, 1, connection.client.generation, null);
    pty.deinit();
    try std.testing.expect(connection.client.nextWrite() == null);
    var old = SessionPty.init(a, &connection, 1, connection.client.generation, null);
    defer old.deinit();
    connection.client.generation += 1;
    try std.testing.expectError(error.Detached, old.writeAll("must not reach new session"));
    try std.testing.expectError(error.Detached, old.requestClose());
    var current = SessionPty.init(a, &connection, 1, connection.client.generation, null);
    defer current.deinit();
    const id = try current.requestClose();
    try std.testing.expectEqual(id, try current.requestClose());
    const message = connection.client.nextWrite().?;
    defer message.deinit();
    const request = try p.parse(p.Request, a, message.payload);
    defer request.deinit();
    try std.testing.expectEqual(p.Op.close, request.value.op);
    try std.testing.expect(connection.client.nextWrite() == null);
}

test "pending explicit close blocks input without reporting process exit early" {
    var connection = try mockConnection();
    defer freeMock(&connection);
    var pty = SessionPty.init(a, &connection, 1, connection.client.generation, null);
    defer pty.deinit();

    const close_id = try pty.requestClose();
    try std.testing.expect(close_id != 0);
    try std.testing.expect(pty.isAlive());
    try std.testing.expectError(error.EndOfStream, pty.writeAll("must not follow close"));

    const close = connection.client.nextWrite().?;
    defer close.deinit();
    const request = try p.parse(p.Request, a, close.payload);
    defer request.deinit();
    try std.testing.expectEqual(p.Op.close, request.value.op);
}

test "session pane retries latest resize after queue pressure without replaying input" {
    var connection = try mockConnection();
    defer freeMock(&connection);
    var pty = SessionPty.init(a, &connection, 1, connection.client.generation, null);
    defer pty.deinit();
    for (0..core.queue_frames) |_| try connection.send(.input, 1, "");
    pty.resize(100, 30);
    pty.resize(123, 45);
    try std.testing.expect(pty.pending_resize != null);
    while (connection.client.nextWrite()) |message| message.deinit();
    var buffer: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try pty.read(&buffer));
    const resized = connection.client.nextWrite().?;
    defer resized.deinit();
    const size = try p.decodeResize(resized.payload);
    try std.testing.expectEqual(@as(u16, 123), size.cols);
    try std.testing.expectEqual(@as(u16, 45), size.rows);
    try std.testing.expect(pty.pending_resize == null);
    try std.testing.expect(connection.client.nextWrite() == null);
}

test "session pane replacement allocates helpers transactionally and cannot convert live panes" {
    var connection = try mockConnection();
    defer freeMock(&connection);
    var runtime = try ghostty.Runtime.init(a, null);
    defer runtime.deinit();
    var cfg = Config.init(a);
    defer cfg.deinit();
    var pane = Pane.init(a);
    defer pane.deinit(&runtime);
    const adapter = SessionPty.init(a, &connection, 1, connection.client.generation, null);
    try pane.content.terminal.bootstrapSession(&pane, &runtime, callbacks(), cfg, adapter);
    const term = &pane.content.terminal;
    try std.testing.expectError(error.CannotConvertLivePane, term.bootstrapSession(&pane, &runtime, callbacks(), cfg, adapter));
    const original = term.terminal;
    const helpers = term.render_state;
    const Fail = struct {
        fn new(_: ?*anyopaque, _: *?*anyopaque) callconv(.c) i32 {
            return -1;
        }
    };
    inline for (.{ "render_state_new", "row_iterator_new", "row_cells_new", "key_encoder_new" }) |field| {
        var bad_runtime = runtime;
        @field(bad_runtime, field) = Fail.new;
        const fresh = (try runtime.createTerminal(80, 24, 4096)).?;
        defer runtime.freeTerminal(fresh);
        if (@import("term/session_pane.zig").replaceTerminal(term, &pane, &bad_runtime, callbacks(), fresh)) |_| {
            return error.ExpectedFailure;
        } else |_| {}
        try std.testing.expectEqual(original, term.terminal);
        try std.testing.expectEqual(helpers, term.render_state);
        try runtime.updateRenderState(term.render_state, term.terminal);
    }
}

test "session pane replacement releases controller search borrowers before freeing old terminal" {
    var connection = try mockConnection();
    defer freeMock(&connection);
    var runtime = try ghostty.Runtime.init(a, null);
    defer runtime.deinit();
    var cfg = Config.init(a);
    defer cfg.deinit();
    var pane = Pane.init(a);
    defer pane.deinit(&runtime);
    const term = &pane.content.terminal;
    try term.bootstrapSession(&pane, &runtime, callbacks(), cfg, SessionPty.init(a, &connection, 1, connection.client.generation, null));
    runtime.terminalWrite(term.terminal, "find me");
    var search: @import("term/search.zig").Search = .{};
    defer search.deinit(a);
    try search.setNeedle(a, term.terminal, "find");
    try search.step(a);
    pane.host_context = &search;
    const Hook = struct {
        fn replacing(node: *Pane) void {
            const value: *@import("term/search.zig").Search = @ptrCast(@alignCast(node.host_context.?));
            std.debug.assert(value.terminal == node.content.terminal.terminal);
            value.deinit(node.allocator);
        }
    };
    term.session_before_replace = Hook.replacing;
    const fresh = (try runtime.createTerminal(cfg.cols, cfg.rows, cfg.scrollback)).?;
    @import("term/session_pane.zig").replaceTerminal(term, &pane, &runtime, callbacks(), fresh) catch |err| {
        runtime.freeTerminal(fresh);
        return err;
    };
    try std.testing.expect(search.handle == null);
    try search.setNeedle(a, term.terminal, "next");
    try search.step(a);
}

test "session pane snapshot replaces hidden render helpers and retains final screen on exit" {
    var connection = try mockConnection();
    defer freeMock(&connection);
    var runtime = try ghostty.Runtime.init(a, null);
    defer runtime.deinit();
    var cfg = Config.init(a);
    defer cfg.deinit();
    var pane = Pane.init(a);
    defer pane.deinit(&runtime);
    const term = &pane.content.terminal;
    try term.bootstrapSession(&pane, &runtime, callbacks(), cfg, SessionPty.init(a, &connection, 1, connection.client.generation, null));
    term.releaseRenderHelpers(&runtime);
    const owner = try vt.Vt.create(a, cfg.cols, cfg.rows, cfg.scrollback);
    defer owner.destroy();
    owner.write("restored screen\x1b]0;owner title\x07");
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    try owner.snapshot(a, &bytes);
    try term.beginSessionSnapshot(&pane, .binary);
    const first: transport.Message = .{ .kind = .snapshot, .pane = 1, .payload = try a.dupe(u8, bytes.items[0..1]), .allocator = a };
    try term.session_snapshot.?.offer(first);
    try deliver(&connection, &pane, " live-after");
    try poll(&pane, &runtime);
    try std.testing.expect(term.session_snapshot_waiting);
    try std.testing.expectEqual(@as(usize, 0), term.pty.?.session.unparsed);
    try std.testing.expect(connection.client.nextWrite() == null);
    var offset: usize = 1;
    while (offset < bytes.items.len) {
        const n = @min(p.max_data, bytes.items.len - offset);
        const message: transport.Message = .{ .kind = .snapshot, .pane = 1, .payload = try a.dupe(u8, bytes.items[offset..][0..n]), .allocator = a };
        errdefer message.deinit();
        try term.session_snapshot.?.offer(message);
        offset += n;
    }
    term.session_snapshot.?.end();
    const deadline = io.nanoTimestamp() + 5 * std.time.ns_per_s;
    while (term.session_snapshot != null) {
        if (io.nanoTimestamp() >= deadline) return error.Timeout;
        try poll(&pane, &runtime);
        try std.Io.sleep(io.get(), .fromMilliseconds(1), .awake);
    }
    try std.testing.expect(term.renderHelpersReady());
    try std.testing.expect(pane.render_dirty == .full);
    const output = try text(&pane);
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "restored screen live-after") != null);
    var title: ghostty.String = .{ .ptr = null, .len = 0 };
    try std.testing.expectEqual(ghostty.success, runtime.terminal_get(term.terminal, @backingInt(ghostty.TerminalData.title), &title));
    try std.testing.expectEqualStrings("owner title", title.slice());
    term.pty.?.session.setExit(7);
    term.refreshChildAliveCache(true);
    try std.testing.expect(!term.hasLiveChild());
    try std.testing.expect(term.retain_on_exit);
    try std.testing.expect(term.terminal != null);
}

test "session pane invalid snapshot preserves old terminal and stops unsafe post-snapshot parsing" {
    var connection = try mockConnection();
    defer freeMock(&connection);
    var runtime = try ghostty.Runtime.init(a, null);
    defer runtime.deinit();
    var cfg = Config.init(a);
    defer cfg.deinit();
    var pane = Pane.init(a);
    defer pane.deinit(&runtime);
    const term = &pane.content.terminal;
    try term.bootstrapSession(&pane, &runtime, callbacks(), cfg, SessionPty.init(a, &connection, 1, connection.client.generation, null));
    runtime.terminalWrite(term.terminal, "kept old screen");
    const old = term.terminal;
    try term.beginSessionSnapshot(&pane, .binary);
    const message: transport.Message = .{ .kind = .snapshot, .pane = 1, .payload = try a.dupe(u8, "invalid"), .allocator = a };
    try term.session_snapshot.?.offer(message);
    term.session_snapshot.?.end();
    const deadline = io.nanoTimestamp() + 5 * std.time.ns_per_s;
    var failed = false;
    while (io.nanoTimestamp() < deadline) {
        term.pollSessionSnapshot(&pane, &runtime) catch |err| {
            try std.testing.expectEqual(error.InvalidSnapshot, err);
            failed = true;
            break;
        };
        try std.Io.sleep(io.get(), .fromMilliseconds(1), .awake);
    }
    try std.testing.expect(failed);
    try std.testing.expect(term.session_snapshot == null);
    try std.testing.expect(term.session_snapshot_waiting);
    try std.testing.expectEqual(old, term.terminal);
    const output = try text(&pane);
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "kept old screen") != null);
}

fn pump(connection: *transport.Connection, pane: *Pane, runtime: *ghostty.Runtime) !void {
    var turns: usize = 0;
    while (turns < core.queue_frames) : (turns += 1) {
        const message = connection.poll() orelse break;
        var transferred = false;
        defer if (!transferred) message.deinit();
        const term = &pane.content.terminal;
        switch (message.kind) {
            .output => {
                try term.pty.?.session.offerOutput(message);
                transferred = true;
            },
            .snapshot => {
                if (term.session_snapshot == null) try term.beginSessionSnapshot(pane, connection.status().format.?);
                try term.session_snapshot.?.offer(message);
                transferred = true;
            },
            .snapshot_end => {
                if (term.session_snapshot == null) try term.beginSessionSnapshot(pane, connection.status().format.?);
                term.session_snapshot.?.end();
            },
            .exit => term.pty.?.session.setExit(try p.decodeExit(message.payload)),
            .event => {
                const event = try p.parse(p.Event, a, message.payload);
                defer event.deinit();
                if (event.value.event == .resync) {
                    try term.beginSessionSnapshot(pane, connection.status().format.?);
                } else term.pty.?.session.detach();
            },
            else => {},
        }
    }
    try poll(pane, runtime);
}

fn waitText(connection: *transport.Connection, pane: *Pane, runtime: *ghostty.Runtime, needle: []const u8) !void {
    const deadline = io.nanoTimestamp() + 10 * std.time.ns_per_s;
    while (io.nanoTimestamp() < deadline) {
        try pump(connection, pane, runtime);
        const contents = try text(pane);
        defer a.free(contents);
        if (std.mem.indexOf(u8, contents, needle) != null) return;
        if (connection.status().phase == .ended) return error.ConnectionEnded;
        try std.Io.sleep(io.get(), .fromMilliseconds(2), .awake);
    }
    return error.Timeout;
}

fn nextControl(controller: *@import("session/controller.zig").Controller) !transport.Message {
    const deadline = io.nanoTimestamp() + 10 * std.time.ns_per_s;
    while (io.nanoTimestamp() < deadline) {
        switch (try controller.step()) {
            .control => |message| return message,
            .blocked => return error.UnexpectedBackpressure,
            .dispatched => {},
            .idle => {
                if (controller.connection.status().phase == .ended) return error.ConnectionEnded;
                try std.Io.sleep(io.get(), .fromMilliseconds(2), .awake);
            },
        }
    }
    return error.Timeout;
}

fn waitOpen(operation: *@import("session/open.zig").Open) !@import("session/open.zig").Attachment {
    const deadline = io.nanoTimestamp() + 10 * std.time.ns_per_s;
    while (io.nanoTimestamp() < deadline) {
        switch (try operation.step()) {
            .attached => |attachment| return attachment,
            .failed => |failure| return failure.reason,
            .pending => try std.Io.sleep(io.get(), .fromMilliseconds(2), .awake),
        }
    }
    return error.Timeout;
}

fn pumpWorkspace(controller: *@import("session/controller.zig").Controller, mux: *@import("mux/mux.zig").Mux, runtime: *ghostty.Runtime) !void {
    controller.reconcile();
    for (0..128) |_| switch (try controller.step()) {
        .control => |message| message.deinit(),
        .idle, .blocked => break,
        .dispatched => {},
    };
    var panes = mux.paneIterator();
    while (panes.next()) |node| try poll(node, runtime);
}

fn waitWorkspaceText(controller: *@import("session/controller.zig").Controller, mux: *@import("mux/mux.zig").Mux, runtime: *ghostty.Runtime, needle: []const u8) !void {
    const deadline = io.nanoTimestamp() + 10 * std.time.ns_per_s;
    while (io.nanoTimestamp() < deadline) {
        try pumpWorkspace(controller, mux, runtime);
        const contents = try text(mux.activePane().?);
        defer a.free(contents);
        if (std.mem.indexOf(u8, contents, needle) != null) return;
        if (controller.connection.status().phase == .ended) return error.ConnectionEnded;
        try std.Io.sleep(io.get(), .fromMilliseconds(2), .awake);
    }
    return error.Timeout;
}

test "session pane real owner restores binary snapshot into Pane after full client teardown" {
    const settings = @import("session_test_options");
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = if (settings.agent) |value| value else if (@import("builtin").os.tag == .linux)
        std.testing.environ.getAlloc(arena, "HOLLOW_TEST_AGENT") catch return error.SkipZigTest
    else
        return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = if (settings.wsl != null)
        try std.fmt.allocPrint(arena, "/tmp/hollow-session-pane-check-{d}", .{io.nanoTimestamp()})
    else
        try std.fmt.allocPrint(arena, "{s}/socket", .{try tmp.dir.realPathFileAlloc(io.get(), ".", arena)});
    var connector: std.ArrayList([]const u8) = .empty;
    if (settings.wsl) |distro| try connector.appendSlice(arena, &.{ "wsl.exe", "-d", distro, "--" });
    try connector.appendSlice(arena, &.{
        "/usr/bin/env",
        try std.fmt.allocPrint(arena, "HOLLOW_SESSION_DIR={s}", .{dir}),
        try std.fmt.allocPrint(arena, "XDG_STATE_HOME={s}", .{dir}),
    });
    const options: transport.Options = .{
        .connector = .{ .argv = connector.items },
        .agent = .{ .path = path },
        .ghostty_identity = ghostty.buildIdentity(),
    };
    defer {
        if (transport.Connection.create(a, io.get(), options)) |cleanup| {
            defer cleanup.destroy();
            _ = cleanup.request(.{ .id = 0, .op = .kill_server }) catch 0;
            if (support.waitMessage(cleanup, .reply)) |message| message.deinit() else |_| {}
            support.waitEnded(cleanup) catch {};
        } else |_| {}
        if (settings.wsl != null) {
            const command = options.connector.command(arena, &.{ "/bin/sh", "-c", "rm -f -- \"$1/owner.log\" \"$1/session-v1.lock\"; rmdir -- \"$1/hollow/sessions\" \"$1/hollow\" \"$1\"", "cleanup", dir }) catch null;
            if (command) |argv| {
                if (std.process.spawn(io.get(), .{ .argv = argv, .stdout = .ignore, .stderr = .ignore, .create_no_window = true })) |value| {
                    var child = value;
                    _ = child.wait(io.get()) catch child.kill(io.get());
                } else |_| {}
            }
        }
    }
    var runtime = try ghostty.Runtime.init(a, null);
    defer runtime.deinit();
    var cfg = Config.init(a);
    defer cfg.deinit();
    const Controller = @import("session/controller.zig").Controller;
    const Mux = @import("mux/mux.zig").Mux;
    var sid: []const u8 = undefined;
    {
        const first = try transport.Connection.create(a, io.get(), options);
        defer first.destroy();
        var controller = Controller.init(a, first);
        defer controller.deinit();
        var mux = Mux.init(a);
        defer mux.deinit(&runtime);
        var opening = try @import("session/open.zig").Open.init(a, first, .{ .id = 0, .op = .create, .spawn = .{
            .cols = cfg.cols,
            .rows = cfg.rows,
            .argv = &.{ "/bin/sh", "-c", "printf 'persisted-marker'; read x; printf 'after-input:%s' \"$x\"; exit 7" },
            .shell_integration = false,
        } });
        defer opening.deinit();
        const created = try waitOpen(&opening);
        defer created.deinit();
        const reply = created.reply;
        try std.testing.expect(reply.value.ok);
        try std.testing.expectEqual(p.SnapshotFormat.binary, first.status().format.?);
        sid = try arena.dupe(u8, reply.value.session.?.id);
        controller.session_id = try a.dupe(u8, sid);
        controller.generation = created.message.generation;
        controller.revision = reply.value.session.?.revision;
        _ = try mux.addSessionWorkspace(&runtime, callbacks(), cfg, &controller, reply.value.session.?, null, null);
        try waitWorkspaceText(&controller, &mux, &runtime, "persisted-marker");
        const layout = try @import("mux/session_layout.zig").capture(a, mux.activeWorkspace().?);
        defer a.free(layout);
        const layout_request = try controller.requestLayout(layout);
        const saved = try nextControl(&controller);
        defer saved.deinit();
        const saved_reply = try p.parse(p.Reply, a, saved.payload);
        defer saved_reply.deinit();
        try std.testing.expect(saved_reply.value.ok);
        try std.testing.expectEqual(layout_request, saved_reply.value.id);
        try std.testing.expectEqual(saved_reply.value.revision.?, controller.revision);
        // Mux -> controller -> connection teardown leaves the owner's shell.
    }
    const second = try transport.Connection.create(a, io.get(), options);
    defer second.destroy();
    var controller = Controller.init(a, second);
    defer controller.deinit();
    var mux = Mux.init(a);
    defer mux.deinit(&runtime);
    var opening = try @import("session/open.zig").Open.init(a, second, .{ .id = 0, .op = .attach, .session = sid });
    defer opening.deinit();
    const attached = try waitOpen(&opening);
    defer attached.deinit();
    const attached_reply = attached.reply;
    try std.testing.expect(attached_reply.value.session.?.layout.len > 0);
    try std.testing.expect(attached_reply.value.ok);
    controller.session_id = try a.dupe(u8, sid);
    controller.generation = attached.message.generation;
    controller.revision = attached_reply.value.session.?.revision;
    _ = try mux.addSessionWorkspace(&runtime, callbacks(), cfg, &controller, attached_reply.value.session.?, null, null);
    const node = mux.activePane().?;
    const term = &node.content.terminal;
    try waitWorkspaceText(&controller, &mux, &runtime, "persisted-marker");
    term.sendText("hello\n");
    try waitWorkspaceText(&controller, &mux, &runtime, "after-input:hello");
    const deadline = io.nanoTimestamp() + 5 * std.time.ns_per_s;
    while (term.pty.?.session.status == null) {
        if (io.nanoTimestamp() >= deadline) return error.Timeout;
        try pumpWorkspace(&controller, &mux, &runtime);
        try std.Io.sleep(io.get(), .fromMilliseconds(2), .awake);
    }
    try std.testing.expectEqual(@as(?u32, 7), term.pty.?.exitStatus());
    try std.testing.expect(term.retain_on_exit and term.terminal != null);
    const local_id = node.id;
    const close_id = try controller.requestClose(local_id);
    const closed = try nextControl(&controller);
    defer closed.deinit();
    const closed_reply = try p.parse(p.Reply, a, closed.payload);
    defer closed_reply.deinit();
    try std.testing.expect(closed_reply.value.ok);
    try std.testing.expectEqual(close_id, closed_reply.value.id);
    try std.testing.expectEqual(local_id, controller.closeTarget(close_id).?);
    _ = mux.closePaneById(&runtime, local_id);
    try std.testing.expectEqual(@as(usize, 0), mux.workspaces.items.len);
    try std.testing.expect(controller.closesSettled());
}

test {
    _ = @import("session_controller_test.zig");
    _ = @import("session/open.zig");
    _ = @import("session/notice.zig");
    _ = @import("app/session_domain.zig");
    _ = @import("session_spawn_mux_test.zig");
}
