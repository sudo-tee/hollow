//! Explicit opt-in integration check. Can run as a native Windows executable
//! under WSL interop to exercise Windows pipe I/O through wsl.exe, not just
//! Linux-to-Linux protocol behavior. Guest agent must already be present.
const std = @import("std");
const io = @import("io.zig");
const transport = @import("session/transport.zig");
const support = @import("session_transport_test.zig");
const p = transport.p;
const a = std.testing.allocator;

test "session connector WSL preserves live process and snapshot across client destruction" {
    const settings = @import("session_test_options");
    const distro = settings.wsl orelse return error.SkipZigTest;
    const agent = settings.agent orelse return error.MissingAgentPath;
    const dir = try std.fmt.allocPrint(a, "/tmp/hollow-session-transport-check-{d}", .{io.nanoTimestamp()});
    defer a.free(dir);
    const runtime_env = try std.fmt.allocPrint(a, "HOLLOW_SESSION_DIR={s}", .{dir});
    defer a.free(runtime_env);
    const state_env = try std.fmt.allocPrint(a, "XDG_STATE_HOME={s}", .{dir});
    defer a.free(state_env);
    const options: transport.Options = .{
        .connector = .{ .argv = &.{ "wsl.exe", "-d", distro, "--", "/usr/bin/env", runtime_env, state_env } },
        .agent = .{ .path = agent },
        .ghostty_identity = "connector-check",
    };
    defer {
        if (transport.Connection.create(a, io.get(), options)) |cleanup| {
            defer cleanup.destroy();
            _ = cleanup.request(.{ .id = 0, .op = .kill_server }) catch 0;
            if (support.waitMessage(cleanup, .reply)) |message| message.deinit() else |_| {}
            support.waitEnded(cleanup) catch {};
        } else |_| {}
        // Only exact files/directories this fixture creates; never recurse.
        const command = options.connector.command(a, &.{ "/bin/sh", "-c", "rm -f -- \"$1/owner.log\" \"$1/session-v1.lock\"; rmdir -- \"$1/hollow/sessions\" \"$1/hollow\" \"$1\"", "cleanup", dir }) catch null;
        if (command) |argv| {
            defer a.free(argv);
            if (std.process.spawn(io.get(), .{ .argv = argv, .stdout = .ignore, .stderr = .ignore, .create_no_window = true })) |child_value| {
                var child = child_value;
                _ = child.wait(io.get()) catch child.kill(io.get());
            } else |_| {}
        }
    }
    var first: ?*transport.Connection = try transport.Connection.create(a, io.get(), options);
    defer if (first) |connection| connection.destroy();
    _ = try first.?.request(.{ .id = 0, .op = .create, .spawn = .{
        .argv = &.{ "/bin/sh", "-c", "printf 'kept-screen'; read x; printf 'after-%s' \"$x\"; sleep 30" },
        .shell_integration = false,
    } });
    const created = try support.waitMessage(first.?, .reply);
    defer created.deinit();
    const reply = try p.parse(p.Reply, a, created.payload);
    defer reply.deinit();
    try std.testing.expect(reply.value.ok);
    const sid = reply.value.session.?.id;
    const pane = reply.value.session.?.panes[0].id;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    while (std.mem.indexOf(u8, bytes.items, "kept-screen") == null) {
        const message = try support.waitMessage(first.?, .output);
        defer message.deinit();
        try bytes.appendSlice(a, message.payload);
        try first.?.consumed(message);
    }
    first.?.destroy();
    first = null;
    const second = try transport.Connection.create(a, io.get(), options);
    defer second.destroy();
    _ = try second.request(.{ .id = 0, .op = .attach, .session = sid });
    const attached = try support.waitMessage(second, .reply);
    defer attached.deinit();
    const attached_reply = try p.parse(p.Reply, a, attached.payload);
    defer attached_reply.deinit();
    try std.testing.expect(attached_reply.value.ok);
    bytes.clearRetainingCapacity();
    const deadline = io.nanoTimestamp() + 10 * std.time.ns_per_s;
    while (true) {
        if (io.nanoTimestamp() >= deadline) return error.Timeout;
        const message = second.poll() orelse {
            if (second.status().phase == .ended) return error.ConnectionEnded;
            try std.Io.sleep(io.get(), .fromMilliseconds(5), .awake);
            continue;
        };
        defer message.deinit();
        if (message.kind == .snapshot) try bytes.appendSlice(a, message.payload);
        if (message.kind == .snapshot_end) break;
    }
    try std.testing.expect(std.mem.indexOf(u8, bytes.items, "kept-screen") != null);
    try second.send(.input, pane, "windows-pipes\n");
    bytes.clearRetainingCapacity();
    while (std.mem.indexOf(u8, bytes.items, "after-windows-pipes") == null) {
        const message = try support.waitMessage(second, .output);
        defer message.deinit();
        try bytes.appendSlice(a, message.payload);
        try second.consumed(message);
    }
}
